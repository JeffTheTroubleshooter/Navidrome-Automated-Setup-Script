#!/usr/bin/env bash
#
# Navidrome installer / uninstaller (from source)
# Detects distro, ensures Go 1.27+ and Node 24, clones repo,
# runs make setup + make build, installs the binary, and creates a systemd service.
#
# Usage:
#   bash navidrome-install.sh            # install
#   bash navidrome-install.sh uninstall  # remove service, files, and optionally packages
#

set -euo pipefail

START_TIME=$(date +%s)
REPO_URL="https://github.com/navidrome/navidrome.git"
DEFAULT_DIR="/opt/navidrome"
BUILD_DIR="/tmp/navidrome-src"
SERVICE_NAME="navidrome"
DEFAULT_PORT=4533
GO_VERSION="1.27.3"
NODE_MIN=24

# ── helpers (logs to stderr) ───────────────────────────────────────────────
die() { echo -e "\n\033[1;31mError:\033[0m $*" >&2; exit 1; }
info() { echo -e "\033[1;34m==>\033[0m $*" >&2; }
ok() { echo -e "\033[1;32m==>\033[0m $*" >&2; }
warn() { echo -e "\033[1;33m==>\033[0m $*" >&2; }
prompt() { local var="$1" msg="$2" default="$3"; read -rp "$msg [$default]: " input; printf -v "$var" '%s' "${input:-$default}"; }
ask_yn() { local msg="$1" default="${2:-n}"; local ans; read -rp "$msg [y/N]: " ans; ans="${ans:-$default}"; [[ "$ans" =~ ^[Yy] ]]; }

elapsed() {
  local end=$(date +%s)
  local secs=$((end - START_TIME))
  printf '%dm %ds' $((secs/60)) $((secs%60))
}

# ── distro detection ───────────────────────────────────────────────────────
detect_distro() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    ID="${ID:-}"
    ID_LIKE="${ID_LIKE:-}"
  else
    die "Cannot detect distro (/etc/os-release missing)."
  fi

  case "$ID" in
    debian|ubuntu|linuxmint|pop|elementary|zorin) PKG="apt" ;;
    fedora|rhel|rocky|almalinux|centos|ol)         PKG="dnf" ;;
    arch|manjaro|endeavouros|garuda)               PKG="pacman" ;;
    opensuse*|sles)                                PKG="zypper" ;;
    alpine)                                        PKG="apk" ;;
    *)
      case "$ID_LIKE" in
        *debian*|*ubuntu*) PKG="apt" ;;
        *rhel*|*fedora*)   PKG="dnf" ;;
        *arch*)            PKG="pacman" ;;
        *suse*)            PKG="zypper" ;;
        *) die "Unsupported distro: $ID (ID_LIKE=$ID_LIKE). Supported: Debian/Ubuntu, Fedora/RHEL, Arch, openSUSE, Alpine." ;;
      esac
      ;;
  esac
  info "Detected: $ID ($PKG)"
}

# ── version helpers ────────────────────────────────────────────────────────
ver_ge() {
  # returns 0 if $1 >= $2
  printf '%s\n%s\n' "$2" "$1" | sort -V -C
}

# ── packages ───────────────────────────────────────────────────────────────
install_base_packages() {
  info "Installing base build packages..."
  case "$PKG" in
    apt)
      sudo apt-get update -qq
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
        git make pkg-config libtag1-dev ffmpeg curl ca-certificates tar
      ;;
    dnf)
      sudo dnf install -y \
        git make pkgconf-pkg-config taglib-devel ffmpeg curl ca-certificates tar
      ;;
    pacman)
      sudo pacman -Sy --noconfirm \
        git make pkgconf taglib ffmpeg curl ca-certificates tar
      ;;
    zypper)
      sudo zypper --non-interactive install \
        git make pkg-config libtag-devel ffmpeg curl ca-certificates tar
      ;;
    apk)
      sudo apk add --no-cache \
        git make pkgconf taglib-dev ffmpeg curl ca-certificates tar
      ;;
  esac
  ok "Base packages ready."
}

