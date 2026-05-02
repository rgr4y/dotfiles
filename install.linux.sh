#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────
# Linux package installer — called by install.sh
# Usage: install.linux.sh [full]
# ──────────────────────────────────────────────

INSTALL_FULL="${1:-bare}"

_log() { echo "  [debug] $*"; }

if [[ -n "${RUNPOD_PUBLIC_IP:-}" ]]; then
  export COLUMNS=200
  _log "RunPod detected, COLUMNS=$COLUMNS"
fi

_log "INSTALL_FULL=$INSTALL_FULL"
_log "HOME=$HOME"
_log "USER=$(whoami) UID=$(id -u)"
_log "SHELL=$SHELL"
_log "PATH=$PATH"
_log "uname: $(uname -a)"
_log "GOOGLE_CLOUD_SHELL=${GOOGLE_CLOUD_SHELL:-unset}"
_log "RUNPOD_PUBLIC_IP=${RUNPOD_PUBLIC_IP:-unset}"

# ──────────────────────────────────────────────
# Cache dir for fast restore on ephemeral systems
# ──────────────────────────────────────────────
CACHE_DIR="$HOME/.dotfiles-cache"
BIN_CACHE="$CACHE_DIR/bin.tar.gz"
DEB_CACHE="$CACHE_DIR/debs.tar.gz"
CACHE_BINS=(/usr/local/bin/sesh /usr/local/bin/dua /usr/local/bin/broot)
_log "CACHE_DIR=$CACHE_DIR"
_log "BIN_CACHE exists: $(test -f "$BIN_CACHE" && echo yes || echo no)"
_log "DEB_CACHE exists: $(test -f "$DEB_CACHE" && echo yes || echo no)"

# ──────────────────────────────────────────────
# Sudo check — skip if already root
# ──────────────────────────────────────────────
if [[ "$(id -u)" -eq 0 ]]; then
  SUDO=""
  _log "Running as root, no sudo needed"
elif command -v sudo &>/dev/null; then
  _log "sudo found at $(command -v sudo)"
  if ! sudo -n true 2>/dev/null; then
    echo "Need sudo to install packages..."
    sudo -v || { echo "⚠ Failed to get sudo — skipping packages"; exit 0; }
  fi
  SUDO="sudo"
  _log "SUDO=sudo (passwordless=$(sudo -n true 2>/dev/null && echo yes || echo no))"
else
  echo "⚠ sudo not found and not root — skipping packages"
  exit 0
fi

# ──────────────────────────────────────────────
# Detect package manager
# ──────────────────────────────────────────────
PM=""
INSTALL=""
if command -v apk &>/dev/null; then
  PM="apk"
  INSTALL="$SUDO apk add --no-cache"
elif command -v apt-get &>/dev/null; then
  PM="apt"
  INSTALL="$SUDO env DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y"
elif command -v yum &>/dev/null; then
  PM="yum"
  INSTALL="$SUDO yum install -y"
elif command -v pacman &>/dev/null; then
  PM="pacman"
  INSTALL="$SUDO pacman -S --noconfirm"
else
  echo "⚠ No supported package manager (apk/apt/yum/pacman) found — skipping"
  exit 0
fi
_log "PM=$PM"
_log "INSTALL=$INSTALL"

_pkg_installed() {
  case "$PM" in
    apk)    apk info -e "$1" &>/dev/null ;;
    apt)    dpkg -s "$1" &>/dev/null ;;
    yum)    rpm -q "$1" &>/dev/null ;;
    pacman) pacman -Qi "$1" &>/dev/null ;;
  esac
}

# ──────────────────────────────────────────────
# Install zsh first (needed before everything)
# ──────────────────────────────────────────────
if ! command -v zsh &>/dev/null; then
  echo "Installing zsh..."
  _log "zsh not found, installing via $PM"
  if [[ "$PM" == "apt" ]]; then
    _log "Running apt-get update..."
    $SUDO apt-get update -qq
    _log "apt-get update exit code: $?"
  fi
  _log "Running: $INSTALL zsh"
  $INSTALL zsh
  _log "zsh install exit code: $?"
  _log "zsh now at: $(command -v zsh 2>/dev/null || echo NOT_FOUND)"
  echo "✓ zsh installed"
else
  _log "zsh already at: $(command -v zsh)"
  echo "✓ zsh already installed"
fi

