#!/usr/bin/env bash
# deploy.sh — install, build, and deploy the WebTransport relay or streamer
#
# Usage:
#   ./deploy.sh                                    interactive menu
#   ./deploy.sh relay                              deploy relay (default host: Riyadh_laptop)
#   ./deploy.sh streamer                           deploy streamer (default host: lviv_laptop)
#   ./deploy.sh relay    --host b@ruh.sunbour.com
#   ./deploy.sh streamer --host pi@192.168.1.42
#   ./deploy.sh both                               deploy relay then streamer (separate default hosts)
#
# Options (applicable to relay / streamer):
#   --host HOST          SSH destination (user@host or SSH config alias)
#   --dir  DIR           Remote working directory  (default: ~/relay or ~/streamer)
#   --force-config       Overwrite existing config.toml on the remote
#   --no-service         Skip systemd service setup
#   -h, --help           Show this help

set -euo pipefail
IFS=$'\n\t'

# ── Colours ───────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  RED='\033[0;31m'; YEL='\033[1;33m'; GRN='\033[0;32m'
  CYN='\033[0;36m'; BLD='\033[1m';    RST='\033[0m'
else
  RED=''; YEL=''; GRN=''; CYN=''; BLD=''; RST=''
fi

info()   { echo -e "${CYN}▶${RST} $*"; }
ok()     { echo -e "${GRN}✓${RST} $*"; }
warn()   { echo -e "${YEL}⚠${RST}  $*"; }
die()    { echo -e "${RED}✗${RST} $*" >&2; exit 1; }
header() { echo -e "\n${BLD}── $* ──${RST}"; }
step()   { echo -e "\n${BLD}[$*]${RST}"; }

# ── Defaults ──────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DEFAULT_RELAY_HOST="Riyadh_laptop"
DEFAULT_RELAY_DIR="~/relay"
DEFAULT_STREAMER_HOST="lviv_laptop"
DEFAULT_STREAMER_DIR="~/streamer"

FORCE_CONFIG=0
NO_SERVICE=0

# ── SSH helpers ───────────────────────────────────────────────────────────────
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)

# Run a command on a remote host (no TTY — safe for output capture + rsync)
remote() {
  local host="$1"; shift
  ssh "${SSH_OPTS[@]}" "$host" "$@"
}

# Run a command that requires sudo (allocates pseudo-TTY so sudo can prompt for password)
remote_s() {
  local host="$1"; shift
  ssh -tt "${SSH_OPTS[@]}" "$host" "$@"
}

# Copy a local file/dir to remote using rsync
push() {
  local src="$1" host="$2" dst="$3"
  rsync -az --delete --progress -e "ssh ${SSH_OPTS[*]}" "$src" "${host}:${dst}"
}

# Write a string as a file on the remote host (safe for arbitrary content)
write_remote_file() {
  local host="$1" path="$2" content="$3"
  printf '%s' "$content" | remote "$host" "cat > $path"
}

write_remote_file_sudo() {
  local host="$1" path="$2" content="$3"
  # Write to a temp file without sudo (stdin-safe), then sudo-move into place.
  # Can't pipe directly into "sudo tee" when using -tt because stdin is the TTY.
  local tmp="/tmp/_deploy_$$"
  printf '%s' "$content" | remote "$host" "cat > '$tmp'"
  remote_s "$host" "sudo mv '$tmp' '$path' && sudo chmod 644 '$path'"
}

check_conn() {
  local host="$1"
  info "Connecting to $host …"
  remote "$host" true 2>/dev/null || die "Cannot reach '$host'. Check SSH config / key / hostname."
  ok "Connected to $host"
}

# Fetch the remote user's home directory
# cd ~ && pwd is more reliable than $HOME — works even when $HOME is unset or wrong
remote_home() {
  local host="$1"
  remote "$host" 'cd ~ && pwd'
}

# Expand a path that may start with ~ using the remote home
expand_remote_path() {
  local home="$1" path="$2"
  echo "${path/#\~/$home}"
}