ensure_go() {
  local current=""
  if command -v go >/dev/null 2>&1; then
    current=$(go version | awk '{print $3}' | sed 's/go//')
  fi

  if [[ -n "$current" ]] && ver_ge "$current" "1.27"; then
    ok "Go $current is new enough"
    return 0
  fi

  info "Go ${current:-not found} is too old (need 1.27+). Installing official Go $GO_VERSION..."
  local tmp="/tmp/go${GO_VERSION}.linux-amd64.tar.gz"
  curl -fsSL -o "$tmp" "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz"
  sudo rm -rf /usr/local/go
  sudo tar -C /usr/local -xzf "$tmp"
  rm -f "$tmp"

  # Prefer the official install for this script and the build
  export PATH="/usr/local/go/bin:$PATH"
  hash -r
  ok "Installed $(go version)"
}

ensure_node() {
  local current=""
  if command -v node >/dev/null 2>&1; then
    current=$(node -v | sed 's/v//' | cut -d. -f1)
  fi

  if [[ -n "$current" ]] && (( current >= NODE_MIN )); then
    ok "Node $current is new enough"
    return 0
  fi

  info "Node ${current:-not found} is too old (need $NODE_MIN+). Installing Node $NODE_MIN from NodeSource..."
  # NodeSource works on most distros; fall back to a note if it fails
  if curl -fsSL "https://deb.nodesource.com/setup_${NODE_MIN}.x" | sudo bash - 2>/dev/null; then
    case "$PKG" in
      apt) sudo apt-get install -y nodejs ;;
      *)   warn "NodeSource setup ran; install nodejs with your package manager if needed." ;;
    esac
  else
    warn "Could not auto-install Node $NODE_MIN. Install it manually and re-run."
    warn "See: https://nodejs.org/ or your distro's nodejs24 package."
  fi

  if command -v node >/dev/null 2>&1; then
    ok "Node $(node -v) available"
  fi
}

# ── build ──────────────────────────────────────────────────────────────────
build_navidrome() {
  info "Cloning navidrome..."
  rm -rf "$BUILD_DIR"
  git clone --depth 1 "$REPO_URL" "$BUILD_DIR"
  cd "$BUILD_DIR"

  # Make sure the official Go is first if we installed it
  export PATH="/usr/local/go/bin:$PATH"

  info "Running make setup (downloads build deps)..."
  make setup

  info "Running make build..."
  make build

  [[ -x "$BUILD_DIR/navidrome" ]] || die "Build finished but binary not found."
  info "Build complete: $BUILD_DIR/navidrome"
}

# ── install ────────────────────────────────────────────────────────────────
install_files() {
  info "Installing to $INSTALL_DIR ..."
  sudo mkdir -p "$INSTALL_DIR/data" "$MUSIC_DIR"
  sudo cp "$BUILD_DIR/navidrome" "$INSTALL_DIR/navidrome"
  sudo chmod +x "$INSTALL_DIR/navidrome"

  sudo tee "$INSTALL_DIR/navidrome.toml" >/dev/null <<CONF
MusicFolder = "$MUSIC_DIR"
DataFolder = "$INSTALL_DIR/data"
Port = $DEFAULT_PORT
Address = "0.0.0.0"
CONF

  sudo chown -R "$USER:$USER" "$INSTALL_DIR"
  ok "Files installed."
}

