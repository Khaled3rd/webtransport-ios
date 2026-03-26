# WebTransport Video Streaming — Relay & Streamer

Ultra-low latency H264 video streaming over WebTransport (QUIC/HTTP3).

```
Camera (Linux)  →  Streamer  →  Relay  →  iOS App (WKWebView + AVSampleBufferDisplayLayer)
  lviv_laptop       ~/streamer    ruh.sunbour.com:4433       iPhone / iPad
```

Frames travel on a single persistent unidirectional QUIC stream with a simple length-prefix framing:

```
[4 bytes: frame length, big-endian uint32]
[1 byte:  flags  (0x01 = keyframe, 0x00 = delta)]
[N bytes: all NAL units in Annex-B format, concatenated]
```

---

## Repository Layout

```
ios-app/                  Swift source — iOS receiver app
WebTransport.xcodeproj/   Xcode project file
relay/                    Rust WebTransport relay server (wtransport 0.4, vendored)
streamer/                 Rust V4L2 → x264 → WebTransport streamer (vendored x264 + wtransport)
```

---

## Relay

### What it does

- Listens on UDP/QUIC port 4433 (WebTransport)
- `/publish` — accepts one authenticated publisher (the streamer)
- `/watch`   — accepts up to `max_subscribers` viewers (iOS clients, browsers)
- Fans every incoming frame out to all active subscribers in real time
- Generates a self-signed P-256 TLS certificate on first run; reuses it on restart
- Exposes `GET /health` on TCP port 4434 (JSON status)

### Prerequisites

| Tool | Version |
|------|---------|
| Rust + Cargo | 1.76+ (`rustup update stable`) |
| OS | Linux (tested on Ubuntu 22.04) |

No system libraries required — all crypto and QUIC code is vendored.

### Build

```bash
cd relay
cargo build --release
# binary: target/release/relay
```

### Configuration — `config.toml`

```toml
[server]
bind            = "0.0.0.0:4433"   # UDP port for WebTransport (QUIC)
publish_path    = "/publish"        # URL path the streamer connects to
subscribe_path  = "/watch"          # URL path viewers connect to
publish_token   = "change-me"       # Bearer token required by the streamer
max_subscribers = 50                # Maximum simultaneous viewers

[tls]
cert_path           = "/home/b/.relay/cert.pem"   # Created automatically if missing
key_path            = "/home/b/.relay/key.pem"    # Created automatically if missing
cert_validity_days  = 14                           # WebTransport requires ≤ 14 days
```

> **TLS note**: WebTransport's `serverCertificateHashes` pinning requires the certificate
> validity period to be **14 days or less**. The relay generates a fresh cert automatically
> when none is found at the configured paths. Rotate the cert (and update the iOS app's
> fingerprint) before it expires.

### Run

```bash
# Default config file: config.toml in the current directory
./target/release/relay

# Custom config path
./target/release/relay --config /etc/relay/config.toml

# With verbose logging
RUST_LOG=info ./target/release/relay
RUST_LOG=debug ./target/release/relay   # very noisy
```

### Get the TLS fingerprint

The relay prints the SHA-256 fingerprint at startup:

```
INFO relay: TLS cert fingerprint (SHA-256): DC:76:40:8B:42:7D:...
```

You need this value in two places:
1. The iOS app's `Configuration.swift` → `certFingerprint`
2. The streamer's `config.toml` → `[relay] cert_fingerprint`

To extract it from an existing cert without restarting:

```bash
openssl x509 -in ~/.relay/cert.pem -noout -fingerprint -sha256 \
  | sed 's/.*Fingerprint=//' | tr '[:lower:]' '[:upper:]'
```

### Rotate the certificate

```bash
rm ~/.relay/cert.pem ~/.relay/key.pem
./target/release/relay   # generates a new cert on startup
```

Then update `cert_fingerprint` in the streamer's `config.toml` and the iOS app's
`Configuration.swift`, then rebuild the iOS app.

### Health check

```bash
curl http://localhost:4434/health
# {"publisher_connected":true,"status":"ok","subscribers":1}
```

### Run as a systemd service

```ini
# /etc/systemd/system/relay.service
[Unit]
Description=WebTransport Relay
After=network.target

[Service]
User=b
WorkingDirectory=/home/b/relay
ExecStart=/home/b/relay/target/release/relay --config /home/b/relay/config.toml
Restart=always
RestartSec=3
Environment=RUST_LOG=info

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now relay
sudo journalctl -u relay -f
```

---

## Streamer

### What it does

