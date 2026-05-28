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
LISTS_CACHE="$CACHE_DIR/apt-lists.tar.gz"
ZSH_CACHE="$CACHE_DIR/zsh.tar.gz"
CACHE_BINS=(/usr/local/bin/sesh /usr/local/bin/dua /usr/local/bin/broot)
_log "CACHE_DIR=$CACHE_DIR"
_log "BIN_CACHE exists: $(test -f "$BIN_CACHE" && echo yes || echo no)"
_log "DEB_CACHE exists: $(test -f "$DEB_CACHE" && echo yes || echo no)"
_log "LISTS_CACHE exists: $(test -f "$LISTS_CACHE" && echo yes || echo no)"
_log "ZSH_CACHE exists: $(test -f "$ZSH_CACHE" && echo yes || echo no)"

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

# Restore cached apt lists or run apt-get update, then save lists after
_apt_update() {
  local lists_dir="/var/lib/apt/lists"
  if [[ -f "$LISTS_CACHE" ]]; then
    _log "Restoring apt lists from cache ($(du -h "$LISTS_CACHE" | cut -f1))..."
    $SUDO tar xzf "$LISTS_CACHE" -C "$lists_dir" 2>/dev/null && \
      _log "apt lists restored from cache" || \
      { _log "apt lists cache corrupt, running update"; _apt_update_network; }
  else
    _apt_update_network
  fi
}

_apt_update_network() {
  local lists_dir="/var/lib/apt/lists"
  _log "Waiting for apt lock..."
  local i=0
  while fuser /var/lib/apt/lists/lock /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend &>/dev/null 2>&1; do
    (( i++ ))
    if (( i > 30 )); then
      _log "apt lock wait timed out after 30s"
      break
    fi
    sleep 1
  done
  _log "Running apt-get update..."
  $SUDO apt-get update -qq
  _log "apt-get update exit code: $?"
  local list_count
  list_count=$(find "$lists_dir" -maxdepth 1 -type f | wc -l)
  if [[ "$list_count" -gt 0 ]]; then
    mkdir -p "$CACHE_DIR"
    $SUDO tar czf "$LISTS_CACHE" -C "$lists_dir" . 2>/dev/null && \
      _log "apt lists cached ($(du -h "$LISTS_CACHE" | cut -f1))"
    $SUDO chown "$(id -u):$(id -g)" "$LISTS_CACHE" 2>/dev/null || true
  fi
}

# ──────────────────────────────────────────────
# Install zsh first (needed before everything)
# ──────────────────────────────────────────────
if ! command -v zsh &>/dev/null; then
  if [[ -f "$ZSH_CACHE" ]]; then
    _log "Restoring zsh from binary cache..."
    $SUDO tar xzf "$ZSH_CACHE" -C / 2>/dev/null
    if command -v zsh &>/dev/null; then
      echo "✓ zsh restored from cache"
    else
      _log "zsh cache restore failed, installing via $PM"
      if [[ "$PM" == "apt" ]]; then _apt_update; fi
      $INSTALL zsh
      _log "zsh install exit code: $?"
      echo "✓ zsh installed"
    fi
  else
    echo "Installing zsh..."
    _log "zsh not found, installing via $PM"
    if [[ "$PM" == "apt" ]]; then
      _apt_update
    fi
    _log "Running: $INSTALL zsh"
    $INSTALL zsh
    _log "zsh install exit code: $?"
    # Save zsh binary cache
    if command -v zsh &>/dev/null && [[ "$PM" == "apt" ]]; then
      mkdir -p "$CACHE_DIR"
      _log "Saving zsh binary cache..."
      $SUDO tar czf "$ZSH_CACHE" \
        /usr/bin/zsh \
        /usr/bin/zsh5 \
        /usr/lib/x86_64-linux-gnu/zsh 2>/dev/null && {
        $SUDO chown "$(id -u):$(id -g)" "$ZSH_CACHE" 2>/dev/null || true
        _log "zsh cache saved ($(du -h "$ZSH_CACHE" | cut -f1))"
      }
    fi
    echo "✓ zsh installed"
  fi
  _log "zsh now at: $(command -v zsh 2>/dev/null || echo NOT_FOUND)"
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
  dialog util-linux dnsutils
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
  tmp="$(mktemp -d)"
  _log "Extracting to $tmp"
  tar xzf "$DEB_CACHE" -C "$tmp" 2>/dev/null || true
  deb_count="$(ls "$tmp"/*.deb 2>/dev/null | wc -l)"
  _log "Debs in cache: $deb_count"
  if [[ "$deb_count" -eq 0 ]]; then
    _log "Cache empty or corrupt, removing and falling through to network install"
    rm -f "$DEB_CACHE"
    rm -rf "$tmp"
    _apt_update
    $INSTALL "${NEEDED[@]}" 2>&1 || {
      for pkg in "${NEEDED[@]}"; do
        $INSTALL "$pkg" 2>/dev/null || echo "    ⚠ $pkg failed"
      done
    }
    echo "✓ Linux packages installed"
  else
    echo "Restoring ${#NEEDED[@]} packages from cache..."
    _log "Running dpkg -i..."
    $SUDO dpkg -i "$tmp"/*.deb 2>&1 | tail -5
    _log "dpkg exit code: ${PIPESTATUS[0]}"
    _log "Running apt-get install -f..."
    $SUDO apt-get install -f -y --no-install-recommends 2>&1 | tail -5
    _log "apt-get -f exit code: ${PIPESTATUS[0]}"
    rm -rf "$tmp"
    local_still_missing=()
    for pkg in "${NEEDED[@]}"; do
      _pkg_installed "$pkg" || local_still_missing+=("$pkg")
    done
    if [[ ${#local_still_missing[@]} -gt 0 ]]; then
      _log "Still missing after cache restore: ${local_still_missing[*]}"
      echo "⚠ ${#local_still_missing[@]} packages not in cache, installing from network..."
      _apt_update
      $INSTALL "${local_still_missing[@]}" 2>/dev/null || {
        for pkg in "${local_still_missing[@]}"; do
          $INSTALL "$pkg" 2>/dev/null || echo "    ⚠ $pkg failed"
        done
      }
    fi
    echo "✓ Packages restored from cache"
  fi
else
  _log "Taking slow path (no cache or not apt)"
  echo "Installing ${#NEEDED[@]} packages (${#SEEN[@]} total, $((${#SEEN[@]} - ${#NEEDED[@]})) already installed)..."
  if [[ "$PM" == "apt" ]]; then
    _apt_update
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
    apt_deb_count="$(ls /var/cache/apt/archives/*.deb 2>/dev/null | wc -l)"
    _log "Caching debs from /var/cache/apt/archives..."
    _log "Deb count: $apt_deb_count"
    if [[ "$apt_deb_count" -gt 0 ]]; then
      mkdir -p "$CACHE_DIR"
      tar czf "$DEB_CACHE" -C /var/cache/apt/archives $(ls /var/cache/apt/archives/*.deb | xargs -n1 basename) 2>/dev/null && \
        echo "✓ Deb cache saved to $DEB_CACHE ($(du -h "$DEB_CACHE" | cut -f1))"
    else
      _log "No debs in apt cache, skipping cache save"
    fi
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