create_service() {
  local bin="$INSTALL_DIR/navidrome"
  [[ -x "$bin" ]] || die "navidrome binary not found at $bin"

  if command -v systemctl >/dev/null 2>&1; then
    info "Creating systemd service..."
    sudo tee "/etc/systemd/system/${SERVICE_NAME}.service" >/dev/null <<UNIT
[Unit]
Description=Navidrome Music Server
After=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$INSTALL_DIR
ExecStart=$bin --configfile $INSTALL_DIR/navidrome.toml
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
    sudo systemctl daemon-reload
    sudo systemctl enable --now "$SERVICE_NAME"
    ok "systemd service enabled and started."
  else
    warn "No systemd detected. Start manually with: $bin --configfile $INSTALL_DIR/navidrome.toml"
  fi
}

# ── uninstall ──────────────────────────────────────────────────────────────
remove_service() {
  info "Removing service..."
  if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    sudo systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    sudo rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    sudo systemctl daemon-reload
    ok "systemd service removed."
  fi
}

remove_files() {
  local dir="${1:-$DEFAULT_DIR}"
  if [[ -d "$dir" ]]; then
    if ask_yn "Remove install directory $dir (includes data)?"; then
      sudo rm -rf "$dir"
      ok "Directory removed."
    else
      info "Kept $dir"
    fi
  else
    warn "Install directory $dir not found."
  fi
}

remove_build_dir() {
  if [[ -d "$BUILD_DIR" ]]; then
    if ask_yn "Remove build directory $BUILD_DIR?"; then
      rm -rf "$BUILD_DIR"
      ok "Build directory removed."
    fi
  fi
}

remove_packages() {
  if ask_yn "Also remove official Go from /usr/local/go?"; then
    sudo rm -rf /usr/local/go
    ok "Removed /usr/local/go"
  fi
  if ask_yn "Also remove other build packages (make, taglib, ffmpeg, etc.)? (may affect other software)"; then
    info "Removing packages..."
    case "$PKG" in
      apt)    sudo apt-get remove -y pkg-config libtag1-dev || true ;;
      dnf)    sudo dnf remove -y pkgconf-pkg-config taglib-devel || true ;;
      pacman) sudo pacman -Rns --noconfirm pkgconf taglib || true ;;
      zypper) sudo zypper --non-interactive remove pkg-config libtag-devel || true ;;
      apk)    sudo apk del pkgconf taglib-dev || true ;;
    esac
    ok "Package removal finished."
  else
    info "Packages kept."
  fi
}

uninstall() {
  echo "Navidrome uninstaller"
  echo "====================="
  detect_distro
  remove_service

  echo
  prompt INSTALL_DIR "Install directory to remove" "$DEFAULT_DIR"
  remove_files "$INSTALL_DIR"
  remove_build_dir
  remove_packages

  echo
  ok "Uninstall finished in $(elapsed)"
}

# ── main ───────────────────────────────────────────────────────────────────
main() {
  local mode="${1:-install}"

  case "$mode" in
    uninstall|remove|--uninstall|-u)
      uninstall
      ;;
    install|"")
      echo "Navidrome installer (from source)"
      echo "================================="
      detect_distro
      install_base_packages
      ensure_go
      ensure_node

      echo
      prompt INSTALL_DIR "Install directory" "$DEFAULT_DIR"
      prompt MUSIC_DIR "Music folder" "/mnt/music"

      build_navidrome
      install_files
      create_service

      local ip
      ip=$(hostname -I 2>/dev/null | awk '{print $1}') || ip="localhost"

      echo
      ok "Done in $(elapsed)"
      echo
      echo "  Open:  http://${ip:-localhost}:$DEFAULT_PORT"
      echo "  Files: $INSTALL_DIR"
      echo "  Music: $MUSIC_DIR"
      echo
      echo "Service commands:"
      if command -v systemctl >/dev/null 2>&1; then
        echo "  sudo systemctl status $SERVICE_NAME"
        echo "  sudo systemctl restart $SERVICE_NAME"
      fi
      echo
      echo "To uninstall later: bash $0 uninstall"
      ;;
    *)
      die "Unknown option: $mode. Use: $0 [install|uninstall]"
      ;;
  esac
}

main "$@"
