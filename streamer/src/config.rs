use serde::Deserialize;
use crate::error::StreamerError;

#[derive(Debug, Deserialize, Clone)]
pub struct Config {
    pub camera: CameraConfig,
    pub encoder: EncoderConfig,
    pub relay: RelayConfig,
}

#[derive(Debug, Deserialize, Clone)]
pub struct CameraConfig {
    pub device: String,
    pub width: u32,
    pub height: u32,
    pub fps: u32,
    pub pixel_format: String,
}

#[derive(Debug, Deserialize, Clone)]
pub struct EncoderConfig {
    pub profile: String,
    pub tune: String,
    pub bitrate_kbps: u32,
    pub keyframe_interval: u32,
}

#[derive(Debug, Deserialize, Clone)]
pub struct RelayConfig {
    pub url: String,
    pub token: String,
    pub cert_fingerprint: String,
}

impl Config {
    pub fn load(path: &str) -> Result<Self, StreamerError> {
        let content = std::fs::read_to_string(path)
            .map_err(|e| StreamerError::Config(format!("Failed to read {path}: {e}")))?;
        toml::from_str(&content)
            .map_err(|e| StreamerError::Config(format!("Failed to parse config: {e}")))
    }
}
