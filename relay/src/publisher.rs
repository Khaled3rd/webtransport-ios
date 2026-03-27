use bytes::Bytes;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::{Mutex, broadcast};
use crate::error::RelayError;
use crate::fanout::FrameSender;

pub struct PublisherState {
    pub connected: Arc<Mutex<bool>>,
}

impl PublisherState {
    pub fn new() -> Self {
        Self {
            connected: Arc::new(Mutex::new(false)),
        }
    }
}

pub async fn handle_publisher(
    session: wtransport::Connection,
    broadcast_tx: FrameSender,
    publisher_connected: Arc<Mutex<bool>>,
    token: String,
    cmd_bcast_tx: Arc<broadcast::Sender<(u64, Bytes)>>,
    resp_bcast_tx: Arc<broadcast::Sender<(u64, Bytes)>>,
) -> Result<(), RelayError> {
    {
        let mut connected = publisher_connected.lock().await;
        if *connected {
            tracing::warn!("Second publisher rejected (409)");
            return Err(RelayError::PublisherConflict);
        }
        *connected = true;
    }

    tracing::info!("Publisher connected");

    let result = run_publisher_loop(&session, &broadcast_tx, cmd_bcast_tx, resp_bcast_tx).await;

    {
        let mut connected = publisher_connected.lock().await;
        *connected = false;
    }

    tracing::info!("Publisher disconnected");
    result
}

async fn run_publisher_loop(
    session: &wtransport::Connection,
    broadcast_tx: &FrameSender,
    cmd_bcast_tx: Arc<broadcast::Sender<(u64, Bytes)>>,
    resp_bcast_tx: Arc<broadcast::Sender<(u64, Bytes)>>,
) -> Result<(), RelayError> {
    // Accept the video uni stream from the streamer.
    let mut video_stream = match session.accept_uni().await {
        Ok(s) => s,
        Err(e) => {
            tracing::info!("Publisher: failed to accept stream: {e}");
            return Ok(());
        }
    };

    tracing::info!("Publisher stream accepted, reading frames");

    // Try to accept the command bidi stream from the streamer.
    // The streamer opens this right after the video stream, so a short timeout suffices.
    // Failure is non-fatal: video-only mode continues.
    match tokio::time::timeout(Duration::from_secs(3), session.accept_bi()).await {
        Ok(Ok((bidi_send, bidi_recv))) => {
            tracing::info!("Publisher bidi command stream accepted");
            let bidi_send = Arc::new(Mutex::new(bidi_send));

            // cmd_forwarder: subscribe to cmd_bcast, write [8B sub_id][4B len][bytes] to streamer
            {
                let bidi_send = bidi_send.clone();
                let mut cmd_rx = cmd_bcast_tx.subscribe();
                tokio::spawn(async move {
                    loop {
                        match cmd_rx.recv().await {
                            Ok((sub_id, cmd_bytes)) => {
                                let len = cmd_bytes.len() as u32;
                                let mut msg = Vec::with_capacity(12 + cmd_bytes.len());
                                msg.extend_from_slice(&sub_id.to_be_bytes());
                                msg.extend_from_slice(&len.to_be_bytes());
                                msg.extend_from_slice(&cmd_bytes);
                                let mut s = bidi_send.lock().await;
                                if let Err(e) = s.write_all(&msg).await {
                                    tracing::debug!("Publisher cmd_forwarder write error: {e}");
                                    break;
                                }
                            }
                            Err(broadcast::error::RecvError::Lagged(n)) => {
                                tracing::warn!("Publisher cmd_forwarder lagged by {n}");
                            }
                            Err(broadcast::error::RecvError::Closed) => break,
                        }
                    }
                    tracing::debug!("Publisher cmd_forwarder ended");
                });
            }

            // resp_reader: read [8B sub_id][4B len][bytes] from streamer, forward to resp_bcast
            {
                tokio::spawn(async move {
                    let mut recv = bidi_recv;
                    let mut id_buf = [0u8; 8];
                    let mut len_buf = [0u8; 4];
                    loop {
                        match read_exact(&mut recv, &mut id_buf).await {
                            Ok(ReadResult::Eof) | Err(_) => break,
                            Ok(ReadResult::Ok) => {}
                        }
                        match read_exact(&mut recv, &mut len_buf).await {
                            Ok(ReadResult::Eof) | Err(_) => break,
                            Ok(ReadResult::Ok) => {}
                        }
                        let sub_id = u64::from_be_bytes(id_buf);
                        let len = u32::from_be_bytes(len_buf) as usize;
                        if len == 0 || len > 1_000_000 {
                            tracing::warn!("Publisher: invalid resp length {len}");
                            break;
                        }
                        let mut body = vec![0u8; len];
                        match read_exact(&mut recv, &mut body).await {
                            Ok(ReadResult::Eof) | Err(_) => break,
                            Ok(ReadResult::Ok) => {}
                        }
                        let _ = resp_bcast_tx.send((sub_id, Bytes::from(body)));
                    }
                    tracing::debug!("Publisher resp_reader ended");
                });
            }
        }
        Ok(Err(e)) => tracing::warn!("Publisher: bidi stream error: {e}, running video-only"),
        Err(_) => tracing::warn!("Publisher: bidi stream timeout, running video-only"),
    }

    // Video loop — unchanged from original.
    let mut len_buf = [0u8; 4];
    loop {
        // Read 4-byte length prefix
        match read_exact(&mut video_stream, &mut len_buf).await? {
            ReadResult::Eof => {
                tracing::info!("Publisher stream closed by streamer");
                return Ok(());
            }
            ReadResult::Ok => {}
        }

        let frame_len = u32::from_be_bytes(len_buf) as usize;
        if frame_len == 0 || frame_len > 2_000_000 {
            tracing::warn!("Publisher: invalid frame length {frame_len}, dropping connection");
            return Err(RelayError::Transport(format!("invalid frame length: {frame_len}")));
        }

        let mut frame = vec![0u8; frame_len];
        match read_exact(&mut video_stream, &mut frame).await? {
            ReadResult::Eof => {
                tracing::info!("Publisher stream closed mid-frame");
                return Ok(());
            }
            ReadResult::Ok => {}
        }

        // Broadcast [1B flags][Annex-B NALs] to all subscribers
        let _ = broadcast_tx.send(Bytes::from(frame));
    }
}

enum ReadResult {
    Ok,
    Eof,
}

async fn read_exact(
    stream: &mut wtransport::RecvStream,
    buf: &mut [u8],
) -> Result<ReadResult, RelayError> {
    let mut offset = 0;
    while offset < buf.len() {
        match stream.read(&mut buf[offset..]).await {
            Ok(Some(n)) => offset += n,
            Ok(None) => return Ok(ReadResult::Eof),
            Err(e) => return Err(RelayError::Transport(format!("Read error: {e}"))),
        }
    }
    Ok(ReadResult::Ok)
}
