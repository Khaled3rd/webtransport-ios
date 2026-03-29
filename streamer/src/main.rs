mod config;
mod capture;
mod encoder;
mod transport;
mod toy_control;
mod error;

use std::sync::Arc;
use tokio::sync::{broadcast, mpsc};
use tokio::sync::mpsc::error::TrySendError;
use tracing_subscriber::EnvFilter;

use crate::config::Config;
use crate::capture::{start_capture, CapturedFrame};
use crate::encoder::{create_encoder, encode_frame, Direction, EncoderCommand, NalUnit, VideoEncoder};
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

    // Command channel: transport → encoder (parsed EncoderCommand + originating sub_id)
    let (enc_cmd_tx, mut enc_cmd_rx) = mpsc::channel::<(EncoderCommand, u64)>(16);
    // Response broadcast: encoder → transport (response JSON + target sub_id)
    let (resp_bcast_tx, _) = broadcast::channel::<(u64, String)>(16);
    let resp_bcast_tx = Arc::new(resp_bcast_tx);

    // Toy controller channel: encoder loop → toy_control task
    let (toy_cmd_tx, toy_cmd_rx) = mpsc::channel::<(Direction, u64)>(16);
    tokio::spawn(toy_control::run_toy_controller(toy_cmd_rx));

    let camera_config = config.camera.clone();
    let relay_config = config.relay.clone();
    let encoder_config = config.encoder.clone();
    let width = config.camera.width;
    let height = config.camera.height;

    let _capture_handle = start_capture(camera_config, capture_tx)?;

    let encoder_config_clone = encoder_config.clone();
    let nal_tx_clone = nal_tx.clone();
    let resp_bcast_tx_enc = resp_bcast_tx.clone();
    let toy_cmd_tx_enc = toy_cmd_tx;
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
                    match nal_tx_clone.try_send(nals) {
                        Ok(()) => {}
                        Err(TrySendError::Full(_)) => {
                            // Transport is busy — drop this frame, force IDR next
                            // so the viewer doesn't receive a delta missing its reference.
                            encoder.force_idr_next = true;
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

            // Drain any pending commands from the transport task.
            while let Ok((cmd, sub_id)) = enc_cmd_rx.try_recv() {
                match cmd {
                    EncoderCommand::Move(dir) => {
                        let _ = toy_cmd_tx_enc.try_send((dir, sub_id));
                    }
                    other => {
                        let cmd_name = encoder.apply_command(other);
                        let json = format!(r#"{{"ok":true,"cmd":"{}"}}"#, cmd_name);
                        let _ = resp_bcast_tx_enc.send((sub_id, json));
                    }
                }
            }
        }
    });

    let shutdown = tokio::signal::ctrl_c();

    tokio::select! {
        _ = transport::run_transport(relay_config, nal_rx, enc_cmd_tx, resp_bcast_tx) => {
            tracing::info!("Transport ended");
        }
        _ = shutdown => {
            tracing::info!("Shutdown signal received");
        }
    }

    Ok(())
}
