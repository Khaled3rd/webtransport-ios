# WebTransport Video Streaming — Relay & Streamer

Ultra-low latency H264 video streaming over WebTransport (QUIC/HTTP3) with a
bidirectional command channel for remote control.

```
Camera (Linux)  →  Streamer  →  Relay  →  iOS App
  lviv_laptop       ~/streamer    ruh.sunbour.com:4433    iPhone / iPad
  Raspberry Pi                                            PC Browser (viewer.html)
                        ↑                    ↓
                   toy_controller.py  ←  D-pad commands
```

---

## Streams

### Video (unidirectional, relay → iOS)

Each frame travels on a single persistent unidirectional QUIC stream:

```
[4 bytes: frame length, big-endian uint32]
[1 byte:  flags  (0x01 = keyframe, 0x00 = delta)]
[N bytes: all NAL units in Annex-B format, concatenated]
```

### Commands (bidirectional, relay ↔ iOS ↔ Streamer)

A single persistent bidirectional QUIC stream carries commands from iOS to the
streamer and responses back. The relay opens the stream to iOS (server-initiated),
and the streamer opens one to the relay.

| Leg | Direction | Wire format |
|-----|-----------|-------------|
| iOS → Relay | bidi send | `[4B len][JSON]` |
| Relay → iOS | bidi recv | `[4B len][JSON]` |
| Relay → Streamer | bidi send | `[8B sub_id][4B len][JSON]` |
| Streamer → Relay | bidi recv | `[8B sub_id][4B len][JSON]` |

**Command JSON (iOS → Streamer):**

```json
{"cmd": "force_keyframe"}
{"cmd": "set_bitrate", "kbps": 2000}
{"cmd": "move_start", "dir": "up"}
{"cmd": "move_start", "dir": "down"}
{"cmd": "move_start", "dir": "left"}
{"cmd": "move_start", "dir": "right"}
{"cmd": "move_stop"}
```

**Response JSON (Streamer → iOS):**

```json
{"ok": true, "cmd": "force_keyframe"}
{"ok": true, "cmd": "set_bitrate"}
```

Move commands are fire-and-forget (routed to the toy controller, no response to iOS).

---

## Repository Layout

```
ios-app/                  Swift source — iOS receiver app
WebTransport.xcodeproj/   Xcode project file
relay/                    Rust WebTransport relay server (wtransport 0.4, vendored)
streamer/                 Rust V4L2 → x264 → WebTransport streamer (vendored x264 + wtransport)
toy_controller.py         Python script — receives move commands via Unix socket, drives motors
viewer.html               Browser viewer — WebTransport + WebCodecs H.264, D-pad, encoder controls
deploy.sh                 One-shot deploy script — installs, builds, and configures relay or streamer
```

---

## Quick Deploy (`deploy.sh`)

`deploy.sh` handles everything end-to-end over SSH: installs system packages, installs
Rust, syncs the source, writes a `config.toml`, sets up TLS, builds the binary, installs
a systemd service, and starts it. Run it from your dev machine.

```bash
chmod +x deploy.sh

./deploy.sh relay                               # deploy relay (default: Riyadh_laptop)
./deploy.sh streamer                            # deploy streamer (default: lviv_laptop)
./deploy.sh streamer --host pi@192.168.1.42     # deploy streamer to a Raspberry Pi
./deploy.sh both                                # deploy relay + streamer in sequence
./deploy.sh                                     # interactive menu
```

**Options:**

| Flag | Description |
|------|-------------|
| `--host HOST` | SSH destination (`user@host` or `~/.ssh/config` alias) |
| `--dir DIR` | Remote working directory (default: `~/relay` or `~/streamer`) |
| `--force-config` | Overwrite an existing `config.toml` on the remote |
| `--no-service` | Skip systemd service installation |

The script prompts for token, bitrate, resolution, etc. with sensible defaults. It
auto-detects Raspberry Pi models and suggests lower resolution defaults for Pi 3 / Zero.
Re-running is safe — it skips steps that are already complete (existing config, existing
packages, etc.) and always rebuilds the binary.

---

## Relay

### What it does

