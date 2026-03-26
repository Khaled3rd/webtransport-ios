use bytes::Bytes;
use std::sync::Arc;
use tokio::sync::broadcast;

pub type FrameSender = Arc<broadcast::Sender<Bytes>>;

pub fn create_fanout() -> FrameSender {
    // Capacity 3: drops old frames rather than new ones — intentional for low latency
    let (tx, _) = broadcast::channel(3);
    Arc::new(tx)
}
