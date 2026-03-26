use bytes::Bytes;
use dashmap::DashMap;
use std::sync::Arc;
use tokio::sync::broadcast;
use wtransport::SendStream;
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

    let result = run_subscriber_loop(&session, &mut rx, id).await;

    registry.count.remove(&id);
    tracing::info!("Subscriber {id} disconnected (total: {})", registry.subscriber_count());

    result
}

async fn run_subscriber_loop(
    session: &wtransport::Connection,
    rx: &mut broadcast::Receiver<Bytes>,
    id: u64,
) -> Result<(), RelayError> {
    // Open a single persistent uni stream to this subscriber.
    // Frames are written as [4B length BE][1B flags][Annex-B NALs].
    let opening = match session.open_uni().await {
        Ok(o) => o,
        Err(e) => {
            tracing::debug!("Subscriber {id} open_uni error: {e}");
            return Ok(());
        }
    };
    let mut stream = match opening.await {
        Ok(s) => s,
        Err(e) => {
            tracing::debug!("Subscriber {id} stream open error: {e}");
            return Ok(());
        }
    };

    tracing::info!("Subscriber {id} stream open, forwarding frames");

    loop {
        match rx.recv().await {
            Ok(frame) => {
                // Write [4B length][frame bytes] in one allocation to minimise syscalls
                let mut msg = Vec::with_capacity(4 + frame.len());
                msg.extend_from_slice(&(frame.len() as u32).to_be_bytes());
                msg.extend_from_slice(&frame);
                if let Err(e) = stream.write_all(&msg).await {
                    tracing::debug!("Subscriber {id} write error: {e}");
                    return Ok(());
                }
            }
            Err(broadcast::error::RecvError::Lagged(n)) => {
                // Drop lagged frames but keep the connection — don't disconnect on lag
                tracing::warn!("Subscriber {id} lagged by {n} frames, continuing");
            }
            Err(broadcast::error::RecvError::Closed) => {
                tracing::info!("Subscriber {id}: broadcast channel closed");
                return Ok(());
            }
        }
    }
}