# ── Remote: Rust ──────────────────────────────────────────────────────────────
ensure_rust() {
  local host="$1"
  step "Rust"
  if remote "$host" 'test -f ~/.cargo/bin/cargo'; then
    local ver
    ver=$(remote "$host" '~/.cargo/bin/cargo --version 2>/dev/null')
    ok "Rust already installed: $ver"
  else
    info "Installing Rust via rustup …"
    remote "$host" \
      'curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs \
       | sh -s -- -y --no-modify-path --quiet'
    ok "Rust installed"
  fi
}

# ── Remote: system packages ───────────────────────────────────────────────────
# Package names differ across distros — map them here.
ensure_deps() {
  local host="$1" component="$2"   # component: relay | streamer
  step "System packages"

  if remote "$host" 'command -v apt-get > /dev/null 2>&1'; then
    # Debian / Ubuntu / Raspberry Pi OS
    local pkgs="build-essential clang libclang-dev cmake make git"
    [[ "$component" == "streamer" ]] && pkgs+=" v4l-utils python3"
    info "apt-get install: $pkgs"
    remote_s "$host" "export DEBIAN_FRONTEND=noninteractive
      sudo apt-get update -qq
      sudo apt-get install -y -qq $pkgs"

  elif remote "$host" 'command -v dnf > /dev/null 2>&1'; then
    # Amazon Linux 2023 / Fedora / RHEL / CentOS Stream
    local pkgs="gcc gcc-c++ clang clang-devel cmake make git"
    [[ "$component" == "streamer" ]] && pkgs+=" v4l-utils python3"
    info "dnf install: $pkgs"
    remote_s "$host" "sudo dnf install -y -q $pkgs"

  elif remote "$host" 'command -v yum > /dev/null 2>&1'; then
    # Amazon Linux 2 / older RHEL
    local pkgs="gcc gcc-c++ clang clang-devel cmake make git"
    [[ "$component" == "streamer" ]] && pkgs+=" v4l-utils python3"
    info "yum install: $pkgs"
    remote_s "$host" "sudo yum install -y -q $pkgs"

  elif remote "$host" 'command -v pacman > /dev/null 2>&1'; then
    # Arch Linux
    local pkgs="base-devel clang cmake git"
    [[ "$component" == "streamer" ]] && pkgs+=" v4l-utils python"
    info "pacman install: $pkgs"
    remote_s "$host" "sudo pacman -Sy --noconfirm --quiet $pkgs"

  else
    warn "Unknown package manager — install manually: clang clang-devel/libclang-dev cmake make git"
    return
  fi
  ok "Packages ready"
}

# ── Remote: native build ──────────────────────────────────────────────────────
build_remote() {
  local host="$1" dir="$2"
  step "Build"
  info "Running 'CC=clang cargo build --release' on $host …"
  info "(Pi 3/arm32 can take 30-40 min; x86_64 ~3-5 min)"
  remote "$host" "source ~/.cargo/env 2>/dev/null || true
    cd $dir
    CC=clang cargo build --release 2>&1"
  ok "Build complete"
}

# ── Local: cross-compile for aarch64 (Pi 4/5 64-bit) ─────────────────────────
build_cross_aarch64() {
  local src_dir="$1"
  step "Cross-compile  (local macOS → aarch64-linux)"
  if ! command -v cross &>/dev/null; then
    die "'cross' not found on this machine.
  Install: cargo install cross --git https://github.com/cross-rs/cross"
  fi
  if ! docker info &>/dev/null 2>&1; then
    die "Docker is not running. Start Docker Desktop, then retry."
  fi
  info "DOCKER_DEFAULT_PLATFORM=linux/amd64 cross build --release --target aarch64-unknown-linux-gnu"
  info "(First run: ~5 min — pulls Docker image + compiles deps; subsequent runs: ~1-2 min)"
  ( cd "$src_dir" && DOCKER_DEFAULT_PLATFORM=linux/amd64 \
      cross build --release --target aarch64-unknown-linux-gnu )
  ok "Cross-compile complete"
}

