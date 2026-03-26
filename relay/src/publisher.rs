use bytes::Bytes;
use std::sync::Arc;
use tokio::sync::Mutex;
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

    let result = run_publisher_loop(&session, &broadcast_tx).await;

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
) -> Result<(), RelayError> {
    // Expect exactly one persistent uni stream from the streamer.
    let mut stream = match session.accept_uni().await {
        Ok(s) => s,
        Err(e) => {
            tracing::info!("Publisher: failed to accept stream: {e}");
            return Ok(());
        }
    };

    tracing::info!("Publisher stream accepted, reading frames");

    let mut len_buf = [0u8; 4];
    loop {
        // Read 4-byte length prefix
        match read_exact(&mut stream, &mut len_buf).await? {
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
        match read_exact(&mut stream, &mut frame).await? {
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
