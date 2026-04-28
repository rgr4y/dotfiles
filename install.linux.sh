#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────
# Linux package installer — called by install.sh
# Usage: install.linux.sh [full]
# ──────────────────────────────────────────────

INSTALL_FULL="${1:-bare}"

if [[ -n "${RUNPOD_PUBLIC_IP:-}" ]]; then
  export COLUMNS=200
fi

# ──────────────────────────────────────────────
# Sudo check — skip if already root
# ──────────────────────────────────────────────
if [[ "$(id -u)" -eq 0 ]]; then
  SUDO=""
elif command -v sudo &>/dev/null; then
  if ! sudo -n true 2>/dev/null; then
    echo "Need sudo to install packages..."
    sudo -v || { echo "⚠ Failed to get sudo — skipping packages"; exit 1; }
  fi
  SUDO="sudo"
else
  echo "⚠ sudo not found and not root — can't install system packages"
  exit 1
fi

# ──────────────────────────────────────────────
# Detect package manager
# ──────────────────────────────────────────────
PM=""
INSTALL=""
if command -v apt-get &>/dev/null; then
  PM="apt"
  INSTALL="$SUDO env DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y"
elif command -v yum &>/dev/null; then
  PM="yum"
  INSTALL="$SUDO yum install -y"
elif command -v pacman &>/dev/null; then
  PM="pacman"
  INSTALL="$SUDO pacman -S --noconfirm"
else
  echo "⚠ No supported package manager (apt/yum/pacman) found"
  exit 1
fi

_pkg_installed() {
  case "$PM" in
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
  [[ "$PM" == "apt" ]] && $SUDO apt-get update -qq
  $INSTALL zsh
  echo "✓ zsh installed"
else
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
for pkg in "${PKGS[@]}"; do
  if [[ -z "${SEEN[$pkg]:-}" ]]; then
    SEEN[$pkg]=1
    if ! _pkg_installed "$pkg"; then
      NEEDED+=("$pkg")
    fi
  fi
done

# ──────────────────────────────────────────────
# Install
# ──────────────────────────────────────────────
if [[ ${#NEEDED[@]} -eq 0 ]]; then
  echo "✓ All ${#SEEN[@]} packages already installed"
else
  echo "Installing ${#NEEDED[@]} packages (${#SEEN[@]} total, $((${#SEEN[@]} - ${#NEEDED[@]})) already installed)..."
  [[ "$PM" == "apt" ]] && $SUDO apt-get update -qq

  for pkg in "${NEEDED[@]}"; do
    echo "  → $pkg"
  done

  $INSTALL "${NEEDED[@]}" 2>/dev/null || {
    echo "Bulk install had errors, falling back to one-by-one..."
    for pkg in "${NEEDED[@]}"; do
      echo "  → $pkg"
      $INSTALL "$pkg" 2>/dev/null || echo "    ⚠ $pkg failed (may not exist in this distro)"
    done
  }

  echo "✓ Linux packages installed"
fi

# ──────────────────────────────────────────────
# sesh (tmux session manager) — only if tmux installed
# ──────────────────────────────────────────────
if command -v tmux &>/dev/null && ! command -v sesh &>/dev/null; then
  echo "Installing sesh..."
  SESH_ARCH="$(uname -m)"
  case "$SESH_ARCH" in
    x86_64)  SESH_ARCH="x86_64" ;;
    aarch64) SESH_ARCH="arm64" ;;
    *)       echo "  ⚠ sesh: unsupported arch $SESH_ARCH"; SESH_ARCH="" ;;
  esac
  if [[ -n "$SESH_ARCH" ]]; then
    SESH_URL="$(curl -s https://api.github.com/repos/joshmedeski/sesh/releases/latest \
      | grep "browser_download_url.*Linux_${SESH_ARCH}.tar.gz" \
      | cut -d '"' -f 4 || true)"
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
if ! command -v dua &>/dev/null; then
  echo "Installing dua-cli..."
  DUA_ARCH="$(uname -m)"
  case "$DUA_ARCH" in
    x86_64)  DUA_TARGET="x86_64-unknown-linux-musl" ;;
    aarch64) DUA_TARGET="aarch64-unknown-linux-musl" ;;
    *)       echo "  ⚠ dua-cli: unsupported arch $DUA_ARCH"; DUA_TARGET="" ;;
  esac
  if [[ -n "$DUA_TARGET" ]]; then
    DUA_URL="$(curl -s https://api.github.com/repos/Byron/dua-cli/releases/latest \
      | grep "browser_download_url.*${DUA_TARGET}.tar.gz" \
      | cut -d '"' -f 4 || true)"
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
if ! command -v broot &>/dev/null; then
  echo "Installing broot..."
  BROOT_ARCH="$(uname -m)"
  case "$BROOT_ARCH" in
    x86_64)  BROOT_TARGET="x86_64-unknown-linux-musl" ;;
    aarch64) BROOT_TARGET="aarch64-unknown-linux-musl" ;;
    *)       echo "  ⚠ broot: unsupported arch $BROOT_ARCH"; BROOT_TARGET="" ;;
  esac
  if [[ -n "$BROOT_TARGET" ]]; then
    BROOT_URL="$(curl -s https://api.github.com/repos/Canop/broot/releases/latest \
      | grep "browser_download_url.*\.zip" \
      | head -1 \
      | cut -d '"' -f 4 || true)"
    if [[ -n "$BROOT_URL" ]]; then
      tmp="$(mktemp -d)"
      curl -sL "$BROOT_URL" -o "$tmp/broot.zip"
      (cd "$tmp" && unzip -qo broot.zip)
      BROOT_BIN="$(find "$tmp" -name "broot" -path "*${BROOT_TARGET}*" -type f 2>/dev/null | head -1)"
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