- Listens on UDP/QUIC port 4433 (WebTransport)
- `/publish` — accepts one authenticated publisher (the streamer)
- `/watch`   — accepts up to `max_subscribers` viewers (iOS clients, browsers)
- Fans every incoming video frame out to all active subscribers in real time
- Routes commands from each iOS subscriber to the publisher (streamer) with sub ID
- Routes responses from the streamer back to the originating subscriber
- Uses a CA-signed TLS certificate (Let's Encrypt) for standard trust — no cert pinning required
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
cert_path           = "/home/b/.relay/cert.pem"   # Path to PEM certificate (fullchain)
key_path            = "/home/b/.relay/key.pem"    # Path to PEM private key
cert_validity_days  = 14                           # Only used when auto-generating a self-signed cert
```

> **TLS note**: The relay loads whatever cert is at the configured paths. Point these at
> your Let's Encrypt `fullchain.pem` and `privkey.pem` for standard CA validation — no
> cert pinning or app rebuilds needed on renewal. If the files are missing the relay
> generates a temporary self-signed cert automatically.

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

### TLS certificate setup (Let's Encrypt)

Copy the Let's Encrypt cert into the relay's cert directory once (requires sudo):

```bash
sudo cp /etc/letsencrypt/live/your-domain/fullchain.pem /home/b/.relay/cert.pem
sudo cp /etc/letsencrypt/live/your-domain/privkey.pem   /home/b/.relay/key.pem
sudo chown b:b /home/b/.relay/cert.pem /home/b/.relay/key.pem
```

Set up a certbot deploy hook so the relay cert is updated automatically on renewal:

```bash
sudo tee /etc/letsencrypt/renewal-hooks/deploy/relay.sh << 'EOF'
#!/bin/bash
cp /etc/letsencrypt/live/your-domain/fullchain.pem /home/b/.relay/cert.pem
cp /etc/letsencrypt/live/your-domain/privkey.pem   /home/b/.relay/key.pem
chown b:b /home/b/.relay/cert.pem /home/b/.relay/key.pem
pkill -HUP relay 2>/dev/null || true
EOF
sudo chmod +x /etc/letsencrypt/renewal-hooks/deploy/relay.sh
```

With a CA-signed cert in place, no fingerprint configuration is needed anywhere —
the iOS app and streamer both use standard TLS validation.

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
- Opens a bidirectional stream to the relay for the command channel
- Accepts `force_keyframe` and `set_bitrate` commands from iOS subscribers
- Forwards `move_start`/`move_stop` commands to `toy_controller.py` via Unix domain socket

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
url   = "https://your-relay-host:4433/publish"
token = "change-me"   # Must match relay's publish_token
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

## Running the Streamer on Raspberry Pi

The streamer compiles and runs on Raspberry Pi. Pick a build path below based on
what is most convenient, then tune the config for your board.

### Platform compatibility

| Board | CPU | RAM | Recommended OS | Rust target |
|---|---|---|---|---|
| RPi 3 B / 3 B+ v1.2 | Cortex-A53 | 1 GB | Pi OS 64-bit (Bookworm) | `aarch64-unknown-linux-gnu` |
| RPi 4 B | Cortex-A72 | 2–8 GB | Pi OS 64-bit (Bookworm) | `aarch64-unknown-linux-gnu` |

Use the **64-bit OS image** on both boards — same Rust target for both, x264 gets
proper ARM64 NEON SIMD, and `ring` (used by rustls) has better support on `aarch64`
than on 32-bit `armv7`.

---

### Option A — Build directly on the Pi (simplest, most reliable)

Works on both boards. No toolchain setup on your dev machine. Compile time is
~10 min on Pi 4 and ~30–40 min on Pi 3.

```bash
# 1. Install build dependencies
sudo apt update
sudo apt install -y clang libclang-dev cmake make git

# 2. Install Rust
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source ~/.cargo/env

# 3. Copy the streamer source to the Pi (from your dev machine)
rsync -av ios/streamer/ pi@raspberrypi:~/streamer/
# — or use scp, git clone, USB stick, etc.

# 4. Build  (CC=clang avoids a GCC memcmp issue in ring's C code)
cd ~/streamer
CC=clang cargo build --release

# 5. Run
RUST_LOG=info ./target/release/streamer config.toml
```

> `nasm` is **not** required on ARM. x264 uses ARM assembly via `gas`, not NASM.

---

### Option B — Cross-compile with `cross` (faster compile, runs on your dev machine)

`cross` uses Docker to provide the correct ARM64 C toolchain. Run this on your
Linux x86\_64 or macOS machine.

The streamer depends on system-installed `libx264` and `libv4l2`. The `Cross.toml`
already checked in at `ios/streamer/Cross.toml` installs them into the cross container
automatically.

```bash
# 1. Install Docker Desktop (macOS) or Docker Engine (Linux)

# 2. Install cross
cargo install cross

# 3. Add the ARM64 Rust target
rustup target add aarch64-unknown-linux-gnu

# 4. Build from inside ios/streamer/
#    Cross.toml installs libx264-dev + libv4l-dev into the container for you.
cd ios/streamer
cross build --release --target aarch64-unknown-linux-gnu

# 5. Copy binary to the Pi
scp target/aarch64-unknown-linux-gnu/release/streamer pi@raspberrypi:~/
```

> **If cross fails** (rare with vendored crates + ring): fall back to Option A.
> The native build on Pi is fully reliable.

For 32-bit Pi OS (armv7, not recommended):

```bash
rustup target add armv7-unknown-linux-gnueabihf
cross build --release --target armv7-unknown-linux-gnueabihf
```

---

### Option C — Cross-compile from macOS using `zig cc` (advanced / limited)

> **Not recommended for most users.** The streamer links against `libx264` and
> `libv4l2`, which are Linux C libraries. Option C only handles the Rust→ARM64
> compilation; you must also cross-compile those C libraries from source or obtain
> ARM64 static builds. **Option B (Docker + cross) handles this automatically via
> `Cross.toml`.** Option C is only worth pursuing if Docker is unavailable.

`zig` acts as a drop-in ARM64 C cross-compiler without installing a full GNU toolchain.

```bash
# 1. Install zig and add the Rust ARM64 target
brew install zig llvm
rustup target add aarch64-unknown-linux-gnu

# 2. Create a wrapper script — must filter out flags zig doesn't understand.
#    Cargo (and crates like ring) pass --target=aarch64-unknown-linux-gnu
#    (Rust triple), which conflicts with zig's own -target flag.
#    macOS flags -arch ARCH and -mmacosx-version-min=X must also be dropped.
#    /usr/local/bin is root-owned — use sudo tee.
sudo tee /usr/local/bin/zig-aarch64-cc << 'EOF'
#!/bin/bash
args=()
skip_next=0
for a in "$@"; do
  if (( skip_next )); then skip_next=0; continue; fi
  case "$a" in
    --target=*|-mmacosx-version-min=*) ;;  # Rust/macOS triples zig rejects
    -arch) skip_next=1 ;;                  # two-word macOS flag; skip flag + value
    *) args+=("$a") ;;
  esac
