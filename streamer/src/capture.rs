use bytes::Bytes;
use tokio::sync::mpsc;
use v4l::{Device, Format, FourCC};
use v4l::buffer::Type;
use v4l::io::traits::CaptureStream;
use v4l::video::Capture;
use crate::config::CameraConfig;
use crate::error::StreamerError;

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum PixelFormat {
    Yuyv,
    Mjpeg,
}

pub struct CapturedFrame {
    pub data: Bytes,
    pub format: PixelFormat,
}

pub fn start_capture(
    config: CameraConfig,
    tx: mpsc::Sender<CapturedFrame>,
) -> Result<std::thread::JoinHandle<()>, StreamerError> {
    let handle = std::thread::Builder::new()
        .name("capture".to_string())
        .spawn(move || {
            if let Err(e) = capture_loop(config, tx) {
                tracing::error!("Capture loop failed: {e}");
            }
        })
        .map_err(|e| StreamerError::Camera(format!("Failed to spawn capture thread: {e}")))?;
    Ok(handle)
}

fn capture_loop(
    config: CameraConfig,
    tx: mpsc::Sender<CapturedFrame>,
) -> Result<(), StreamerError> {
    let dev = Device::new(
        config.device
            .trim_start_matches("/dev/video")
            .parse::<usize>()
            .map_err(|e| StreamerError::Camera(format!("Invalid device path: {e}")))?
    ).map_err(|e| StreamerError::Camera(format!("Failed to open device: {e}")))?;

    // Try MJPEG first, fall back to YUYV
    let (fourcc, pixel_format) = try_set_format(&dev, &config, FourCC::new(b"MJPG"), PixelFormat::Mjpeg)
        .unwrap_or_else(|_| {
            tracing::info!("MJPEG not supported, falling back to YUYV");
            (FourCC::new(b"YUYV"), PixelFormat::Yuyv)
        });

    let fmt = Format::new(config.width, config.height, fourcc);
    dev.set_format(&fmt)
        .map_err(|e| StreamerError::Camera(format!("Failed to set format: {e}")))?;

    tracing::info!("Capture: {}x{} @ {} fps, format={pixel_format:?}", config.width, config.height, config.fps);

    let mut stream = v4l::io::mmap::Stream::with_buffers(&dev, Type::VideoCapture, 4)
        .map_err(|e| StreamerError::Camera(format!("Failed to create stream: {e}")))?;

    loop {
        let (buf, _meta) = stream.next()
            .map_err(|e| StreamerError::Camera(format!("Failed to read frame: {e}")))?;

        let frame_data = Bytes::copy_from_slice(buf);
        let frame = CapturedFrame {
            data: frame_data,
            format: pixel_format,
        };

        // Non-blocking send: drop oldest if full
        match tx.try_send(frame) {
            Ok(_) => {}
            Err(mpsc::error::TrySendError::Full(_)) => {
                tracing::warn!("Capture buffer full, dropping frame");
            }
            Err(mpsc::error::TrySendError::Closed(_)) => {
                tracing::info!("Capture channel closed, stopping");
                break;
            }
        }
    }

    Ok(())
}

fn try_set_format(
    dev: &Device,
    config: &CameraConfig,
    fourcc: FourCC,
    pixel_format: PixelFormat,
) -> Result<(FourCC, PixelFormat), StreamerError> {
    // Check if the format is supported
    let fmt = Format::new(config.width, config.height, fourcc);
    dev.set_format(&fmt)
        .map_err(|e| StreamerError::Camera(format!("Format not supported: {e}")))?;
    let actual = dev.format()
        .map_err(|e| StreamerError::Camera(format!("Failed to get format: {e}")))?;
    if actual.fourcc == fourcc {
        tracing::info!("Using pixel format: {pixel_format:?}");
        Ok((fourcc, pixel_format))
    } else {
        Err(StreamerError::Camera("Format not accepted".into()))
    }
}