# ── Remote: systemd service ───────────────────────────────────────────────────
install_service() {
  local host="$1" name="$2" user="$3" abs_dir="$4" rust_log="${5:-info}" extra_env="${6:-}"

  local binary="$abs_dir/target/release/$name"
  local config="$abs_dir/config.toml"

  local env_line=""
  [[ -n "$extra_env" ]] && env_line="Environment=$extra_env"

  # ${name^} is bash 4+ only; macOS ships bash 3.2 — use tr instead
  local name_cap
  name_cap="$(printf '%s' "${name:0:1}" | tr '[:lower:]' '[:upper:]')${name:1}"

  local svc
  svc="[Unit]
Description=WebTransport ${name_cap}
After=network-online.target
Wants=network-online.target

[Service]
User=$user
WorkingDirectory=$abs_dir
ExecStart=$binary --config $config
Restart=always
RestartSec=5
Environment=RUST_LOG=${rust_log}
$env_line

[Install]
WantedBy=multi-user.target"

  write_remote_file_sudo "$host" "/etc/systemd/system/${name}.service" "$svc"
  remote_s "$host" "sudo systemctl daemon-reload && sudo systemctl enable $name"
  ok "Service /etc/systemd/system/${name}.service installed and enabled"
}

# Interactive systemd setup — prompts the user; skipped if --no-service or no systemd.
maybe_install_service() {
  local host="$1" name="$2" user="$3" abs_dir="$4"
  local manual_cmd="RUST_LOG=info $abs_dir/target/release/$name --config $abs_dir/config.toml"

  if [[ $NO_SERVICE -eq 1 ]]; then
    warn "Skipping systemd (--no-service)"
    echo -e "  Start manually: ${CYN}ssh $host '$manual_cmd &'${RST}"
    return
  fi

  if ! has_systemd "$host" 2>/dev/null; then
    warn "systemd not available on $host"
    echo -e "  Start manually: ${CYN}ssh $host 'source ~/.cargo/env; $manual_cmd &'${RST}"
    return
  fi

  step "Systemd service"
  local choice
  read -rp "$(printf '%b' "${CYN}?${RST} Configure systemd service for ${BLD}${name}${RST}? [${BLD}Y${RST}/n]: ")" choice
  choice="${choice:-Y}"

  if [[ ! "$choice" =~ ^[Yy] ]]; then
    warn "Skipping systemd — start manually:"
    echo -e "  ${CYN}ssh $host 'source ~/.cargo/env; $manual_cmd &'${RST}"
    return
  fi

  local rust_log
  ask "RUST_LOG level (error/warn/info/debug)" "info" rust_log

  install_service "$host" "$name" "$user" "$abs_dir" "$rust_log"
  restart_service "$host" "$name"
}

restart_service() {
  local host="$1" name="$2"
  info "Restarting $name …"
  remote_s "$host" "sudo systemctl restart $name"
  sleep 2
  local status
  status=$(remote "$host" "systemctl is-active $name" || true)
  if [[ "$status" == "active" ]]; then
    ok "$name is running"
  else
    warn "$name status: '$status'"
    warn "Check logs: ssh $host 'journalctl -u $name -n 50 --no-pager'"
  fi
}

has_systemd() {
  # Just check the binary exists — is-system-running exits non-zero on AWS
  # even when systemd is fully operational (status "degraded" is common).
  local host="$1"
  remote "$host" 'command -v systemctl > /dev/null 2>&1'
}

# ── Interactive prompts ───────────────────────────────────────────────────────
ask() {
  # ask "Question text" "default" varname
  local q="$1" def="$2" var="$3"
  local input
  read -rp "$(printf '%b' "${CYN}?${RST} $q [${BLD}$def${RST}]: ")" input
  printf -v "$var" '%s' "${input:-$def}"
}

ask_secret() {
  local q="$1" var="$2"
  local input
  read -rsp "$(printf '%b' "${CYN}?${RST} $q: ")" input
  echo
  printf -v "$var" '%s' "$input"
}

# ── TLS (relay only) ──────────────────────────────────────────────────────────