done
exec zig cc -target aarch64-linux-gnu "${args[@]}"
EOF
sudo chmod +x /usr/local/bin/zig-aarch64-cc

# 3. Tell Cargo to use it
mkdir -p ios/streamer/.cargo
cat > ios/streamer/.cargo/config.toml << 'EOF'
[target.aarch64-unknown-linux-gnu]
linker = "/usr/local/bin/zig-aarch64-cc"
EOF

# 4. Install Linux headers for bindgen.
#    x264-sys and v4l2-sys-mit run bindgen at build time and need Linux C and
#    kernel UAPI headers (inttypes.h, linux/videodev2.h) which are absent on macOS.
#
#    zig ≤ 0.13 bundled these headers inside its lib directory.
#    zig 0.14+ no longer includes them — use musl-cross instead, which ships a
#    complete ARM64 sysroot (musl libc + Linux kernel UAPI headers).

brew tap FiloSottile/musl-cross
brew install musl-cross --with-aarch64 --without-x86_64

MUSL_INC="$(brew --prefix musl-cross)/libexec/aarch64-linux-musl/include"
test -f "${MUSL_INC}/inttypes.h"            && echo "libc OK"   || echo "ERROR: musl-cross headers missing at ${MUSL_INC}"
test -f "${MUSL_INC}/linux/videodev2.h"     && echo "linux OK"  || echo "ERROR: Linux UAPI headers missing at ${MUSL_INC}/linux/"