- Opens a V4L2 camera (YUYV or MJPEG)
- Encodes frames with x264 (H.264 baseline, zero-latency tuning)
- Connects to the relay's `/publish` endpoint over WebTransport
- Sends all NAL units for each frame bundled on one persistent unidirectional stream

### Prerequisites

| Tool | Version |
|------|---------|
| Rust + Cargo | 1.76+ |
| clang / libclang | Required by `x264-sys` bindgen |
| OS | Linux with V4L2 (tested on Ubuntu 20.04) |
| Camera | Any V4L2 device that supports YUYV or MJPEG at the configured resolution |

```bash
# Ubuntu / Debian
sudo apt install clang libclang-dev
```

> **Compiler note**: Build with `clang`, not GCC. GCC 9.x has a bug that triggers a
> miscompile in `aws-lc-sys`. The `CC=clang` prefix below handles this.

### Build

```bash
cd streamer
CC=clang cargo build --release
# binary: target/release/streamer
```

### Configuration — `config.toml`

```toml
[camera]
device        = "/dev/video0"   # V4L2 device path
width         = 1280            # Capture width in pixels
height        = 720             # Capture height in pixels
fps           = 30              # Requested frame rate
pixel_format  = "YUYV"         # "YUYV" or "MJPEG"

[encoder]
profile           = "baseline"    # H.264 profile (baseline required for iOS hardware decode)
tune              = "zerolatency" # Disable lookahead buffering
bitrate_kbps      = 2000          # Target bitrate in kbps
keyframe_interval = 30            # IDR frame every N frames (forced via x264 API)

[relay]
url                 = "https://ruh.sunbour.com:4433/publish"
token               = "change-me"          # Must match relay's publish_token
cert_fingerprint    = "DC:76:40:..."       # SHA-256 of relay TLS cert (colon-separated uppercase hex)
```

### Run

```bash
# Default config file: config.toml in current directory
./target/release/streamer

# Custom config
./target/release/streamer --config /etc/streamer/config.toml

# With logging
RUST_LOG=info ./target/release/streamer
```

The streamer reconnects automatically if the relay is unavailable or the connection drops.

### List available cameras and formats

```bash
# List V4L2 devices
v4l2-ctl --list-devices

# Show supported formats and resolutions
v4l2-ctl -d /dev/video0 --list-formats-ext
```

### Kill a stale streamer process

Only one streamer can be connected to the relay at a time. If a previous instance is
still running:

```bash
pkill -9 -f "target/release/streamer"
```

---

## iOS App

### What it does

- Receives the live H264 stream from the relay over WebTransport
- Displays video full-screen with a blinking **LIVE** badge when connected
- Reconnects automatically on disconnect

### Requirements

| Tool | Version |
|------|---------|
| Xcode | 16+ (tested on Xcode 26.3) |
| iOS deployment target | iOS 17+ (tested on iOS 26.2) |
| Device | Physical iPhone or iPad (WebTransport is not available in the Simulator) |

### Project structure

```
ios-app/
  Configuration.swift      Relay URL + TLS cert fingerprint
  WebTransportApp.swift    App entry point (@main)
  ContentView.swift        Root view — composes all components
  WebTransportView.swift   Hidden WKWebView running the JS WebTransport client
  WebTransportBridge.swift WKScriptMessageHandler — bridges JS frames to H264Decoder
  H264Decoder.swift        Annex-B parser → AVCC CMSampleBuffer builder
  StreamRenderer.swift     AVSampleBufferDisplayLayer SwiftUI wrapper
  NalRingBuffer.swift      Ring buffer for NAL assembly
  webtransport.html        Reference JS client (not loaded by the app — see below)
WebTransport.xcodeproj/    Xcode project (PBXFileSystemSynchronizedRootGroup)
```

### Configuration — `Configuration.swift`

The only file you need to edit before building:

```swift
enum Configuration {
    static let relayURL        = "https://your-relay-host:4433/watch"
    static let certFingerprint = "DC:76:40:8B:42:7D:..."  // from relay startup log
}
```

`certFingerprint` must be the **colon-separated uppercase SHA-256** of the relay's
self-signed TLS cert. The relay prints it at startup:

```
INFO relay: TLS cert fingerprint (SHA-256): DC:76:40:8B:42:7D:...
```

Update this value (and rebuild the app) every time the relay cert is rotated.

### Build & run

1. Open `WebTransport.xcodeproj` in Xcode.
2. Select your iPhone/iPad as the run destination (not a Simulator).
3. Set your Development Team in **Signing & Capabilities**.
4. Edit `Configuration.swift` with your relay URL and cert fingerprint.
5. Press **Run** (⌘R).

### How it works