install_certbot() {
  local host="$1"
  if remote "$host" 'command -v certbot > /dev/null 2>&1'; then
    ok "certbot already installed"
    return
  fi
  info "Installing certbot …"
  if remote "$host" 'command -v apt-get > /dev/null 2>&1'; then
    remote_s "$host" "sudo apt-get install -y -qq certbot"
  elif remote "$host" 'command -v dnf > /dev/null 2>&1'; then
    # Amazon Linux 2023 / Fedora — certbot may be in the repo or via pip
    remote_s "$host" "sudo dnf install -y -q certbot 2>/dev/null || sudo pip3 install certbot"
  elif remote "$host" 'command -v yum > /dev/null 2>&1'; then
    # Amazon Linux 2 — needs EPEL first
    remote_s "$host" "sudo amazon-linux-extras install -y epel 2>/dev/null || true
      sudo yum install -y -q certbot 2>/dev/null || sudo pip3 install certbot"
  else
    # Universal fallback
    remote_s "$host" "sudo pip3 install certbot"
  fi
  ok "certbot installed"
}

copy_le_cert() {
  # Copy an existing Let's Encrypt cert into ~/.relay/ and install the renewal hook
  local host="$1" domain="$2"
  remote "$host" "mkdir -p ~/.relay"
  remote_s "$host" "
    sudo cp /etc/letsencrypt/live/${domain}/fullchain.pem ~/.relay/cert.pem
    sudo cp /etc/letsencrypt/live/${domain}/privkey.pem   ~/.relay/key.pem
    sudo chown \"\$(whoami):\$(whoami)\" ~/.relay/cert.pem ~/.relay/key.pem
    chmod 600 ~/.relay/key.pem
  "
  local hook
  hook='#!/bin/bash
DOMAIN=$(ls /etc/letsencrypt/live/ | grep -v README | head -1)
RUSER=$(stat -c "%U" /home/$(ls /home | head -1) 2>/dev/null || echo b)
RHOME=$(eval echo "~${RUSER}")
cp /etc/letsencrypt/live/${DOMAIN}/fullchain.pem ${RHOME}/.relay/cert.pem
cp /etc/letsencrypt/live/${DOMAIN}/privkey.pem   ${RHOME}/.relay/key.pem
chown ${RUSER}:${RUSER} ${RHOME}/.relay/cert.pem ${RHOME}/.relay/key.pem
chmod 600 ${RHOME}/.relay/key.pem
pkill -HUP relay 2>/dev/null || true'
  write_remote_file_sudo "$host" "/etc/letsencrypt/renewal-hooks/deploy/relay.sh" "$hook"
  remote_s "$host" "sudo chmod +x /etc/letsencrypt/renewal-hooks/deploy/relay.sh"
}

setup_tls() {
  local host="$1"
  step "TLS certificate"

  # Check for an existing Let's Encrypt cert
  # Run the sudo command non-capturing (output goes to a temp file on the remote).
  # We cannot capture output from remote_s because ssh -tt routes the sudo password
  # prompt through the PTY to stdout, contaminating the $() result.
  local domain
  remote_s "$host" "sudo ls /etc/letsencrypt/live/ 2>/dev/null | grep -v README | head -1 > /tmp/_deploy_le || true" 2>/dev/null || true
  domain=$(remote "$host" "cat /tmp/_deploy_le 2>/dev/null; rm -f /tmp/_deploy_le" || true)
  domain="${domain//$'\r'/}"

  if [[ -n "$domain" ]]; then
    info "Let's Encrypt cert already present for: $domain"
    copy_le_cert "$host" "$domain"
    ok "Cert copied to ~/.relay/; renewal hook installed"
    return
  fi

  # No cert yet — ask whether to obtain one now
  echo
  warn "No Let's Encrypt cert found on $host"
  echo -e "  ${BLD}Option 1${RST} — Obtain a cert now via certbot (recommended)"
  echo -e "           Requires: domain name pointing to this server + TCP 80 open"
  echo -e "  ${BLD}Option 2${RST} — Skip; relay auto-generates a self-signed cert (14-day expiry)"
  echo
  local choice
  read -rp "$(printf '%b' "${CYN}?${RST} Obtain a Let's Encrypt cert now? [Y/n]: ")" choice
  choice="${choice:-Y}"

  if [[ ! "$choice" =~ ^[Yy] ]]; then
    warn "Skipping TLS — relay will use a self-signed cert (only suitable for testing)"
    remote "$host" "mkdir -p ~/.relay"
    return
  fi

  # Prompt for domain and email
  local le_domain le_email
  ask "Domain name pointing to this server (e.g. relay.example.com)" "" le_domain
  [[ -z "$le_domain" ]] && die "A domain name is required for Let's Encrypt"
  ask "Email address (certbot expiry notifications)" "" le_email
  [[ -z "$le_email" ]] && die "An email address is required for Let's Encrypt"

  echo
  warn "Make sure before continuing:"
  echo -e "  • DNS: ${BLD}${le_domain}${RST} → this server's public IP"
  echo -e "  • Firewall: ${BLD}TCP 80${RST} inbound open (HTTP-01 challenge)"
  read -rp $'\nReady? Press Enter to continue, Ctrl-C to abort … '

  install_certbot "$host"

  info "Running certbot --standalone for $le_domain …"
  remote_s "$host" "sudo certbot certonly --standalone --non-interactive \
    --agree-tos --email '${le_email}' -d '${le_domain}'"

  copy_le_cert "$host" "$le_domain"
  ok "Let's Encrypt cert obtained and installed for $le_domain"
  ok "Auto-renewal configured — cert will renew automatically every 60 days"
}