# Use Homebrew LLVM's libclang (not Xcode's) — Xcode's has a #include_next
# issue in its inttypes.h when the target is Linux.
export LIBCLANG_PATH="$(brew --prefix llvm)/lib"
export BINDGEN_EXTRA_CLANG_ARGS="--target=aarch64-linux-gnu -isystem ${MUSL_INC}"

# 5. Build
cd ios/streamer
CC="/usr/local/bin/zig-aarch64-cc" \
CXX="zig c++ -target aarch64-linux-gnu" \
AR="$(brew --prefix llvm)/bin/llvm-ar" \
cargo build --release --target aarch64-unknown-linux-gnu

# 6. Copy to Pi
scp target/aarch64-unknown-linux-gnu/release/streamer pi@raspberrypi:~/
```

> `zig cc` can occasionally fail on complex C code in `ring` or `x264-sys`. If it does,
> use Option A or B.

---

### Configuration per board

**Raspberry Pi 3 B — reduce resolution and fps**

The encoder is hardcoded to `Preset::Ultrafast`, which is already the fastest x264 mode.
At 480p / 15 fps, CPU usage is roughly 60–80% of one core.

```toml
[camera]
device        = "/dev/video0"
width         = 640
height        = 480
fps           = 15
pixel_format  = "MJPEG"      # MJPEG reduces USB bandwidth vs YUYV

[encoder]
profile           = "baseline"
tune              = "zerolatency"
bitrate_kbps      = 800
keyframe_interval = 15        # match fps

[relay]
url   = "https://your-relay-host:4433/publish"
token = "change-me"
```

**Raspberry Pi 4 B — 720p capable**

```toml
[camera]
device        = "/dev/video0"
width         = 1280
height        = 720
fps           = 30
pixel_format  = "MJPEG"

[encoder]
profile           = "baseline"
tune              = "zerolatency"
bitrate_kbps      = 2000
keyframe_interval = 30

[relay]
url   = "https://your-relay-host:4433/publish"
token = "change-me"
```

---

### Camera options on Pi

**USB webcam** — plug in and it appears at `/dev/video0`. Use MJPEG to reduce USB
bandwidth (YUYV at 720p / 30fps saturates USB 2.0):

```bash
v4l2-ctl --list-devices                  # show all V4L2 devices
v4l2-ctl -d /dev/video0 --list-formats-ext  # show supported formats / resolutions
```

**Pi Camera Module v1 / v2** — must be enabled before it appears as a V4L2 device:

```bash
# Pi OS Bullseye — enable Legacy Camera in raspi-config
sudo raspi-config
# → Interface Options → Legacy Camera → Enable
# Reboot; camera appears at /dev/video0

# Pi OS Bookworm — Legacy Camera is removed; use libcamera-vid + v4l2loopback instead:
sudo apt install -y v4l2loopback-dkms
sudo modprobe v4l2loopback video_nr=10
libcamera-vid --width 640 --height 480 --framerate 15 \
              --codec yuv420 -t 0 --output - \
              | ffmpeg -f rawvideo -pix_fmt yuv420p -s 640x480 -r 15 -i - \
                       -f v4l2 /dev/video10
# Then set device = "/dev/video10" in config.toml, pixel_format = "YUYV"
```

---

### Run as a systemd service on Pi

```ini
# /etc/systemd/system/streamer.service
[Unit]
Description=WebTransport Streamer
After=network-online.target
Wants=network-online.target