# ──────────────────────────────────────────────
# Base packages (always installed)
# ──────────────────────────────────────────────
BASE_PKGS=(
  git curl htop ncat netcat-openbsd aria2
  command-not-found fzf ripgrep tcpdump
  procps lsof wget pv file unzip eza
  vim bat
)

# ──────────────────────────────────────────────
# Full packages (only with "full" profile)
# ──────────────────────────────────────────────
FULL_PKGS=(
  iftop iotop btop tree screen tmux rsync rclone
  dialog util-linux toilet figlet dnsutils
  iputils-ping iproute2 net-tools pigz nmap less
  jq m4 iperf3 gh
)

# ──────────────────────────────────────────────
# Build final list
# ──────────────────────────────────────────────
PKGS=("${BASE_PKGS[@]}")
if [[ "$INSTALL_FULL" == "full" ]]; then
  PKGS+=("${FULL_PKGS[@]}")
fi

# Deduplicate and filter already-installed packages
declare -A SEEN
NEEDED=()
ALREADY=()
for pkg in "${PKGS[@]}"; do
  if [[ -z "${SEEN[$pkg]:-}" ]]; then
    SEEN[$pkg]=1
    if ! _pkg_installed "$pkg"; then
      NEEDED+=("$pkg")
    else
      ALREADY+=("$pkg")
    fi
  fi
done
_log "Total packages: ${#SEEN[@]}"
_log "Already installed (${#ALREADY[@]}): ${ALREADY[*]}"
_log "Needed (${#NEEDED[@]}): ${NEEDED[*]}"