# ── Relay config ──────────────────────────────────────────────────────────────
gen_relay_config() {
  local home="$1" token="$2" max_sub="$3"
  cat <<EOF
[server]
bind            = "0.0.0.0:4433"
publish_path    = "/publish"
subscribe_path  = "/watch"
publish_token   = "${token}"
max_subscribers = ${max_sub}

[tls]
cert_path          = "${home}/.relay/cert.pem"
key_path           = "${home}/.relay/key.pem"
cert_validity_days = 14
EOF
}

# ── Streamer config ───────────────────────────────────────────────────────────
gen_streamer_config() {
  local relay_url="$1" token="$2" device="$3" \
        width="$4" height="$5" fps="$6" fmt="$7" bitrate="$8"
  cat <<EOF
[camera]
device        = "${device}"
width         = ${width}
height        = ${height}
fps           = ${fps}
pixel_format  = "${fmt}"

[encoder]
profile           = "baseline"
tune              = "zerolatency"
bitrate_kbps      = ${bitrate}
keyframe_interval = ${fps}

[relay]
url   = "${relay_url}"
token = "${token}"
EOF
}

# ── Detect Raspberry Pi model ─────────────────────────────────────────────────
detect_pi() {
  local host="$1"
  remote "$host" '
    if [ -f /sys/firmware/devicetree/base/model ]; then
      cat /sys/firmware/devicetree/base/model | tr -d "\0"
    elif grep -qi "raspberry" /proc/cpuinfo 2>/dev/null; then
      grep "Model" /proc/cpuinfo | head -1 | cut -d: -f2 | xargs
    else
      echo ""
    fi
  ' 2>/dev/null || true
}

