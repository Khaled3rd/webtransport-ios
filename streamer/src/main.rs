mod config;
mod capture;
mod encoder;
mod transport;
mod error;

use tokio::sync::mpsc;
use tracing_subscriber::EnvFilter;

use crate::config::Config;
use crate::capture::{start_capture, CapturedFrame};
use crate::encoder::{create_encoder, encode_frame, NalUnit, VideoEncoder};
use crate::error::StreamerError;

#[tokio::main(flavor = "multi_thread", worker_threads = 4)]
async fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::from_default_env())
        .init();

    rustls::crypto::ring::default_provider()
        .install_default()
        .expect("Failed to install crypto provider");

    let (config_path, device_override, bitrate_override, fps_override) = parse_args();

    let mut config = match Config::load(&config_path) {
        Ok(c) => c,
        Err(e) => {
            tracing::error!("Failed to load config: {e}");
            std::process::exit(1);
        }
    };

    if let Some(dev) = device_override {
        config.camera.device = dev;
    }
    if let Some(br) = bitrate_override {
        config.encoder.bitrate_kbps = br;
    }
    if let Some(fps) = fps_override {
        config.camera.fps = fps;
    }

    tracing::info!("Starting streamer: device={}, relay={}", config.camera.device, config.relay.url);

    if let Err(e) = run(config).await {
        tracing::error!("Fatal error: {e}");
        std::process::exit(1);
    }
}

fn parse_args() -> (String, Option<String>, Option<u32>, Option<u32>) {
    let args: Vec<String> = std::env::args().collect();
    let mut config_path = "config.toml".to_string();
    let mut device = None;
    let mut bitrate = None;
    let mut fps = None;

    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--config" if i + 1 < args.len() => {
                config_path = args[i + 1].clone();
                i += 2;
            }
            "--device" if i + 1 < args.len() => {
                device = Some(args[i + 1].clone());
                i += 2;
            }
            "--bitrate" if i + 1 < args.len() => {
                bitrate = args[i + 1].parse().ok();
                i += 2;
            }
            "--fps" if i + 1 < args.len() => {
                fps = args[i + 1].parse().ok();
                i += 2;
            }
            _ => i += 1,
        }
    }

    (config_path, device, bitrate, fps)
}

async fn run(config: Config) -> Result<(), StreamerError> {
    let (capture_tx, mut capture_rx) = mpsc::channel::<CapturedFrame>(4);
    // Small NAL channel — transport consumes as fast as possible.
    // try_send drops frames when full (real-time: always send latest).
    let (nal_tx, nal_rx) = mpsc::channel::<Vec<NalUnit>>(2);

    let camera_config = config.camera.clone();
    let relay_config = config.relay.clone();
    let encoder_config = config.encoder.clone();
    let width = config.camera.width;
    let height = config.camera.height;

    let _capture_handle = start_capture(camera_config, capture_tx)?;

    let encoder_config_clone = encoder_config.clone();
    let nal_tx_clone = nal_tx.clone();
    tokio::task::spawn_blocking(move || {
        let mut encoder: VideoEncoder = match create_encoder(&encoder_config_clone, width, height) {
            Ok(e) => e,
            Err(e) => {
                tracing::error!("Failed to create encoder: {e}");
                return;
            }
        };

        tracing::info!("Encoder ready");

        let rt = tokio::runtime::Handle::current();
        loop {
            let frame = rt.block_on(capture_rx.recv());
            let frame = match frame {
                Some(f) => f,
                None => {
                    tracing::info!("Capture channel closed, stopping encoder");
                    break;
                }
            };

            match encode_frame(&encoder_config_clone, &mut encoder, frame, width, height) {
                Ok(nals) if !nals.is_empty() => {
                    use tokio::sync::mpsc::error::TrySendError;
                    match nal_tx_clone.try_send(nals) {
                        Ok(()) => {}
                        Err(TrySendError::Full(_)) => {
                            // Transport is busy — drop this frame, keep encoding
                        }
                        Err(TrySendError::Closed(_)) => {
                            tracing::info!("NAL channel closed, stopping encoder");
                            break;
                        }
                    }
                }
                Ok(_) => {}
                Err(e) => tracing::warn!("Encode error: {e}"),
            }
        }
    });

    let shutdown = tokio::signal::ctrl_c();

    tokio::select! {
        _ = transport::run_transport(relay_config, nal_rx) => {
            tracing::info!("Transport ended");
        }
        _ = shutdown => {
            tracing::info!("Shutdown signal received");
        }
    }

    Ok(())
}
