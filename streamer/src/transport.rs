use std::time::Duration;
use tokio::sync::mpsc;
use wtransport::{ClientConfig, Endpoint};
use wtransport::tls::Sha256Digest;
use crate::config::RelayConfig;
use crate::encoder::NalUnit;
use crate::error::StreamerError;

pub async fn run_transport(
    config: RelayConfig,
    mut rx: mpsc::Receiver<Vec<NalUnit>>,
) -> Result<(), StreamerError> {
    let fingerprint_bytes = parse_fingerprint(&config.cert_fingerprint)?;

    let mut backoff = Duration::from_secs(1);

    loop {
        tracing::info!("Connecting to relay: {}", config.url);

        match connect_and_stream(&config, &fingerprint_bytes, &mut rx).await {
            Ok(_) => {
                tracing::info!("Transport session ended cleanly");
                backoff = Duration::from_secs(1);
            }
            Err(e) => {
                tracing::warn!("Transport error: {e}, reconnecting in {backoff:?}");
                tokio::time::sleep(backoff).await;
                backoff = (backoff * 2).min(Duration::from_secs(30));
            }
        }
    }
}

async fn connect_and_stream(
    config: &RelayConfig,
    fingerprint_bytes: &[u8; 32],
    rx: &mut mpsc::Receiver<Vec<NalUnit>>,
) -> Result<(), StreamerError> {
    let digest = Sha256Digest::new(*fingerprint_bytes);

    let client_config = ClientConfig::builder()
        .with_bind_default()
        .with_server_certificate_hashes([digest])
        .build();

    let endpoint = match Endpoint::client(client_config) {
        Ok(e) => e,
        Err(e) => return Err(StreamerError::Transport(format!("Failed to create endpoint: {e}"))),
    };

    let connect_opts = wtransport::endpoint::ConnectOptions::builder(&config.url)
        .add_header("authorization", format!("Bearer {}", config.token))
        .build();

    let connection = match endpoint.connect(connect_opts).await {
        Ok(c) => c,
        Err(e) => return Err(StreamerError::Transport(format!("Connection failed: {e}"))),
    };

    tracing::info!("Connected to relay at {}", config.url);

    // Open a single persistent uni stream for the entire session.
    // All frames are written as [4B length BE][1B flags][Annex-B NALs].
    let opening = match connection.open_uni().await {
        Ok(o) => o,
        Err(e) => return Err(StreamerError::Transport(format!("open_uni failed: {e}"))),
    };
    let mut stream = match opening.await {
        Ok(s) => s,
        Err(e) => return Err(StreamerError::Transport(format!("Stream open failed: {e}"))),
    };

    tracing::info!("Publish stream open, streaming frames");

    loop {
        let nals = match rx.recv().await {
            Some(n) => n,
            None => {
                tracing::info!("NAL channel closed");
                return Ok(());
            }
        };

        // Bundle all NALs into one frame: [4B length BE][1B flags][Annex-B NALs concatenated]
        let is_keyframe = nals.iter().any(|n| n.is_keyframe);
        let flags: u8 = if is_keyframe { 0x01 } else { 0x00 };

        let nal_bytes: usize = nals.iter().map(|n| n.data.len()).sum();
        // frame_len = 1 (flags) + nal_bytes
        let frame_len = (1 + nal_bytes) as u32;

        let mut frame = Vec::with_capacity(4 + 1 + nal_bytes);
        frame.extend_from_slice(&frame_len.to_be_bytes());
        frame.push(flags);
        for nal in &nals {
            frame.extend_from_slice(&nal.data);
        }

        use wtransport::SendStream;
        if let Err(e) = stream.write_all(&frame).await {
            return Err(StreamerError::Transport(format!("Write failed: {e}")));
        }
    }
}

fn parse_fingerprint(hex_str: &str) -> Result<[u8; 32], StreamerError> {
    let bytes: Vec<u8> = hex_str
        .split(':')
        .map(|part| {
            u8::from_str_radix(part, 16)
                .map_err(|e| StreamerError::Transport(format!("Invalid fingerprint hex '{part}': {e}")))
        })
        .collect::<Result<Vec<u8>, StreamerError>>()?;

    bytes.try_into()
        .map_err(|v: Vec<u8>| StreamerError::Transport(
            format!("Fingerprint must be 32 bytes, got {}", v.len())
        ))
}