# ── Deploy relay ──────────────────────────────────────────────────────────────
deploy_relay() {
  local host="$1" remote_dir="$2"

  header "Deploy Relay → $host"
  check_conn "$host"

  local ruser rhome
  ruser=$(remote "$host" 'whoami')
  rhome=$(remote_home "$host")
  [[ -z "$rhome" ]] && die "Could not determine home directory on $host"
  info "Remote: user=${BLD}${ruser}${RST}, home=${BLD}${rhome}${RST}"
  local abs_dir
  abs_dir=$(expand_remote_path "$rhome" "$remote_dir")

  # ── Prompts ────────────────────────────────────────────────────────────────
  header "Configuration"
  local token max_sub
  ask  "Publish token (shared secret with streamer)" "secret-publish-token" token
  ask  "Max subscribers" "50" max_sub

  # ── Deps ───────────────────────────────────────────────────────────────────
  ensure_deps "$host" relay
  ensure_rust "$host"

  # ── Source ─────────────────────────────────────────────────────────────────
  step "Sync source"
  remote "$host" "mkdir -p $abs_dir"
  push "$SCRIPT_DIR/relay/" "$host" "$abs_dir/"
  ok "Source synced to $host:$abs_dir"

  # ── Config ─────────────────────────────────────────────────────────────────
  step "Config"
  if [[ $FORCE_CONFIG -eq 1 ]] || ! remote "$host" "test -f $abs_dir/config.toml" 2>/dev/null; then
    local cfg
    cfg=$(gen_relay_config "$rhome" "$token" "$max_sub")
    write_remote_file "$host" "$abs_dir/config.toml" "$cfg"
    ok "config.toml written"
  else
    ok "config.toml already exists — skipping (use --force-config to overwrite)"
  fi

  # ── TLS ────────────────────────────────────────────────────────────────────
  setup_tls "$host" "$abs_dir"

  # ── Build ──────────────────────────────────────────────────────────────────
  build_remote "$host" "$abs_dir"

  # ── Service ────────────────────────────────────────────────────────────────
  maybe_install_service "$host" "relay" "$ruser" "$abs_dir"

  header "Relay deployment done"
  ok "Relay endpoint: https://<host>:4433"
  echo -e "  Publish URL : ${CYN}https://$(remote "$host" 'hostname -f 2>/dev/null || hostname'):4433/publish${RST}"
  echo -e "  Watch URL   : ${CYN}https://$(remote "$host" 'hostname -f 2>/dev/null || hostname'):4433/watch${RST}"
  echo -e "  Health      : ${CYN}ssh $host 'curl -s http://localhost:4434/health'${RST}"
  echo -e "  Logs        : ${CYN}ssh $host 'journalctl -u relay -f'${RST}"
  echo
  warn "AWS / cloud firewall checklist:"
  echo -e "    ${BLD}UDP 4433${RST} inbound — WebTransport / QUIC (viewers + streamer)"
  echo -e "    ${BLD}TCP 4434${RST} inbound — health check endpoint (optional)"
  echo -e "    ${BLD}TCP 443${RST}  inbound — Let's Encrypt HTTP challenge (if obtaining cert)"
  echo -e "  AWS: EC2 → Security Groups → Inbound Rules → Add Rule"
}