[Service]
User=pi
WorkingDirectory=/home/pi/streamer
ExecStart=/home/pi/streamer/target/release/streamer --config /home/pi/streamer/config.toml
Restart=always
RestartSec=5
Environment=RUST_LOG=info

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now streamer
sudo journalctl -u streamer -f
```

---

### Advanced: Hardware H.264 encoder (Raspberry Pi 4 only)

RPi 4 exposes a hardware H.264 encoder via the V4L2 memory-to-memory (M2M) API at
`/dev/video11` (`bcm2835-codec`). Hardware encoding uses ~5% CPU versus ~60% for x264
at 720p, and produces the same Annex-B output format the relay already expects.

**The current codebase uses x264 (software) on all platforms.** Switching to the
hardware encoder requires replacing `encoder.rs` with V4L2 M2M API calls:

1. Open `/dev/video11` as a V4L2 M2M device.
2. Set **output** format: `V4L2_PIX_FMT_YUV420` at the desired resolution.
3. Set **capture** format: `V4L2_PIX_FMT_H264`.
4. Set bitrate control via `V4L2_CID_MPEG_VIDEO_BITRATE` and profile via
   `V4L2_CID_MPEG_VIDEO_H264_PROFILE`.
5. Call `VIDIOC_STREAMON` on both queues; feed YUV frames to the output queue;
   read H.264 NAL units from the capture queue.
6. Detect keyframes from `V4L2_BUF_FLAG_KEYFRAME` on capture buffers.

The `v4l` crate already in `Cargo.toml` covers capture, but V4L2 M2M encoding needs
either direct `ioctl` calls or a dedicated crate. This is a significant rewrite and
is not yet implemented.

---

## Toy Controller

`toy_controller.py` is a Python script that runs on the same machine as the streamer
and receives directional drive commands via a Unix domain socket.

### Protocol

The streamer sends JSON datagrams to `/tmp/toy.sock`:

```json
{"d": "u"}   // forward
{"d": "d"}   // backward
{"d": "l"}   // turn left
{"d": "r"}   // turn right
{"d": "s"}   // stop
```

### Run

```bash
python3 ~/toy_controller.py
# [toy] listening on /tmp/toy.sock
```

Start this **before** the streamer so the socket is ready when the first move command arrives.
The streamer silently ignores send errors if the controller is not running.

### Add hardware control

Edit the `drive()` function in `toy_controller.py` and add your GPIO / motor calls:

```python
def drive(direction: str) -> None:
    if direction == "u":
        left_motor.forward(); right_motor.forward()
    elif direction == "d":
        left_motor.backward(); right_motor.backward()
    elif direction == "l":
        left_motor.backward(); right_motor.forward()
    elif direction == "r":
        left_motor.forward(); right_motor.backward()
    else:  # stop
        left_motor.stop(); right_motor.stop()
```

### Test without iOS

Send a test datagram directly from the terminal on the streamer machine:

```bash
python3 -c "
import socket, json
s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
s.sendto(json.dumps({'d': 'u'}).encode(), '/tmp/toy.sock')
"
# → [toy] FORWARD
```

---

## iOS App

### What it does

- Receives the live H264 stream from the relay over WebTransport
- Displays video full-screen with a blinking **LIVE** badge when connected
- Reconnects automatically on disconnect
- Slide-up command panel with:
  - **D-pad** — press and hold any direction to drive the toy; release to stop
  - **Force Keyframe** — requests an IDR frame immediately
  - **Bitrate selector** — switches encoder bitrate to 500 / 1000 / 2000 / 4000 kbps

### Requirements

| Tool | Version |
|------|---------|
| Xcode | 16+ (tested on Xcode 26.3) |
| iOS deployment target | iOS 17+ (tested on iOS 26.2) |
| Device | Physical iPhone or iPad (WebTransport is not available in the Simulator) |

### Project structure

```
ios-app/
  Configuration.swift      Relay URL
  WebTransportApp.swift    App entry point (@main)
  ContentView.swift        Root view — video, command panel, D-pad, response toast
  WebTransportView.swift   Hidden WKWebView running the JS WebTransport client
  WebTransportBridge.swift WKScriptMessageHandler — bridges JS frames/commands to Swift
  H264Decoder.swift        Annex-B parser → AVCC CMSampleBuffer builder
  StreamRenderer.swift     AVSampleBufferDisplayLayer SwiftUI wrapper
  NalRingBuffer.swift      Ring buffer for NAL assembly