```
WKWebView (1×1 px, invisible)
  │  JS opens WebTransport to relay /watch
  │  Reads one persistent unidirectional stream
  │  Parses [4B length][1B flags][Annex-B NALs] frames
  │  Posts base64 frame strings to Swift via webkit.messageHandlers.frame
  ▼
WebTransportBridge  (WKScriptMessageHandler, @MainActor)
  │  Base64-decodes the payload
  │  Calls H264Decoder.decode(payload:)
  ▼
H264Decoder  (@MainActor)
  │  Finds Annex-B NAL boundaries (0x000001 / 0x00000001 start codes)
  │  Extracts SPS (type 7) and PPS (type 8) → builds CMVideoFormatDescription
  │  Packs VCL NALs (type 1 / 5) into AVCC CMSampleBuffer
  │    • malloc-owned memory so AVSampleBufferDisplayLayer can retain it
  │    • kCMSampleAttachmentKey_DisplayImmediately set to bypass PTS scheduling
  │  Calls onSampleBuffer(sampleBuffer)
  ▼
StreamRenderer / VideoDisplayLayer
     AVSampleBufferDisplayLayer.enqueue(_:)
     → hardware H264 decode → screen
```

No `VTDecompressionSession` is used. `AVSampleBufferDisplayLayer` accepts AVCC H264
`CMSampleBuffer`s directly and handles all decoding internally.

> **Note on `webtransport.html`**: This file is a standalone reference copy of the JS
> client. The app does **not** load it from disk — the JS is baked directly into the
> HTML string inside `WebTransportView.swift`'s `buildHTML()` function. This avoids
> WKWebView sandbox errors (`Could not create a sandbox extension`) that occur with
> `loadFileURL`. If you modify the JS, edit `WebTransportView.swift`.

### Expected log output (healthy stream)

```
[WT] status: connected
[bridge] frame #1 size=3210 header=1
[decoder] payload=3210B header=1 nals=11
[decoder] SPS size=22
[decoder] PPS size=4
[decoder] format description built OK
[decoder] submitFrame pts=0 vclNals=9
[renderer] enqueued frame, layer status: 0
[bridge] frame #2 size=820 header=0
[decoder] submitFrame pts=1 vclNals=8
[renderer] enqueued frame, layer status: 0
```

`header=1` = keyframe, `header=0` = delta frame, `layer status: 0` = rendering OK.

---

## End-to-End Startup Sequence

```
# 1. Start the relay (Riyadh server)
RUST_LOG=info ./relay/target/release/relay

# 2. Note the fingerprint printed at startup, update configs if rotated

# 3. Start the streamer (camera machine)
RUST_LOG=info ./streamer/target/release/streamer

# 4. Verify both are connected
curl http://<relay-host>:4434/health
# → {"publisher_connected":true,"status":"ok","subscribers":0}

# 5. Open the iOS app — video should appear within 1-2 seconds
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `publisher rejected: already connected` | Stale streamer process | `pkill -9 -f streamer` |
| `Could not automatically determine CryptoProvider` | Missing rustls init | Already fixed in `main.rs` — rebuild |
| No video on iOS, relay shows subscriber | Old JS still cached in WKWebView | Clean build + reinstall iOS app |
| Streamer exits immediately | Token mismatch or relay cert fingerprint wrong | Check `config.toml` on both sides |
| Cert expired (>14 days) | WebTransport rejects expired cert | Rotate cert, update fingerprint |
| Low FPS (< 15 fps) | High RTT + QUIC flow control | Lower `bitrate_kbps`; reduce resolution |
| `Capture buffer full` warnings | Encoder faster than network | Normal under congestion; frames are dropped gracefully |

---

## Architecture Notes

- **Vendored dependencies**: Both crates vendor `wtransport 0.4` (with a patch to
  `driver/utils.rs` for `stream_id` conversion) and `x264 0.3 / x264-sys 0.1`.
  No network access required to build.
- **Single persistent stream**: Each publisher→relay and relay→subscriber connection
  uses exactly one long-lived unidirectional QUIC stream. This eliminates per-frame
  stream-setup RTT overhead and achieves near-realtime latency even at 120 ms RTT.
- **Backpressure handling**: The streamer uses non-blocking `try_send` into the NAL
  channel. Frames are silently dropped on a full channel rather than blocking the
  encoder, preserving real-time behaviour under congestion.
- **Keyframe forcing**: IDR frames are forced via `x264_encoder_encode` with
  `X264_TYPE_IDR` every `keyframe_interval` frames. `keyint_max` alone is unreliable
  with the zerolatency tune.
