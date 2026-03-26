use thiserror::Error;

#[derive(Debug, Error)]
pub enum RelayError {
    #[error("TLS error: {0}")]
    Tls(String),

    #[error("Config error: {0}")]
    Config(String),

    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),

    #[error("Publisher already connected")]
    PublisherConflict,

    #[error("Max subscribers reached")]
    MaxSubscribers,

    #[error("Unauthorized")]
    Unauthorized,

    #[error("Transport error: {0}")]
    Transport(String),
}
