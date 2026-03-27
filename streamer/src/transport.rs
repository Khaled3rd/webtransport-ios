use std::sync::Arc;
use std::time::Duration;
use tokio::sync::{broadcast, mpsc, Mutex};
use wtransport::{ClientConfig, Endpoint};
use wtransport::tls::Sha256Digest;
use crate::config::RelayConfig;
use crate::encoder::{Direction, EncoderCommand, NalUnit};
use crate::error::StreamerError;

pub async fn run_transport(
    config: RelayConfig,
    mut rx: mpsc::Receiver<Vec<NalUnit>>,
    enc_cmd_tx: mpsc::Sender<(EncoderCommand, u64)>,
    resp_bcast_tx: Arc<broadcast::Sender<(u64, String)>>,
) -> Result<(), StreamerError> {
    let fingerprint_bytes = parse_fingerprint(&config.cert_fingerprint)?;

    let mut backoff = Duration::from_secs(1);

    loop {
        tracing::info!("Connecting to relay: {}", config.url);

        match connect_and_stream(&config, &fingerprint_bytes, &mut rx, &enc_cmd_tx, &resp_bcast_tx).await {
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
    enc_cmd_tx: &mpsc::Sender<(EncoderCommand, u64)>,
    resp_bcast_tx: &Arc<broadcast::Sender<(u64, String)>>,
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

    // Open a single persistent uni stream for video.
    let opening = match connection.open_uni().await {
        Ok(o) => o,
        Err(e) => return Err(StreamerError::Transport(format!("open_uni failed: {e}"))),
    };
    let mut video_stream = match opening.await {
        Ok(s) => s,
        Err(e) => return Err(StreamerError::Transport(format!("Stream open failed: {e}"))),
    };

    tracing::info!("Publish stream open, streaming frames");

    // Open a bidi stream for the command channel. Non-fatal if it fails.
    let cmd_task_handles = match connection.open_bi().await {
        Ok(bi_opening) => match bi_opening.await {
            Ok((bidi_send, bidi_recv)) => {
                tracing::info!("Command bidi stream open");
                let bidi_send = Arc::new(Mutex::new(bidi_send));

                // cmd_reader_task: read [8B sub_id][4B len][JSON] from relay, parse, send to encoder
                let cmd_task = {
                    let enc_cmd_tx = enc_cmd_tx.clone();
                    tokio::spawn(async move {
                        let mut recv = bidi_recv;
                        let mut id_buf = [0u8; 8];
                        let mut len_buf = [0u8; 4];
                        loop {
                            match recv_exact(&mut recv, &mut id_buf).await {
                                Ok(false) | Err(_) => break,
                                Ok(true) => {}
                            }
                            match recv_exact(&mut recv, &mut len_buf).await {
                                Ok(false) | Err(_) => break,
                                Ok(true) => {}
                            }
                            let sub_id = u64::from_be_bytes(id_buf);
                            let len = u32::from_be_bytes(len_buf) as usize;
                            if len == 0 || len > 1_000_000 {
                                tracing::warn!("Transport: invalid cmd length {len}");
                                break;
                            }
                            let mut body = vec![0u8; len];
                            match recv_exact(&mut recv, &mut body).await {
                                Ok(false) | Err(_) => break,
                                Ok(true) => {}
                            }
                            let json_str = match std::str::from_utf8(&body) {
                                Ok(s) => s,
                                Err(_) => { tracing::warn!("Invalid UTF-8 in command"); continue; }
                            };
                            let cmd = match parse_command(json_str) {
                                Some(c) => c,
                                None => { tracing::warn!("Unknown command: {json_str}"); continue; }
                            };
                            let _ = enc_cmd_tx.send((cmd, sub_id)).await;
                        }
                        tracing::debug!("Transport cmd_reader ended");
                    })
                };

                // resp_writer_task: subscribe to resp_bcast, write [8B sub_id][4B len][bytes] to relay
                let resp_task = {
                    let bidi_send = bidi_send.clone();
                    let mut resp_rx = resp_bcast_tx.subscribe();
                    tokio::spawn(async move {
                        loop {
                            match resp_rx.recv().await {
                                Ok((sub_id, json)) => {
                                    let bytes = json.as_bytes();
                                    let len = bytes.len() as u32;
                                    let mut msg = Vec::with_capacity(12 + bytes.len());
                                    msg.extend_from_slice(&sub_id.to_be_bytes());
                                    msg.extend_from_slice(&len.to_be_bytes());
                                    msg.extend_from_slice(bytes);
                                    let mut s = bidi_send.lock().await;
                                    if let Err(e) = s.write_all(&msg).await {
                                        tracing::debug!("Transport resp_writer error: {e}");
                                        break;
                                    }
                                }
                                Err(broadcast::error::RecvError::Lagged(n)) => {
                                    tracing::warn!("Transport resp_writer lagged by {n}");
                                }
                                Err(broadcast::error::RecvError::Closed) => break,
                            }
                        }
                        tracing::debug!("Transport resp_writer ended");
                    })
                };

                Some((cmd_task, resp_task))
            }
            Err(e) => {
                tracing::warn!("Transport: bidi stream open failed: {e}, command channel unavailable");
                None
            }
        },
        Err(e) => {
            tracing::warn!("Transport: open_bi failed: {e}, command channel unavailable");
            None
        }
    };

    // Video loop.
    let result = loop {
        let nals = match rx.recv().await {
            Some(n) => n,
            None => {
                tracing::info!("NAL channel closed");
                break Ok(());
            }
        };

        let is_keyframe = nals.iter().any(|n| n.is_keyframe);
        let flags: u8 = if is_keyframe { 0x01 } else { 0x00 };

        let nal_bytes: usize = nals.iter().map(|n| n.data.len()).sum();
        let frame_len = (1 + nal_bytes) as u32;

        let mut frame = Vec::with_capacity(4 + 1 + nal_bytes);
        frame.extend_from_slice(&frame_len.to_be_bytes());
        frame.push(flags);
        for nal in &nals {
            frame.extend_from_slice(&nal.data);
        }

        use wtransport::SendStream;
        if let Err(e) = video_stream.write_all(&frame).await {
            break Err(StreamerError::Transport(format!("Write failed: {e}")));
        }
    };

    // Clean up bidi tasks.
    if let Some((cmd_task, resp_task)) = cmd_task_handles {
        cmd_task.abort();
        resp_task.abort();
    }

    result
}

fn parse_command(json: &str) -> Option<EncoderCommand> {
    let v: serde_json::Value = serde_json::from_str(json).ok()?;
    match v.get("cmd")?.as_str()? {
        "force_keyframe" => Some(EncoderCommand::ForceKeyframe),
        "set_bitrate" => {
            let kbps = v.get("kbps")?.as_u64()? as u32;
            Some(EncoderCommand::SetBitrate(kbps))
        }
        "move_start" => {
            let dir = match v.get("dir")?.as_str()? {
                "up"    => Direction::Up,
                "down"  => Direction::Down,
                "left"  => Direction::Left,
                "right" => Direction::Right,
                _       => return None,
            };
            Some(EncoderCommand::Move(dir))
        }
        "move_stop" => Some(EncoderCommand::Move(Direction::Stop)),
        _ => None,
    }
}

async fn recv_exact(stream: &mut wtransport::RecvStream, buf: &mut [u8]) -> Result<bool, StreamerError> {
    let mut offset = 0;
    while offset < buf.len() {
        match stream.read(&mut buf[offset..]).await {
            Ok(Some(n)) => offset += n,
            Ok(None) => return Ok(false),
            Err(e) => return Err(StreamerError::Transport(format!("Read error: {e}"))),
        }
    }
    Ok(true)
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