# ── Deploy streamer ───────────────────────────────────────────────────────────
deploy_streamer() {
  local host="$1" remote_dir="$2"

  header "Deploy Streamer → $host"
  check_conn "$host"

  local ruser rhome
  ruser=$(remote "$host" 'whoami')
  rhome=$(remote_home "$host")
  [[ -z "$rhome" ]] && die "Could not determine home directory on $host"
  info "Remote: user=${BLD}${ruser}${RST}, home=${BLD}${rhome}${RST}"
  local abs_dir
  abs_dir=$(expand_remote_path "$rhome" "$remote_dir")

  # ── Detect architecture and Pi model ──────────────────────────────────────
  step "Target detection"
  local arch
  arch=$(remote "$host" 'uname -m')
  info "Architecture: $arch"

  # aarch64 (Pi 4/5 64-bit): cross-compile locally and upload binary.
  # arm32 / x86_64: build natively on the remote host.
  local cross_compile=0
  [[ "$arch" == "aarch64" ]] && cross_compile=1

  local default_w=1280 default_h=720 default_fps=30
  local default_fmt=MJPEG default_bitrate=2000

  local pi_model=""
  if [[ "$arch" == "aarch64" || "$arch" == "armv7l" || "$arch" == "armv6l" ]]; then
    pi_model=$(detect_pi "$host")
    if [[ -n "$pi_model" ]]; then
      info "Detected: $pi_model"
      if echo "$pi_model" | grep -qiE "Pi (Zero|Zero 2|2|3)"; then
        default_w=640; default_h=480; default_fps=15; default_bitrate=800
        warn "Pi 3 / 2 / Zero detected — defaulting to 640×480 / 15fps for CPU headroom"
      else
        info "Pi 4 / 5 (aarch64) — will cross-compile locally, then upload binary"
      fi
    fi
  fi

  # ── Prompts ────────────────────────────────────────────────────────────────
  header "Configuration"
  local relay_url token device width height fps fmt bitrate
  ask "Relay publish URL"         "https://ruh.sunbour.com:4433/publish" relay_url
  ask "Publish token"             "secret-publish-token"                 token
  ask "Camera device"             "/dev/video0"                          device
  ask "Capture width"             "$default_w"                           width
  ask "Capture height"            "$default_h"                           height
  ask "Capture fps"               "$default_fps"                         fps
  ask "Pixel format (MJPEG/YUYV)" "$default_fmt"                        fmt
  ask "Encoder bitrate kbps"      "$default_bitrate"                     bitrate

  # ── Deps ───────────────────────────────────────────────────────────────────
  if [[ $cross_compile -eq 1 ]]; then
    # Pre-built binary: no Rust or build tools needed on the Pi.
    # Install only runtime utilities (v4l-utils for camera diagnostics,
    # python3 for toy_controller.py).
    step "System packages"
    if remote "$host" 'command -v apt-get > /dev/null 2>&1'; then
      info "apt-get install: v4l-utils python3"
      remote_s "$host" "export DEBIAN_FRONTEND=noninteractive
        sudo apt-get update -qq
        sudo apt-get install -y -qq v4l-utils python3"
    else
      warn "Unknown package manager — install v4l-utils and python3 manually if needed"
    fi
    ok "Packages ready"
  else
    ensure_deps "$host" streamer
    ensure_rust "$host"
  fi

  # ── Source ─────────────────────────────────────────────────────────────────
  step "Sync source"
  if [[ $cross_compile -eq 1 ]]; then
    # Pi only needs target/release/ dir (for the uploaded binary) and the root dir.
    remote "$host" "mkdir -p $abs_dir/target/release"
  else
    remote "$host" "mkdir -p $abs_dir"
    push "$SCRIPT_DIR/streamer/" "$host" "$abs_dir/"
  fi
  rsync -az -e "ssh ${SSH_OPTS[*]}" "$SCRIPT_DIR/toy_controller.py" "${host}:${rhome}/toy_controller.py"
  ok "toy_controller.py synced to $host"

  # ── Config ─────────────────────────────────────────────────────────────────
  step "Config"
  if [[ $FORCE_CONFIG -eq 1 ]] || ! remote "$host" "test -f $abs_dir/config.toml" 2>/dev/null; then
    local cfg
    cfg=$(gen_streamer_config "$relay_url" "$token" "$device" \
          "$width" "$height" "$fps" "$fmt" "$bitrate")
    write_remote_file "$host" "$abs_dir/config.toml" "$cfg"
    ok "config.toml written"
  else
    ok "config.toml already exists — skipping (use --force-config to overwrite)"
  fi

  # ── Build / Upload ─────────────────────────────────────────────────────────
  if [[ $cross_compile -eq 1 ]]; then
    build_cross_aarch64 "$SCRIPT_DIR/streamer"
    step "Upload binary"
    local bin_src="$SCRIPT_DIR/streamer/target/aarch64-unknown-linux-gnu/release/streamer"
    [[ -f "$bin_src" ]] || die "Cross-compiled binary not found: $bin_src"
    rsync -az --progress -e "ssh ${SSH_OPTS[*]}" \
      "$bin_src" "${host}:${abs_dir}/target/release/streamer"
    ok "Binary uploaded to $host:$abs_dir/target/release/streamer"
  else
    build_remote "$host" "$abs_dir"
  fi

  # ── Service ────────────────────────────────────────────────────────────────
  maybe_install_service "$host" "streamer" "$ruser" "$abs_dir"

  header "Streamer deployment done"
  ok "Streamer binary at $host:$abs_dir/target/release/streamer"
  echo -e "  Logs    : ${CYN}ssh $host 'journalctl -u streamer -f'${RST}"
  echo -e "  Toy ctrl: ${CYN}ssh $host 'python3 ~/toy_controller.py'${RST}"

  if [[ -n "$pi_model" ]]; then
    echo -e "\n  ${YEL}Pi tip${RST}: camera not appearing?"
    echo -e "    Bullseye: ${CYN}sudo raspi-config${RST} → Interface Options → Legacy Camera"
    echo -e "    Bookworm: ${CYN}sudo apt install v4l2loopback-dkms${RST} + libcamera-vid pipe (see README)"
    echo -e "    Check devices: ${CYN}ssh $host 'v4l2-ctl --list-devices'${RST}"
  fi
}

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") <command> [options]

