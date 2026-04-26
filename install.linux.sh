#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────
# Linux package installer — called by install.sh
# Usage: install.linux.sh [full]
# ──────────────────────────────────────────────

INSTALL_FULL="${1:-bare}"

# ──────────────────────────────────────────────
# Sudo check
# ──────────────────────────────────────────────
if ! command -v sudo &>/dev/null; then
  echo "⚠ sudo not found — can't install system packages"
  exit 1
fi

if ! sudo -n true 2>/dev/null; then
  echo "Need sudo to install packages..."
  sudo -v || { echo "⚠ Failed to get sudo — skipping packages"; exit 1; }
fi

# ──────────────────────────────────────────────
# Detect package manager
# ──────────────────────────────────────────────
PM=""
INSTALL=""
if command -v apt-get &>/dev/null; then
  PM="apt"
  INSTALL="sudo DEBIAN_FRONTEND=noninteractive apt-get install -y"
elif command -v yum &>/dev/null; then
  PM="yum"
  INSTALL="sudo yum install -y"
elif command -v pacman &>/dev/null; then
  PM="pacman"
  INSTALL="sudo pacman -S --noconfirm"
else
  echo "⚠ No supported package manager (apt/yum/pacman) found"
  exit 1
fi

# ──────────────────────────────────────────────
# Install zsh first (needed before everything)
# ──────────────────────────────────────────────
if ! command -v zsh &>/dev/null; then
  echo "Installing zsh..."
  [[ "$PM" == "apt" ]] && sudo apt-get update -qq
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

# Deduplicate (base and full share some entries like procps, fzf, ripgrep, etc.)
declare -A SEEN
UNIQUE=()
for pkg in "${PKGS[@]}"; do
  if [[ -z "${SEEN[$pkg]:-}" ]]; then
    SEEN[$pkg]=1
    UNIQUE+=("$pkg")
  fi
done

# ──────────────────────────────────────────────
# Install
# ──────────────────────────────────────────────
echo "Installing ${#UNIQUE[@]} packages..."
[[ "$PM" == "apt" ]] && sudo apt-get update -qq

for pkg in "${UNIQUE[@]}"; do
  echo "  → $pkg"
done

$INSTALL "${UNIQUE[@]}" 2>/dev/null || {
  # Some packages may not exist on all distros — try one-by-one
  echo "Bulk install had errors, falling back to one-by-one..."
  for pkg in "${UNIQUE[@]}"; do
    echo "  → $pkg"
    $INSTALL "$pkg" 2>/dev/null || echo "    ⚠ $pkg failed (may not exist in this distro)"
  done
}

echo "✓ Linux packages installed"

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
      | cut -d '"' -f 4)"
    if [[ -n "$SESH_URL" ]]; then
      tmp="$(mktemp -d)"
      curl -sL "$SESH_URL" -o "$tmp/sesh.tar.gz"
      tar -xzf "$tmp/sesh.tar.gz" -C "$tmp"
      sudo install -m 755 "$tmp/sesh" /usr/local/bin/sesh
      rm -rf "$tmp"
      echo "✓ sesh installed"
    else
      echo "  ⚠ sesh: could not find release URL"
    fi
  fi
elif command -v sesh &>/dev/null; then
  echo "✓ sesh already installed"
fi
