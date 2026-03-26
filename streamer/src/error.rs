use thiserror::Error;

#[derive(Debug, Error)]
pub enum StreamerError {
    #[error("Config error: {0}")]
    Config(String),

    #[error("Camera error: {0}")]
    Camera(String),

    #[error("Encoder error: {0}")]
    Encoder(String),

    #[error("Transport error: {0}")]
    Transport(String),

    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),
}
