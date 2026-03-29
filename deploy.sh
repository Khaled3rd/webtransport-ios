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
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=15"

# Run a command on a remote host
remote() {
  local host="$1"; shift
  ssh $SSH_OPTS "$host" "$@"
}

# Copy a local file/dir to remote using rsync
push() {
  local src="$1" host="$2" dst="$3"
  rsync -az --delete --info=progress2 -e "ssh $SSH_OPTS" "$src" "${host}:${dst}"
}

# Write a string as a file on the remote host (safe for arbitrary content)
write_remote_file() {
  local host="$1" path="$2" content="$3"
  printf '%s' "$content" | remote "$host" "cat > $path"
}

write_remote_file_sudo() {
  local host="$1" path="$2" content="$3"
  printf '%s' "$content" | remote "$host" "sudo tee $path > /dev/null"
}

check_conn() {
  local host="$1"
  info "Connecting to $host …"
  remote "$host" true 2>/dev/null || die "Cannot reach '$host'. Check SSH config / key / hostname."
  ok "Connected to $host"
}

# Fetch the remote user's home directory (resolves ~)
remote_home() {
  local host="$1"
  remote "$host" 'echo $HOME'
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
    remote "$host" "export DEBIAN_FRONTEND=noninteractive
      sudo apt-get update -qq
      sudo apt-get install -y -qq $pkgs"

  elif remote "$host" 'command -v dnf > /dev/null 2>&1'; then
    # Amazon Linux 2023 / Fedora / RHEL / CentOS Stream
    local pkgs="gcc gcc-c++ clang clang-devel cmake make git"
    [[ "$component" == "streamer" ]] && pkgs+=" v4l-utils python3"
    info "dnf install: $pkgs"
    remote "$host" "sudo dnf install -y -q $pkgs"

  elif remote "$host" 'command -v yum > /dev/null 2>&1'; then
    # Amazon Linux 2 / older RHEL
    local pkgs="gcc gcc-c++ clang clang-devel cmake make git"
    [[ "$component" == "streamer" ]] && pkgs+=" v4l-utils python3"
    info "yum install: $pkgs"
    remote "$host" "sudo yum install -y -q $pkgs"

  elif remote "$host" 'command -v pacman > /dev/null 2>&1'; then
    # Arch Linux
    local pkgs="base-devel clang cmake git"
    [[ "$component" == "streamer" ]] && pkgs+=" v4l-utils python"
    info "pacman install: $pkgs"
    remote "$host" "sudo pacman -Sy --noconfirm --quiet $pkgs"

  else
    warn "Unknown package manager — install manually: clang clang-devel/libclang-dev cmake make git"
    return
  fi
  ok "Packages ready"
}

# ── Remote: build ─────────────────────────────────────────────────────────────
build_remote() {
  local host="$1" dir="$2"
  step "Build"
  info "Running 'CC=clang cargo build --release' on $host …"
  info "(Pi 3 can take 30-40 min; Pi 4 ~10 min; x86_64 ~3-5 min)"
  remote "$host" "source ~/.cargo/env 2>/dev/null || true
    cd $dir
    CC=clang cargo build --release 2>&1"
  ok "Build complete"
}

# ── Remote: systemd service ───────────────────────────────────────────────────
install_service() {
  local host="$1" name="$2" user="$3" abs_dir="$4" extra_env="${5:-}"

  local binary="$abs_dir/target/release/$name"
  local config="$abs_dir/config.toml"

  local env_line=""
  [[ -n "$extra_env" ]] && env_line="Environment=$extra_env"

  local svc
  svc="[Unit]
Description=WebTransport ${name^}
After=network-online.target
Wants=network-online.target

[Service]
User=$user
WorkingDirectory=$abs_dir
ExecStart=$binary --config $config
Restart=always
RestartSec=5
Environment=RUST_LOG=info
$env_line

[Install]
WantedBy=multi-user.target"

  write_remote_file_sudo "$host" "/etc/systemd/system/${name}.service" "$svc"
  remote "$host" "sudo systemctl daemon-reload && sudo systemctl enable $name"
  ok "Service /etc/systemd/system/${name}.service installed and enabled"
}

