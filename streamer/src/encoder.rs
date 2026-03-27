use bytes::Bytes;
use x264::{Setup, Preset, Tune, Colorspace, Image, Plane};
use crate::capture::{CapturedFrame, PixelFormat};
use crate::config::EncoderConfig;
use crate::error::StreamerError;

#[derive(Clone, Copy, Debug)]
pub enum Direction {
    Up,
    Down,
    Left,
    Right,
    Stop,
}

pub enum EncoderCommand {
    ForceKeyframe,
    SetBitrate(u32),
    Move(Direction),
}

pub struct VideoEncoder {
    enc: x264::Encoder,
    pts: i64,
    frame_count: u32,
    keyframe_interval: u32,
    pub force_idr_next: bool,
    pub pending_bitrate: Option<u32>,
}

impl VideoEncoder {
    pub fn apply_command(&mut self, cmd: EncoderCommand) -> &'static str {
        match cmd {
            EncoderCommand::ForceKeyframe => {
                self.force_idr_next = true;
                "force_keyframe"
            }
            EncoderCommand::SetBitrate(kbps) => {
                self.pending_bitrate = Some(kbps);
                "set_bitrate"
            }
            EncoderCommand::Move(_) => "move", // routed to toy controller, not encoder
        }
    }
}

pub struct NalUnit {
    pub is_keyframe: bool,
    pub data: Bytes,
}

pub fn create_encoder(config: &EncoderConfig, width: u32, height: u32) -> Result<VideoEncoder, StreamerError> {
    let enc = Setup::preset(Preset::Ultrafast, Tune::None, false, true)
        .bitrate(config.bitrate_kbps as i32)
        .keyint_max(config.keyframe_interval as i32)
        .bframes(0)
        .repeat_headers(true)
        .baseline()
        .build(Colorspace::I420, width as i32, height as i32)
        .map_err(|_| StreamerError::Encoder("Failed to create encoder".into()))?;

    Ok(VideoEncoder {
        enc,
        pts: 0,
        frame_count: 0,
        keyframe_interval: config.keyframe_interval,
        force_idr_next: false,
        pending_bitrate: None,
    })
}

pub fn encode_frame(
    _config: &EncoderConfig,
    enc: &mut VideoEncoder,
    frame: CapturedFrame,
    width: u32,
    height: u32,
) -> Result<Vec<NalUnit>, StreamerError> {
    // Apply pending bitrate change: rebuild encoder with new bitrate.
    if let Some(kbps) = enc.pending_bitrate.take() {
        match Setup::preset(Preset::Ultrafast, Tune::None, false, true)
            .bitrate(kbps as i32)
            .keyint_max(enc.keyframe_interval as i32)
            .bframes(0)
            .repeat_headers(true)
            .baseline()
            .build(Colorspace::I420, width as i32, height as i32)
        {
            Ok(new_enc) => {
                enc.enc = new_enc;
                enc.pts = 0;
                enc.frame_count = 0;
                tracing::info!("Encoder rebuilt with bitrate {kbps} kbps");
            }
            Err(_) => tracing::warn!("Failed to rebuild encoder for bitrate change"),
        }
    }

    let yuv = match frame.format {
        PixelFormat::Yuyv => yuyv_to_yuv420p(&frame.data, width, height)?,
        PixelFormat::Mjpeg => mjpeg_to_yuv420p(&frame.data)?,
    };

    let image = Image::new(
        Colorspace::I420,
        width as i32,
        height as i32,
        &[
            Plane { data: &yuv.y, stride: width as i32 },
            Plane { data: &yuv.u, stride: (width / 2) as i32 },
            Plane { data: &yuv.v, stride: (width / 2) as i32 },
        ],
    );

    let pts = enc.pts;
    let force_idr = enc.force_idr_next || enc.frame_count % enc.keyframe_interval == 0;
    if enc.force_idr_next {
        enc.force_idr_next = false;
        tracing::info!("IDR forced");
    }

    let (nals, _) = if force_idr {
        enc.enc.encode_idr(pts, image)
    } else {
        enc.enc.encode(pts, image)
    }.map_err(|_| StreamerError::Encoder("encode failed".into()))?;

    enc.pts += 1;
    enc.frame_count += 1;

    let mut result = Vec::new();
    for i in 0..nals.len() {
        let unit = nals.unit(i);
        let payload: &[u8] = unit.as_ref();
        // NAL unit type = bits 0-4 of byte 4 (Annex-B: [0x00 0x00 0x00 0x01][nal header])
        let is_keyframe = payload.len() > 4 && (payload[4] & 0x1F) == 5;
        result.push(NalUnit {
            is_keyframe,
            data: Bytes::from(payload.to_vec()),
        });
    }

    Ok(result)
}