WebTransport.xcodeproj/    Xcode project (PBXFileSystemSynchronizedRootGroup)
```

### Configuration — `Configuration.swift`

The only file you need to edit before building:

```swift
enum Configuration {
    static let relayURL = "https://your-relay-host:4433/watch"
}
```

That's the only value to change. With a CA-signed cert on the relay, standard TLS
validation applies — no fingerprint, no cert pinning, no app rebuild on cert renewal.

### Build & run

1. Open `WebTransport.xcodeproj` in Xcode.
2. Select your iPhone/iPad as the run destination (not a Simulator).
3. Set your Development Team in **Signing & Capabilities**.
4. Edit `Configuration.swift` with your relay URL.
5. Press **Run** (⌘R).

### How it works

```
WKWebView (1×1 px, invisible)
  │  JS opens WebTransport to relay /watch
  │  Accepts relay's server-initiated bidi stream (incomingBidirectionalStreams)
  │    └─ writable → send commands [4B len][JSON]
  │    └─ readable → receive responses [4B len][JSON] → commandResponse handler
  │  Accepts relay's server-initiated uni stream (incomingUnidirectionalStreams)
  │    └─ parses [4B length][1B flags][Annex-B NALs] frames → frame handler
  ▼
WebTransportBridge  (WKScriptMessageHandler, @MainActor)
  │  "frame" message → base64-decode → H264Decoder.decode(payload:)
  │  "commandResponse" message → onCommandResponse callback → UI toast
  │  sendCommand(_:) → evaluateJavaScript → window.sendCommand(json)
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

---

## Browser Viewer (`viewer.html`)

A self-contained HTML page that mirrors the iOS app for use from any desktop browser.
No install required — open the file directly.

### Requirements

| Browser | Minimum version |
|---------|----------------|
| Chrome / Chromium | 94+ (WebTransport + WebCodecs) |
| Edge | 94+ |
| Firefox | Not supported (WebTransport is behind a flag; WebCodecs partial) |
| Safari | Not supported |

### Usage

Open `viewer.html` directly in Chrome:

```
File → Open File → viewer.html
```

Or serve it over HTTPS (required if you change the relay URL to an HTTP origin):

```bash
# Python quick server (HTTP is fine for localhost)
python3 -m http.server 8080
# → open http://localhost:8080/viewer.html
```

### What it does

- Connects to the relay's `/watch` endpoint over WebTransport (no cert pinning —
  Let's Encrypt CA cert is trusted by the browser natively).
- Accepts the relay's server-initiated bidirectional stream for commands/responses
  (same `incomingBidirectionalStreams` pattern as the iOS app).
- Accepts the relay's unidirectional video stream; parses `[4B len][1B flags][Annex-B NALs]`.
- Decodes H.264 in real time using the **WebCodecs `VideoDecoder` API** with Annex-B
  input; no plugin or WASM required. Codec string is parsed from the SPS NAL on the
  first keyframe.
- Renders decoded frames to a `<canvas>` element; auto-resizes on the first frame.
- Reconnects automatically on disconnect.
- **Controls** — same as the iOS app:
  - Force Keyframe button
  - Bitrate selector: 500 / 1000 / 2000 / 4000 kbps
  - D-pad: click/touch and hold any direction; release to stop
  - Keyboard arrow keys: hold to drive, release to stop
  - Response toast (3-second auto-dismiss)

### Changing the relay URL

Edit the constant at the top of `viewer.html`:

```javascript
const RELAY_URL = 'https://your-relay-host:4433/watch';
```

---

## End-to-End Startup Sequence