# ──────────────────────────────────────────────
# Install (with deb cache fast-path)
# ──────────────────────────────────────────────
if [[ ${#NEEDED[@]} -eq 0 ]]; then
  echo "✓ All ${#SEEN[@]} packages already installed"
elif [[ "$PM" == "apt" && -f "$DEB_CACHE" ]]; then
  _log "Taking deb cache fast-path"
  _log "DEB_CACHE size: $(du -h "$DEB_CACHE" 2>/dev/null | cut -f1)"
  echo "Restoring ${#NEEDED[@]} packages from cache..."
  tmp="$(mktemp -d)"
  _log "Extracting to $tmp"
  tar xzf "$DEB_CACHE" -C "$tmp"
  _log "Debs in cache: $(ls "$tmp"/*.deb 2>/dev/null | wc -l)"
  _log "Running dpkg -i..."
  $SUDO dpkg -i "$tmp"/*.deb 2>&1 | tail -5
  _log "dpkg exit code: ${PIPESTATUS[0]}"
  _log "Running apt-get install -f..."
  $SUDO apt-get install -f -y --no-install-recommends 2>&1 | tail -5
  _log "apt-get -f exit code: ${PIPESTATUS[0]}"
  rm -rf "$tmp"
  # Verify what's still missing after cache restore
  local_still_missing=()
  for pkg in "${NEEDED[@]}"; do
    _pkg_installed "$pkg" || local_still_missing+=("$pkg")
  done
  if [[ ${#local_still_missing[@]} -gt 0 ]]; then
    _log "Still missing after cache restore: ${local_still_missing[*]}"
    echo "⚠ ${#local_still_missing[@]} packages not in cache, installing from network..."
    $SUDO apt-get update -qq
    $INSTALL "${local_still_missing[@]}" 2>/dev/null || {
      for pkg in "${local_still_missing[@]}"; do
        $INSTALL "$pkg" 2>/dev/null || echo "    ⚠ $pkg failed"
      done
    }
  fi
  echo "✓ Packages restored from cache"
else
  _log "Taking slow path (no cache or not apt)"
  echo "Installing ${#NEEDED[@]} packages (${#SEEN[@]} total, $((${#SEEN[@]} - ${#NEEDED[@]})) already installed)..."
  if [[ "$PM" == "apt" ]]; then
    _log "Running apt-get update..."
    $SUDO apt-get update -qq
    _log "apt-get update exit code: $?"
  fi

  for pkg in "${NEEDED[@]}"; do
    echo "  → $pkg"
  done

  _log "Running bulk install..."
  $INSTALL "${NEEDED[@]}" 2>&1 || {
    _log "Bulk install failed, falling back to one-by-one"
    echo "Bulk install had errors, falling back to one-by-one..."
    for pkg in "${NEEDED[@]}"; do
      echo "  → $pkg"
      $INSTALL "$pkg" 2>&1 || echo "    ⚠ $pkg failed (may not exist in this distro)"
    done
  }

  # Verify
  for pkg in "${NEEDED[@]}"; do
    if _pkg_installed "$pkg"; then
      _log "  ✓ $pkg installed"
    else
      _log "  ✗ $pkg NOT installed"
    fi
  done

  # Cache debs for next boot
  if [[ "$PM" == "apt" ]]; then
    mkdir -p "$CACHE_DIR"
    _log "Caching debs from /var/cache/apt/archives..."
    _log "Deb count: $(ls /var/cache/apt/archives/*.deb 2>/dev/null | wc -l)"
    tar czf "$DEB_CACHE" -C /var/cache/apt/archives . 2>/dev/null && \
      echo "✓ Deb cache saved to $DEB_CACHE ($(du -h "$DEB_CACHE" | cut -f1))"
  fi

  echo "✓ Linux packages installed"
fi

# ──────────────────────────────────────────────
# Binary tools — restore from cache or download
# ──────────────────────────────────────────────
_bins_all_present() {
  for b in "${CACHE_BINS[@]}"; do
    [[ -x "$b" ]] || return 1
  done
  return 0
}

_save_bin_cache() {
  local existing=()
  for b in "${CACHE_BINS[@]}"; do
    if [[ -x "$b" ]]; then
      existing+=("$b")
      _log "  cache candidate: $b ($(du -h "$b" 2>/dev/null | cut -f1))"
    else
      _log "  skip (not found): $b"
    fi
  done
  if [[ ${#existing[@]} -gt 0 ]]; then
    mkdir -p "$CACHE_DIR"
    tar czf "$BIN_CACHE" "${existing[@]}" 2>/dev/null && \
      echo "✓ Binary cache saved (${#existing[@]} tools, $(du -h "$BIN_CACHE" | cut -f1))"
  else
    _log "No binaries to cache"
  fi
}

for b in "${CACHE_BINS[@]}"; do
  _log "Binary check: $b exists=$(test -x "$b" && echo yes || echo no)"
done

if [[ -f "$BIN_CACHE" ]] && ! _bins_all_present; then
  _log "BIN_CACHE size: $(du -h "$BIN_CACHE" 2>/dev/null | cut -f1)"
  echo "Restoring binaries from cache..."
  tar xzf "$BIN_CACHE" -C / 2>/dev/null
  _log "tar exit code: $?"
  for b in "${CACHE_BINS[@]}"; do
    _log "  After restore: $b exists=$(test -x "$b" && echo yes || echo no)"
  done
  echo "✓ Binaries restored from cache"
elif [[ -f "$BIN_CACHE" ]]; then
  _log "All binaries present, skipping cache restore"
else
  _log "No bin cache found, will download individually"
fi

# ──────────────────────────────────────────────
# sesh (tmux session manager) — only if tmux installed
# ──────────────────────────────────────────────
_log "tmux=$(command -v tmux 2>/dev/null || echo NOT_FOUND) sesh=$(command -v sesh 2>/dev/null || echo NOT_FOUND)"
if command -v tmux &>/dev/null && ! command -v sesh &>/dev/null; then
  echo "Installing sesh..."
  SESH_ARCH="$(uname -m)"
  _log "SESH_ARCH=$SESH_ARCH"
  case "$SESH_ARCH" in
    x86_64)  SESH_ARCH="x86_64" ;;
    aarch64) SESH_ARCH="arm64" ;;
    *)       echo "  ⚠ sesh: unsupported arch $SESH_ARCH"; SESH_ARCH="" ;;
  esac
  if [[ -n "$SESH_ARCH" ]]; then
    _log "Fetching sesh release URL from GitHub API..."
    SESH_URL="$(curl -s https://api.github.com/repos/joshmedeski/sesh/releases/latest \
      | grep "browser_download_url.*Linux_${SESH_ARCH}.tar.gz" \
      | cut -d '"' -f 4 || true)"
    _log "SESH_URL=${SESH_URL:-EMPTY}"
    if [[ -n "$SESH_URL" ]]; then
      tmp="$(mktemp -d)"
      curl -sL "$SESH_URL" -o "$tmp/sesh.tar.gz"
      tar -xzf "$tmp/sesh.tar.gz" -C "$tmp"
      $SUDO install -m 755 "$tmp/sesh" /usr/local/bin/sesh
      rm -rf "$tmp"
      echo "✓ sesh installed"
    else
      echo "  ⚠ sesh: could not find release URL"
    fi
  fi
elif command -v sesh &>/dev/null; then
  echo "✓ sesh already installed"
fi

# ──────────────────────────────────────────────
# dua-cli (disk usage analyzer)
# ──────────────────────────────────────────────
_log "dua=$(command -v dua 2>/dev/null || echo NOT_FOUND)"
if ! command -v dua &>/dev/null; then
  echo "Installing dua-cli..."
  DUA_ARCH="$(uname -m)"
  _log "DUA_ARCH=$DUA_ARCH"
  case "$DUA_ARCH" in
    x86_64)  DUA_TARGET="x86_64-unknown-linux-musl" ;;
    aarch64) DUA_TARGET="aarch64-unknown-linux-musl" ;;
    *)       echo "  ⚠ dua-cli: unsupported arch $DUA_ARCH"; DUA_TARGET="" ;;
  esac
  if [[ -n "$DUA_TARGET" ]]; then
    _log "Fetching dua-cli release URL from GitHub API..."
    DUA_URL="$(curl -s https://api.github.com/repos/Byron/dua-cli/releases/latest \
      | grep "browser_download_url.*${DUA_TARGET}.tar.gz" \
      | cut -d '"' -f 4 || true)"
    _log "DUA_URL=${DUA_URL:-EMPTY}"
    if [[ -n "$DUA_URL" ]]; then
      tmp="$(mktemp -d)"
      curl -sL "$DUA_URL" -o "$tmp/dua.tar.gz"
      tar -xzf "$tmp/dua.tar.gz" -C "$tmp"
      $SUDO install -m 755 "$tmp"/dua-*/dua /usr/local/bin/dua
      rm -rf "$tmp"
      echo "✓ dua-cli installed"
    else
      echo "  ⚠ dua-cli: could not find release URL"
    fi
  fi
elif command -v dua &>/dev/null; then
  echo "✓ dua-cli already installed"
fi

# ──────────────────────────────────────────────
# broot (file navigator/manager)
# ──────────────────────────────────────────────
_log "broot=$(command -v broot 2>/dev/null || echo NOT_FOUND)"
if ! command -v broot &>/dev/null; then
  echo "Installing broot..."
  BROOT_ARCH="$(uname -m)"
  _log "BROOT_ARCH=$BROOT_ARCH"
  case "$BROOT_ARCH" in
    x86_64)  BROOT_TARGET="x86_64-unknown-linux-musl" ;;
    aarch64) BROOT_TARGET="aarch64-unknown-linux-musl" ;;
    *)       echo "  ⚠ broot: unsupported arch $BROOT_ARCH"; BROOT_TARGET="" ;;
  esac
  if [[ -n "$BROOT_TARGET" ]]; then
    _log "Fetching broot release URL from GitHub API..."
    BROOT_URL="$(curl -s https://api.github.com/repos/Canop/broot/releases/latest \
      | grep "browser_download_url.*\.zip" \
      | head -1 \
      | cut -d '"' -f 4 || true)"
    _log "BROOT_URL=${BROOT_URL:-EMPTY}"
    if [[ -n "$BROOT_URL" ]]; then
      tmp="$(mktemp -d)"
      curl -sL "$BROOT_URL" -o "$tmp/broot.zip"
      (cd "$tmp" && unzip -qo broot.zip)
      BROOT_BIN="$(find "$tmp" -name "broot" -path "*${BROOT_TARGET}*" -type f 2>/dev/null | head -1)"
      _log "BROOT_BIN=${BROOT_BIN:-EMPTY}"
      _log "Zip contents: $(find "$tmp" -type f 2>/dev/null | head -10)"
      if [[ -n "$BROOT_BIN" ]]; then
        $SUDO install -m 755 "$BROOT_BIN" /usr/local/bin/broot
        echo "✓ broot installed"
      else
        echo "  ⚠ broot: no binary found for $BROOT_TARGET in zip"
      fi
      rm -rf "$tmp"
    else
      echo "  ⚠ broot: could not find release URL"
    fi
  fi
elif command -v broot &>/dev/null; then
  echo "✓ broot already installed"
fi

# ──────────────────────────────────────────────
# Save binary cache if we downloaded anything new
# ──────────────────────────────────────────────
_save_bin_cache