struct Yuv420p {
    y: Vec<u8>,
    u: Vec<u8>,
    v: Vec<u8>,
}

fn yuyv_to_yuv420p(data: &[u8], width: u32, height: u32) -> Result<Yuv420p, StreamerError> {
    let w = width as usize;
    let h = height as usize;
    let expected = w * h * 2;
    if data.len() < expected {
        return Err(StreamerError::Encoder(format!(
            "YUYV data too short: got {} bytes, expected {expected}", data.len()
        )));
    }

    let mut y_plane = vec![0u8; w * h];
    let mut u_plane = vec![0u8; (w / 2) * (h / 2)];
    let mut v_plane = vec![0u8; (w / 2) * (h / 2)];

    for row in 0..h {
        for col in 0..(w / 2) {
            let src_idx = (row * w + col * 2) * 2;
            let y0 = data[src_idx];
            let u0 = data[src_idx + 1];
            let y1 = data[src_idx + 2];
            let v0 = data[src_idx + 3];

            y_plane[row * w + col * 2] = y0;
            y_plane[row * w + col * 2 + 1] = y1;

            if row % 2 == 0 {
                let uv_idx = (row / 2) * (w / 2) + col;
                u_plane[uv_idx] = u0;
                v_plane[uv_idx] = v0;
            }
        }
    }

    Ok(Yuv420p { y: y_plane, u: u_plane, v: v_plane })
}

fn mjpeg_to_yuv420p(data: &[u8]) -> Result<Yuv420p, StreamerError> {
    let mut decoder = jpeg_decoder::Decoder::new(std::io::Cursor::new(data));
    let pixels = decoder.decode()
        .map_err(|e| StreamerError::Encoder(format!("JPEG decode error: {e}")))?;
    let info = decoder.info()
        .ok_or_else(|| StreamerError::Encoder("No JPEG info available".into()))?;

    let w = info.width as usize;
    let h = info.height as usize;

    if pixels.len() != w * h * 3 {
        return Err(StreamerError::Encoder(format!(
            "Unexpected pixel count: {} (expected {})", pixels.len(), w * h * 3
        )));
    }

    let mut y_plane = vec![0u8; w * h];
    let mut u_plane = vec![0u8; (w / 2) * (h / 2)];
    let mut v_plane = vec![0u8; (w / 2) * (h / 2)];

    for row in 0..h {
        for col in 0..w {
            let idx = (row * w + col) * 3;
            let r = pixels[idx] as f32;
            let g = pixels[idx + 1] as f32;
            let b = pixels[idx + 2] as f32;

            let y = (0.299 * r + 0.587 * g + 0.114 * b) as u8;
            y_plane[row * w + col] = y;

            if row % 2 == 0 && col % 2 == 0 {
                let u = ((-0.169 * r - 0.331 * g + 0.5 * b) + 128.0) as u8;
                let v = ((0.5 * r - 0.419 * g - 0.081 * b) + 128.0) as u8;
                let uv_idx = (row / 2) * (w / 2) + col / 2;
                u_plane[uv_idx] = u;
                v_plane[uv_idx] = v;
            }
        }
    }

    Ok(Yuv420p { y: y_plane, u: u_plane, v: v_plane })
}