restart_service() {
  local host="$1" name="$2"
  info "Restarting $name …"
  remote "$host" "sudo systemctl restart $name"
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
setup_tls() {
  local host="$1" relay_dir="$2"
  step "TLS certificate"

  # Look for a Let's Encrypt cert
  local domain
  domain=$(remote "$host" 'sudo ls /etc/letsencrypt/live/ 2>/dev/null | grep -v README | head -1' || true)

  if [[ -n "$domain" ]]; then
    info "Let's Encrypt cert found for: $domain"
    remote "$host" "
      mkdir -p ~/.relay
      sudo cp /etc/letsencrypt/live/${domain}/fullchain.pem ~/.relay/cert.pem
      sudo cp /etc/letsencrypt/live/${domain}/privkey.pem   ~/.relay/key.pem
      sudo chown \"\$(whoami):\$(whoami)\" ~/.relay/cert.pem ~/.relay/key.pem
      chmod 600 ~/.relay/key.pem
    "
    # Renewal hook
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
    remote "$host" "sudo chmod +x /etc/letsencrypt/renewal-hooks/deploy/relay.sh"
    ok "TLS cert copied; auto-renewal hook installed"
  else
    warn "No Let's Encrypt cert found on $host"
    warn "The relay will auto-generate a self-signed cert (valid 14 days)"
    warn "For production: install certbot, obtain a cert, then rerun deploy.sh relay"
    remote "$host" "mkdir -p ~/.relay"
  fi
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

  local rhome
  rhome=$(remote_home "$host")
  local abs_dir
  abs_dir=$(expand_remote_path "$rhome" "$remote_dir")
  local ruser
  ruser=$(remote "$host" 'whoami')

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
  if [[ $NO_SERVICE -eq 0 ]] && has_systemd "$host" 2>/dev/null; then
    step "Systemd service"
    install_service "$host" "relay" "$ruser" "$abs_dir"
    restart_service "$host" "relay"
  else
    [[ $NO_SERVICE -eq 1 ]] && warn "Skipping systemd (--no-service)" || warn "systemd not available"
    echo -e "  Start manually: ${CYN}ssh $host 'RUST_LOG=info $abs_dir/target/release/relay --config $abs_dir/config.toml &'${RST}"
  fi

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

  local rhome
  rhome=$(remote_home "$host")
  local abs_dir
  abs_dir=$(expand_remote_path "$rhome" "$remote_dir")
  local ruser
  ruser=$(remote "$host" 'whoami')

  # ── Detect architecture and Pi model ──────────────────────────────────────
  step "Target detection"
  local arch
  arch=$(remote "$host" 'uname -m')
  info "Architecture: $arch"

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
        info "Pi 4 / 5 detected — defaulting to 1280×720 / 30fps"
      fi
    fi
  fi

  # ── Prompts ────────────────────────────────────────────────────────────────
  header "Configuration"
  local relay_url token device width height fps fmt bitrate
  ask "Relay publish URL"      "https://ruh.sunbour.com:4433/publish" relay_url
  ask "Publish token"          "secret-publish-token"                 token
  ask "Camera device"          "/dev/video0"                          device
  ask "Capture width"          "$default_w"                           width
  ask "Capture height"         "$default_h"                           height
  ask "Capture fps"            "$default_fps"                         fps
  ask "Pixel format (MJPEG/YUYV)" "$default_fmt"                     fmt
  ask "Encoder bitrate kbps"   "$default_bitrate"                     bitrate

  # ── Deps ───────────────────────────────────────────────────────────────────
  ensure_deps "$host" streamer
  ensure_rust "$host"

  # ── Source ─────────────────────────────────────────────────────────────────
  step "Sync source"
  remote "$host" "mkdir -p $abs_dir"
  push "$SCRIPT_DIR/streamer/" "$host" "$abs_dir/"
  # Toy controller alongside the streamer
  rsync -az -e "ssh $SSH_OPTS" "$SCRIPT_DIR/toy_controller.py" "${host}:${rhome}/toy_controller.py"
  ok "Source and toy_controller.py synced to $host"

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

  # ── Build ──────────────────────────────────────────────────────────────────
  build_remote "$host" "$abs_dir"

  # ── Service ────────────────────────────────────────────────────────────────
  if [[ $NO_SERVICE -eq 0 ]] && has_systemd "$host" 2>/dev/null; then
    step "Systemd service"
    install_service "$host" "streamer" "$ruser" "$abs_dir"
    restart_service "$host" "streamer"
  else
    [[ $NO_SERVICE -eq 1 ]] && warn "Skipping systemd (--no-service)" || warn "systemd not available"
    echo -e "  Start manually: ${CYN}ssh $host 'RUST_LOG=info $abs_dir/target/release/streamer --config $abs_dir/config.toml &'${RST}"
  fi

  header "Streamer deployment done"
  ok "Streamer running on $host"
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
