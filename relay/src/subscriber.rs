use bytes::Bytes;
use dashmap::DashMap;
use std::sync::Arc;
use tokio::sync::{Mutex, broadcast};
use crate::error::RelayError;
use crate::fanout::FrameSender;

pub struct SubscriberRegistry {
    pub count: Arc<DashMap<u64, ()>>,
    pub next_id: Arc<std::sync::atomic::AtomicU64>,
}

impl SubscriberRegistry {
    pub fn new() -> Self {
        Self {
            count: Arc::new(DashMap::new()),
            next_id: Arc::new(std::sync::atomic::AtomicU64::new(0)),
        }
    }

    pub fn subscriber_count(&self) -> usize {
        self.count.len()
    }
}

pub async fn handle_subscriber(
    session: wtransport::Connection,
    broadcast_tx: FrameSender,
    registry: Arc<SubscriberRegistry>,
    max_subscribers: usize,
    cmd_bcast_tx: Arc<broadcast::Sender<(u64, Bytes)>>,
    resp_bcast_tx: Arc<broadcast::Sender<(u64, Bytes)>>,
) -> Result<(), RelayError> {
    let current = registry.subscriber_count();
    if current >= max_subscribers {
        tracing::warn!("Max subscribers ({max_subscribers}) reached, rejecting new subscriber");
        return Err(RelayError::MaxSubscribers);
    }

    let id = registry.next_id.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    registry.count.insert(id, ());
    tracing::info!("Subscriber {id} connected (total: {})", registry.subscriber_count());

    let mut rx = broadcast_tx.subscribe();

    let result = run_subscriber_loop(&session, &mut rx, id, cmd_bcast_tx, resp_bcast_tx).await;

    registry.count.remove(&id);
    tracing::info!("Subscriber {id} disconnected (total: {})", registry.subscriber_count());

    result
}

async fn run_subscriber_loop(
    session: &wtransport::Connection,
    rx: &mut broadcast::Receiver<Bytes>,
    id: u64,
    cmd_bcast_tx: Arc<broadcast::Sender<(u64, Bytes)>>,
    resp_bcast_tx: Arc<broadcast::Sender<(u64, Bytes)>>,
) -> Result<(), RelayError> {
    // Open a single persistent uni stream to this subscriber for video.
    let opening = match session.open_uni().await {
        Ok(o) => o,
        Err(e) => {
            tracing::debug!("Subscriber {id} open_uni error: {e}");
            return Ok(());
        }
    };
    let mut video_stream = match opening.await {
        Ok(s) => s,
        Err(e) => {
            tracing::debug!("Subscriber {id} stream open error: {e}");
            return Ok(());
        }
    };

    tracing::info!("Subscriber {id} video stream open, forwarding frames");

    // Open a bidi stream to iOS for commands/responses. Non-fatal if it fails.
    match session.open_bi().await {
        Ok(bi_opening) => match bi_opening.await {
            Ok((bidi_send, bidi_recv)) => {
                tracing::info!("Subscriber {id} bidi command stream open");
                let bidi_send = Arc::new(Mutex::new(bidi_send));

                // cmd_reader: read [4B len][bytes] from iOS, forward as (id, bytes) to cmd_bcast
                {
                    let cmd_bcast_tx = cmd_bcast_tx.clone();
                    tokio::spawn(async move {
                        let mut recv = bidi_recv;
                        let mut len_buf = [0u8; 4];
                        loop {
                            match recv_exact(&mut recv, &mut len_buf).await {
                                Ok(false) | Err(_) => break,
                                Ok(true) => {}
                            }
                            let len = u32::from_be_bytes(len_buf) as usize;
                            if len == 0 || len > 1_000_000 {
                                tracing::warn!("Subscriber {id}: invalid cmd length {len}");
                                break;
                            }
                            let mut body = vec![0u8; len];
                            match recv_exact(&mut recv, &mut body).await {
                                Ok(false) | Err(_) => break,
                                Ok(true) => {}
                            }
                            let _ = cmd_bcast_tx.send((id, Bytes::from(body)));
                        }
                        tracing::debug!("Subscriber {id} cmd_reader ended");
                    });
                }

                // resp_writer: subscribe to resp_bcast, filter by id, write [4B len][bytes] to iOS
                {
                    let bidi_send = bidi_send.clone();
                    let mut resp_rx = resp_bcast_tx.subscribe();
                    tokio::spawn(async move {
                        loop {
                            match resp_rx.recv().await {
                                Ok((target_id, resp_bytes)) if target_id == id => {
                                    let len = resp_bytes.len() as u32;
                                    let mut msg = Vec::with_capacity(4 + resp_bytes.len());
                                    msg.extend_from_slice(&len.to_be_bytes());
                                    msg.extend_from_slice(&resp_bytes);
                                    let mut s = bidi_send.lock().await;
                                    if let Err(e) = s.write_all(&msg).await {
                                        tracing::debug!("Subscriber {id} resp_writer error: {e}");
                                        break;
                                    }
                                }
                                Ok(_) => {} // response is for a different subscriber
                                Err(broadcast::error::RecvError::Lagged(n)) => {
                                    tracing::warn!("Subscriber {id} resp_writer lagged by {n}");
                                }
                                Err(broadcast::error::RecvError::Closed) => break,
                            }
                        }
                        tracing::debug!("Subscriber {id} resp_writer ended");
                    });
                }
            }
            Err(e) => tracing::warn!("Subscriber {id}: bidi stream open error: {e}"),
        },
        Err(e) => tracing::warn!("Subscriber {id}: open_bi error: {e}"),
    }

    // Video loop — unchanged from original.
    loop {
        match rx.recv().await {
            Ok(frame) => {
                // Write [4B length][frame bytes] in one allocation to minimise syscalls
                let mut msg = Vec::with_capacity(4 + frame.len());
                msg.extend_from_slice(&(frame.len() as u32).to_be_bytes());
                msg.extend_from_slice(&frame);
                if let Err(e) = video_stream.write_all(&msg).await {
                    tracing::debug!("Subscriber {id} write error: {e}");
                    return Ok(());
                }
            }
            Err(broadcast::error::RecvError::Lagged(n)) => {
                tracing::warn!("Subscriber {id} lagged by {n} frames, continuing");
            }
            Err(broadcast::error::RecvError::Closed) => {
                tracing::info!("Subscriber {id}: broadcast channel closed");
                return Ok(());
            }
        }
    }
}

/// Read exactly buf.len() bytes from a bidi RecvStream.
/// Returns Ok(true) on success, Ok(false) on clean EOF, Err on error.
async fn recv_exact(
    stream: &mut wtransport::RecvStream,
    buf: &mut [u8],
) -> Result<bool, RelayError> {
    let mut offset = 0;
    while offset < buf.len() {
        match stream.read(&mut buf[offset..]).await {
            Ok(Some(n)) => offset += n,
            Ok(None) => return Ok(false),
            Err(e) => return Err(RelayError::Transport(format!("Read error: {e}"))),
        }
    }
    Ok(true)
}