Commands:
  relay             Deploy the relay server
  streamer          Deploy the streamer (Linux x86_64 or Raspberry Pi)
  both              Deploy relay then streamer (uses separate default hosts)

Options:
  --host HOST       SSH destination: user@host or SSH config alias
                    Default for relay:    $DEFAULT_RELAY_HOST
                    Default for streamer: $DEFAULT_STREAMER_HOST
  --dir DIR         Remote working directory
                    Default for relay:    $DEFAULT_RELAY_DIR
                    Default for streamer: $DEFAULT_STREAMER_DIR
  --force-config    Overwrite existing config.toml on the remote
  --no-service      Skip systemd service installation
  -h, --help        Show this help

Examples:
  $(basename "$0") relay
  $(basename "$0") relay    --host b@ruh.sunbour.com
  $(basename "$0") relay    --host ubuntu@54.123.45.67        # AWS Ubuntu AMI
  $(basename "$0") relay    --host ec2-user@54.123.45.67      # AWS Amazon Linux AMI
  $(basename "$0") relay    --host aws_server                 # SSH config alias
  $(basename "$0") streamer
  $(basename "$0") streamer --host pi@192.168.1.42
  $(basename "$0") streamer --host pi@192.168.1.42 --force-config
  $(basename "$0") both
EOF
}

# ── Interactive menu ──────────────────────────────────────────────────────────
interactive() {
  echo -e "\n${BLD}WebTransport Deploy${RST}"
  echo "  1) Deploy relay    (default: $DEFAULT_RELAY_HOST)"
  echo "  2) Deploy streamer (default: $DEFAULT_STREAMER_HOST)"
  echo "  3) Deploy both"
  echo "  q) Quit"
  local choice
  read -rp $'\nChoice: ' choice
  case "$choice" in
    1) deploy_relay    "$DEFAULT_RELAY_HOST"    "$DEFAULT_RELAY_DIR" ;;
    2) deploy_streamer "$DEFAULT_STREAMER_HOST" "$DEFAULT_STREAMER_DIR" ;;
    3) deploy_relay    "$DEFAULT_RELAY_HOST"    "$DEFAULT_RELAY_DIR"
       deploy_streamer "$DEFAULT_STREAMER_HOST" "$DEFAULT_STREAMER_DIR" ;;
    q|Q) exit 0 ;;
    *) die "Unknown choice: $choice" ;;
  esac
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  [[ $# -eq 0 ]] && { interactive; return; }

  local cmd="$1"; shift
  local host="" dir=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --host)         host="$2";    shift 2 ;;
      --dir)          dir="$2";     shift 2 ;;
      --force-config) FORCE_CONFIG=1; shift ;;
      --no-service)   NO_SERVICE=1;   shift ;;
      -h|--help)      usage; exit 0 ;;
      *) die "Unknown option: $1" ;;
    esac
  done

  case "$cmd" in
    relay)
      deploy_relay \
        "${host:-$DEFAULT_RELAY_HOST}" \
        "${dir:-$DEFAULT_RELAY_DIR}"
      ;;
    streamer)
      deploy_streamer \
        "${host:-$DEFAULT_STREAMER_HOST}" \
        "${dir:-$DEFAULT_STREAMER_DIR}"
      ;;
    both)
      deploy_relay    "${DEFAULT_RELAY_HOST}"    "${DEFAULT_RELAY_DIR}"
      deploy_streamer "${DEFAULT_STREAMER_HOST}" "${DEFAULT_STREAMER_DIR}"
      ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown command: '$cmd'. Run '$(basename "$0") --help' for usage." ;;
  esac
}

main "$@"
