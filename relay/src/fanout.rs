use bytes::Bytes;
use std::sync::Arc;
use tokio::sync::broadcast;

pub type FrameSender = Arc<broadcast::Sender<Bytes>>;

pub fn create_fanout() -> FrameSender {
    // Capacity 8: ~267ms at 30fps. Reduces lag-induced keyframe requests without
    // adding latency (subscriber drains immediately when it keeps up).
    let (tx, _) = broadcast::channel(8);
    Arc::new(tx)
}