```bash
# 1. Start the relay (Riyadh server)
RUST_LOG=info ./relay/target/release/relay

# 2. Start the toy controller (camera machine) — optional, before streamer
python3 ~/toy_controller.py

# 3. Start the streamer (camera machine)
RUST_LOG=info ./streamer/target/release/streamer

# 4. Verify both are connected
curl http://<relay-host>:4434/health
# → {"publisher_connected":true,"status":"ok","subscribers":0}

# 5. Open the iOS app — video appears within 1-2 seconds
#    Tap the slider icon (bottom-right) to open the command panel
#    Hold a D-pad arrow to drive; release to stop
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `publisher rejected: already connected` | Stale streamer process | `pkill -9 -f streamer` |
| `Could not automatically determine CryptoProvider` | Missing rustls init | Already fixed in `main.rs` — rebuild |
| No video on iOS, relay shows subscriber | Old JS still cached in WKWebView | Clean build + reinstall iOS app |
| D-pad does nothing | `toy_controller.py` not running | Start it before the streamer |
| D-pad does nothing, controller is running | Bidi stream not opened | Check relay log for `Subscriber N bidi command stream open` |
| Streamer exits immediately | Token mismatch or relay unreachable | Check `token` in `config.toml` on both sides |
| TLS handshake fails | Relay using self-signed cert, iOS expects CA cert | Copy Let's Encrypt cert to `~/.relay/` and restart relay |
| Low FPS (< 15 fps) | High RTT + QUIC flow control | Lower `bitrate_kbps`; reduce resolution |
| `Capture buffer full` warnings | Encoder faster than network | Normal under congestion; frames are dropped gracefully |
| Pi 3: encoder can't keep up | x264 too slow at current resolution | Reduce to 640×480 / 15fps; use `pixel_format = "MJPEG"` |
| Pi camera not detected | Legacy Camera not enabled (Bullseye) or wrong loopback (Bookworm) | Run `raspi-config` or set up `v4l2loopback` — see Raspberry Pi section |
| `cross build` fails | Vendored crates + ring conflict with cross's Docker image | Build directly on the Pi (Option A) |
| `zig cc`: `unable to parse target query 'aarch64-unknown-linux-gnu'` | Cargo passes Rust triple to zig which only understands its own format | Use the updated wrapper script that filters `--target=*` before passing args to zig |
| `zig cc`: `'x264.h' file not found` | `x264` is a system C library — not bundled in the Rust vendor tree; must be installed or cross-compiled | Use Option B instead: `Cross.toml` installs `libx264-dev` into the Docker container automatically |
| `zig cc`: `inttypes.h` not found (`x264-sys`) | zig 0.14+ no longer bundles Linux headers; Xcode's libclang also has a `#include_next` issue when targeting Linux | Install `musl-cross` and set `LIBCLANG_PATH` + `BINDGEN_EXTRA_CLANG_ARGS` per step 4 |
| `zig cc`: `linux/videodev2.h` not found (`v4l2-sys-mit`) | Linux kernel UAPI headers absent on macOS (zig 0.14+ removed bundled headers) | Same — `musl-cross` ships these headers at `$(brew --prefix musl-cross)/libexec/aarch64-linux-musl/include/linux/` |
| `musl-cross` install fails / no `--with-aarch64` | Tap or formula changed | Try `brew install musl-cross` without options; if sysroot is at a different path, run `find $(brew --prefix musl-cross) -name videodev2.h` to locate it |
| `viewer.html` blank / no WebTransport | Browser too old or wrong browser | Use Chrome 94+; Firefox and Safari are not supported |
| `viewer.html` decodes but stutters | VideoDecoder backpressure | Normal on slow machines; reduce relay bitrate via bitrate selector |

---

## Architecture Notes

- **Vendored dependencies**: Both crates vendor `wtransport 0.4` (with a patch to
  `driver/utils.rs` for `stream_id` conversion) and `x264 0.3 / x264-sys 0.1`.
  No network access required to build.
- **Single persistent stream**: Each publisher→relay and relay→subscriber connection
  uses exactly one long-lived unidirectional QUIC stream. This eliminates per-frame
  stream-setup RTT overhead and achieves near-realtime latency even at 120 ms RTT.
- **Bidirectional command channel**: A second persistent QUIC stream per connection
  carries commands and responses. The relay multiplexes multiple iOS subscribers by
  tagging each message with an 8-byte subscriber ID. Each subscriber only receives
  responses addressed to its own ID.
- **Toy control IPC**: The streamer and Python toy controller communicate via a Unix
  domain socket (`SOCK_DGRAM`, `/tmp/toy.sock`). The streamer is the sender; the
  controller binds and receives. Errors are silently dropped so a missing controller
  never disrupts video streaming.
- **Backpressure handling**: The streamer uses non-blocking `try_send` into the NAL
  channel. Frames are silently dropped on a full channel rather than blocking the
  encoder, preserving real-time behaviour under congestion.
- **Keyframe forcing**: IDR frames are forced via `x264_encoder_encode` with
  `X264_TYPE_IDR` every `keyframe_interval` frames. `keyint_max` alone is unreliable
  with the zerolatency tune.
