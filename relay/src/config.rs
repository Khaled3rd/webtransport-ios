use serde::Deserialize;
use std::path::Path;
use crate::error::RelayError;

#[derive(Debug, Deserialize, Clone)]
pub struct Config {
    pub server: ServerConfig,
    pub tls: TlsConfig,
}

#[derive(Debug, Deserialize, Clone)]
pub struct ServerConfig {
    pub bind: String,
    pub publish_path: String,
    pub subscribe_path: String,
    pub publish_token: String,
    pub max_subscribers: usize,
}

#[derive(Debug, Deserialize, Clone)]
pub struct TlsConfig {
    pub cert_path: String,
    pub key_path: String,
    pub cert_validity_days: u32,
}

impl Config {
    pub fn load(path: &str) -> Result<Self, RelayError> {
        let content = std::fs::read_to_string(path)
            .map_err(|e| RelayError::Config(format!("Failed to read config file {path}: {e}")))?;
        toml::from_str(&content)
            .map_err(|e| RelayError::Config(format!("Failed to parse config: {e}")))
    }
}
