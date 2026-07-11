#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────
# Dotfiles Bootstrap — install.sh
# curl -sL lolf.art/ing.sh | bash
# ──────────────────────────────────────────────

CHEZMOI_REPO="https://github.com/rgr4y/dotfiles.git"
CHEZMOI_BIN_DIR="$HOME/.local/bin"
# chezmoi is a ~CHEZMOI_SIZE_MB MB static binary. On cramped embedded rootfs the
# default target ($HOME/.local/bin) may be near-full — if the *real* backing fs
# (symlinks resolved) has < LOW_DISK_MB free, ask where to put it (roomy data
# mount, global if root/sudo, or ephemeral /tmp).
LOW_DISK_MB="${LOW_DISK_MB:-128}"
CHEZMOI_SIZE_MB="${CHEZMOI_SIZE_MB:-20}"
ZI_HOME="$HOME/.zi"
PLUG_VIM="$HOME/.vim/autoload/plug.vim"
DATA_FILE=""  # set after chezmoi source-path is known

# ──────────────────────────────────────────────
# 1. OS & Capabilities
# ──────────────────────────────────────────────
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "$OS" in
  darwin) OS="darwin" ;;
  linux)  OS="linux"  ;;
  *)      echo "Unsupported OS: $OS"; exit 1 ;;
esac
export DOTFILES_OS="$OS"

HAS_SUDO=0
if command -v sudo &>/dev/null && sudo -n true 2>/dev/null; then
  HAS_SUDO=1
fi

# Sudo prefix for package installs (empty if root or no sudo).
SUDO=""
if [[ "$(id -u)" -ne 0 && $HAS_SUDO -eq 1 ]]; then SUDO="sudo"; fi

HAS_ZSH=0
if command -v zsh &>/dev/null; then
  HAS_ZSH=1
fi

PKG_MGR=""
if command -v brew &>/dev/null; then
  PKG_MGR="brew"
elif command -v apt-get &>/dev/null; then
  PKG_MGR="apt"
elif command -v apk &>/dev/null; then
  PKG_MGR="apk"
elif command -v opkg &>/dev/null; then
  PKG_MGR="opkg"
fi

# ──────────────────────────────────────────────
# Low-power / space-constrained detection
# ──────────────────────────────────────────────
# LOWPOWER trips on ANY of:
#   - 32-bit ARM (armv6l/armv7l/armhf/armel) — genuinely tiny SoCs
#   - opkg/apk package manager (OpenWrt / Alpine embedded images)
#   - < LOWPOWER_DISK_MB free on the $HOME backing fs
# aarch64 alone is NOT low-power (could be Graviton / Pi4 8GB / arm64 VM); it
# only trips lowpower via opkg/apk or the disk check.
# When LOWPOWER: the profile is HARD-FORCED to "bare" (menu skipped), chezmoi is
# staged in /tmp and removed after apply, and .git dirs are stripped post-apply.
LOWPOWER_DISK_MB="${LOWPOWER_DISK_MB:-128}"
ARCH="$(uname -m)"
LOWPOWER=0
LOWPOWER_WHY=""
case "$ARCH" in
  armv[67]*|armhf|armel) LOWPOWER=1; LOWPOWER_WHY="arch=$ARCH" ;;
esac
if [[ "$PKG_MGR" == "opkg" || "$PKG_MGR" == "apk" ]]; then
  LOWPOWER=1; LOWPOWER_WHY="${LOWPOWER_WHY:+$LOWPOWER_WHY }pkg=$PKG_MGR"
fi
_home_free_mb="$(df -m "$HOME" 2>/dev/null | awk 'NR==2{print $4}')"
if [[ -n "$_home_free_mb" && "$_home_free_mb" -lt "$LOWPOWER_DISK_MB" ]]; then
  LOWPOWER=1; LOWPOWER_WHY="${LOWPOWER_WHY:+$LOWPOWER_WHY }disk=${_home_free_mb}MB"
fi
# IS_TINY kept as an alias — existing skip guards (vim-plug, nerd font, vim
# plugins) reference it.
IS_TINY=$LOWPOWER

echo "┌─────────────────────────────────────┐"
echo "│  Dotfiles Bootstrap                 │"
echo "│  OS: $OS  sudo: $HAS_SUDO  zsh: $HAS_ZSH       │"
echo "│  pkg: ${PKG_MGR:-none}                          │"
echo "└─────────────────────────────────────┘"
if [[ $LOWPOWER -eq 1 ]]; then
  echo "  ⚡ low-power system ($LOWPOWER_WHY) → 'bare' profile forced"
fi
echo

# ──────────────────────────────────────────────
# 1b. Ensure SSL certs exist (needed before any curl/git)
# ──────────────────────────────────────────────
if ! curl -fsL https://github.com --head -o /dev/null 2>/dev/null; then
  echo "⚠ SSL certs missing — installing ca-certificates..."
  if [[ "$PKG_MGR" == "opkg" ]]; then
    opkg update 2>/dev/null || true
    opkg install ca-certificates ca-bundle 2>/dev/null || true
  elif [[ "$PKG_MGR" == "apt" ]]; then
    sudo apt-get update -qq 2>/dev/null && sudo apt-get install -y -qq ca-certificates 2>/dev/null || true
  fi
  # Verify fix worked
  if curl -fsL https://github.com --head -o /dev/null 2>/dev/null; then
    echo "✓ SSL certs installed"
  else
    echo "⚠ SSL still failing — curl will use -k (insecure) as fallback"
    # Export so all curl calls in this script can pick it up
    export CURL_INSECURE=1
  fi
fi

# Helper: curl wrapper that falls back to insecure if certs broken
_curl() {
  if [[ "${CURL_INSECURE:-0}" == "1" ]]; then
    curl -k "$@"
  else
    curl "$@"
  fi
}

# ──────────────────────────────────────────────
# 1c. Terminal UI helpers (needed by install + wizard)
# ──────────────────────────────────────────────
_tput() { tput "$@" 2>/dev/null || true; }
BOLD=$(_tput bold)
DIM=$(_tput dim)
RESET=$(_tput sgr0)
GREEN=$(_tput setaf 2)
CYAN=$(_tput setaf 6)
YELLOW=$(_tput setaf 3)

# True if a controlling terminal is reachable. Under `curl -sL … | bash` stdin is
# the PIPE (already at EOF), so `read` returns instantly and every interactive
# menu auto-picks its default — which is exactly why the profile menu "never
# appeared". Menus therefore read from /dev/tty, and skip entirely when it isn't
# reachable (true non-interactive runs: cron, CI).
_have_tty() { { true 0</dev/tty; } 2>/dev/null; }

# ──────────────────────────────────────────────
# 2. Install dependencies
# ──────────────────────────────────────────────
# Map uname -m to chezmoi release arch names
_chezmoi_arch() {
  case "$(uname -m)" in
    x86_64|amd64)     echo "amd64" ;;
    aarch64|arm64)    echo "arm64" ;;
    armv7*|armhf)     echo "arm"   ;;  # armv7 runs armv6 (arm) binary fine
    armv6*)           echo "arm"   ;;
    i386|i686)        echo "i386"  ;;
    mips)             echo "mips"  ;;
    mipsel|mips64el)  echo "mipsle" ;;
    *)                echo ""      ;;  # fallback to get.chezmoi.io
  esac
}

_chezmoi_download() {
  local dest="$1"
  local arch
  arch="$(_chezmoi_arch)"

  # If we know the arch, download directly — more reliable than get.chezmoi.io on odd platforms
  if [[ -n "$arch" ]]; then
    local ver
    ver="$(_curl -fsL https://api.github.com/repos/twpayne/chezmoi/releases/latest 2>/dev/null \
           | grep -o '"tag_name": *"[^"]*"' | head -1 | grep -o 'v[0-9][0-9.]*')"
    if [[ -z "$ver" ]]; then
      echo "⚠ Can't fetch latest chezmoi version, trying get.chezmoi.io..."
      sh -c "$(_curl -fsLS get.chezmoi.io)" -- -b "$dest"
      return
    fi

    local url="https://github.com/twpayne/chezmoi/releases/download/${ver}/chezmoi-linux-${arch}"
    echo "  Downloading chezmoi ${ver} for linux/${arch}..."
    if _curl -fsL "$url" -o "${dest}/chezmoi" && chmod +x "${dest}/chezmoi"; then
      return 0
    fi

    # Binary not available — try .tar.gz
    url="https://github.com/twpayne/chezmoi/releases/download/${ver}/chezmoi_${ver#v}_linux_${arch}.tar.gz"
    echo "  Trying tarball: ${url}..."
    local tmp
    tmp="$(mktemp -d)"
    if _curl -fsL "$url" -o "$tmp/chezmoi.tar.gz" && tar -xzf "$tmp/chezmoi.tar.gz" -C "$tmp" chezmoi 2>/dev/null; then
      mv "$tmp/chezmoi" "${dest}/chezmoi" && chmod +x "${dest}/chezmoi"
      rm -rf "$tmp"
      return 0
    fi
    rm -rf "$tmp"
    echo "⚠ Direct download failed, falling back to get.chezmoi.io..."
  fi

  sh -c "$(_curl -fsLS get.chezmoi.io)" -- -b "$dest"
}

# Canonical path with symlinks resolved (so a symlinked bin dir measures its
# REAL backing fs). Falls back gracefully where readlink -f / realpath are absent.
_resolve() {
  local p="$1"
  if readlink -f "$p" >/dev/null 2>&1; then readlink -f "$p"
  elif command -v realpath >/dev/null 2>&1; then realpath "$p" 2>/dev/null || echo "$p"
  else echo "$p"; fi
}

# Free MB on the fs backing $1, symlinks resolved; walks up if the path is absent.
_avail_mb() {
  local p; p="$(_resolve "$1")"
  while [[ -n "$p" && ! -e "$p" ]]; do
    [[ "$p" != */* ]] && { p="/"; break; }
    p="${p%/*}"; [[ -z "$p" ]] && p="/"
  done
  df -m "$p" 2>/dev/null | awk 'NR==2{print $4}'
}

# True if the binary can be created in $1 directly (dir or parent writable),
# following symlinks.
_can_write() {
  local d; d="$(_resolve "$1")"
  local parent
  [[ -d "$d" && -w "$d" ]] && return 0
  parent="${d%/*}"; [[ -z "$parent" ]] && parent="/"
  [[ -d "$parent" && -w "$parent" ]]
}

# Download chezmoi into $CHEZMOI_BIN_DIR. If $1 (use_sudo) is set, stage in a
# writable temp then install with sudo (for global dirs we can't write directly).
_place_chezmoi() {
  local use_sudo="$1" stage
  if [[ -n "$use_sudo" ]]; then
    stage="$(mktemp -d)"
    _chezmoi_download "$stage"
    $use_sudo install -m 0755 "$stage/chezmoi" "$CHEZMOI_BIN_DIR/chezmoi"
    rm -rf "$stage"
  else
    _chezmoi_download "$CHEZMOI_BIN_DIR"
  fi
}

# Ask where to install chezmoi. Silent default on roomy single-disk machines;
# prompts when the box is embedded, the real backing fs is tight, or more than
# one viable location exists. All space/writability checks resolve symlinks.
_select_chezmoi_dir() {
  local default_dir="$HOME/.local/bin"
  local default_avail; default_avail="$(_avail_mb "$default_dir")"
  local euid="${EUID:-$(id -u)}"

  # No terminal → can't prompt; use the default dir.
  if ! _have_tty; then echo "$default_dir"; return; fi

  local -a dirs=() labels=()

  # 1. default home (persistent) — space measured on its resolved fs
  dirs+=("$default_dir"); labels+=("$default_dir  (${default_avail:-?}MB, persistent)")

  # 2. roomy persistent data mounts (only if they hold >= 2x the binary)
  local m a cand
  for m in /userdata /mnt/data /mnt/sda /mnt/sdcard /data /opt; do
    { [[ -d "$m" ]] && _can_write "$m"; } || continue
    cand="$m/.local/bin"
    [[ "$(_resolve "$cand")" == "$(_resolve "$default_dir")" ]] && continue
    a="$(_avail_mb "$m")"
    [[ -z "$a" || "$a" -lt $((CHEZMOI_SIZE_MB * 2)) ]] && continue
    dirs+=("$cand"); labels+=("$cand  (${a}MB, persistent)")
  done

  # 3. GLOBAL install if root or sudo — shared, keeps the cramped home fs clean
  if [[ "$euid" -eq 0 || $HAS_SUDO -eq 1 ]]; then
    local g note; note="global"; [[ "$euid" -ne 0 ]] && note="global, sudo"
    for g in /usr/local/bin /opt/bin /usr/bin; do
      [[ -d "$g" ]] || continue
      a="$(_avail_mb "$g")"
      dirs+=("$g"); labels+=("$g  (${a:-?}MB, ${note})")
    done
  fi

  # 4. /tmp — ephemeral tmpfs (RAM), gone on reboot, but free on embedded boxes
  if [[ -d /tmp ]] && _can_write /tmp; then
    a="$(_avail_mb /tmp)"
    dirs+=("/tmp/.local/bin"); labels+=("/tmp/.local/bin  (${a:-?}MB, ${YELLOW}EPHEMERAL — lost on reboot${RESET})")
  fi

  # Silent default: roomy, not embedded, and nowhere better to offer.
  if [[ ${#dirs[@]} -le 1 || ( $IS_TINY -eq 0 && -n "$default_avail" && "$default_avail" -ge "$LOW_DISK_MB" ) ]]; then
    echo "$default_dir"
    return
  fi

  {
    echo
    if [[ -n "$default_avail" && "$default_avail" -lt "$LOW_DISK_MB" ]]; then
      echo "${YELLOW}⚠ Low disk:${RESET} ${default_dir} has ${default_avail}MB free (chezmoi ~${CHEZMOI_SIZE_MB}MB)."
    fi
    echo "${BOLD}Install chezmoi to:${RESET}"
    echo "${DIM}(↑/↓ to move, Enter to select)${RESET}"
    echo
  } >&2

  # Default highlight = most free space among persistent (non-/tmp) options.
  local selected=0 best_avail=0 i d
  for ((i = 0; i < ${#dirs[@]}; i++)); do
    d="${dirs[$i]}"; [[ "$d" == /tmp/* ]] && continue
    a="$(_avail_mb "$d")"
    if [[ -n "$a" && "$a" -gt "$best_avail" ]]; then best_avail="$a"; selected="$i"; fi
  done

  _tput civis
  while true; do
    for ((i = 0; i < ${#dirs[@]}; i++)); do
      if [[ $i -eq $selected ]]; then
        echo -e "\r  ${GREEN}▸ ${labels[$i]}${RESET}   " >&2
      else
        echo -e "\r    ${labels[$i]}   " >&2
      fi
    done
    IFS= read -rsn1 key </dev/tty
    case "$key" in
      A|k) [[ $selected -gt 0 ]] && selected=$((selected - 1)) ;;
      B|j) [[ $selected -lt $((${#dirs[@]} - 1)) ]] && selected=$((selected + 1)) ;;
      "")  break ;;
    esac
    printf "\033[%dA" "${#dirs[@]}" >&2
  done
  _tput cnorm
  echo >&2

  echo "${dirs[$selected]}"
}

install_chezmoi() {
  # Low-power / <128MB free: stage chezmoi in /tmp (tmpfs). It's bootstrap-only
  # here — cleanup_lowpower() removes it after apply. No prompt.
  if [[ $LOWPOWER -eq 1 ]]; then
    CHEZMOI_BIN_DIR="/tmp/.local/bin"
    echo "${YELLOW}⚡ low-power → staging chezmoi in $CHEZMOI_BIN_DIR (ephemeral, removed after apply)${RESET}"
  else
    CHEZMOI_BIN_DIR="$(_select_chezmoi_dir)"
  fi

  # Global dirs may not be writable directly — use sudo to place the binary.
  local use_sudo=""
  if ! _can_write "$CHEZMOI_BIN_DIR"; then
    if [[ "${EUID:-$(id -u)}" -ne 0 && $HAS_SUDO -eq 1 ]]; then
      use_sudo="sudo"
    else
      echo "⚠ $CHEZMOI_BIN_DIR not writable and no sudo — using \$HOME/.local/bin instead."
      CHEZMOI_BIN_DIR="$HOME/.local/bin"
    fi
  fi

  $use_sudo mkdir -p "$CHEZMOI_BIN_DIR"
  export PATH="$CHEZMOI_BIN_DIR:$PATH"

  case "$CHEZMOI_BIN_DIR" in
    /tmp/*) echo "${YELLOW}⚠ chezmoi in /tmp is EPHEMERAL — re-run this bootstrap after a reboot.${RESET}" ;;
  esac

  if ! command -v chezmoi &>/dev/null; then
    echo "Installing chezmoi to $CHEZMOI_BIN_DIR..."
    _place_chezmoi "$use_sudo"
    echo "✓ chezmoi installed"
    return
  fi

  local _bin _cur _lat
  _bin="$(command -v chezmoi)"
  if ! find "$_bin" -mtime +365 -print -quit 2>/dev/null | grep -q .; then
    echo "✓ chezmoi up to date ($(chezmoi --version 2>&1 | head -1))"
    return
  fi

  _cur="$(chezmoi --version 2>/dev/null | grep -o 'v[0-9][0-9.]*' | head -1)"
  _lat="$(_curl -fsL https://api.github.com/repos/twpayne/chezmoi/releases/latest 2>/dev/null \
          | grep -o '"tag_name": *"[^"]*"' | head -1 | grep -o 'v[0-9][0-9.]*')"
  if [[ -n "$_lat" && "$_cur" != "$_lat" ]]; then
    echo "chezmoi ${_cur} → ${_lat} — upgrading..."
    _place_chezmoi "$use_sudo"
    echo "✓ chezmoi upgraded"
  else
    echo "✓ chezmoi ${_cur:-unknown} is latest"
  fi
}

install_zi() {
  if ! command -v git &>/dev/null; then
    echo "⚠ git not found — skipping zi"
    return
  fi
  if [[ -f "$ZI_HOME/bin/zi.zsh" ]]; then
    echo "✓ zi already installed"
    return
  fi
  echo "Installing zi..."
  mkdir -p "$ZI_HOME/bin"
  git clone --depth 1 https://github.com/z-shell/zi.git "$ZI_HOME/bin" 2>/dev/null
  echo "✓ zi installed"
}

install_vim_plug() {
  if [[ $IS_TINY -eq 1 ]]; then
    echo "✓ skipping vim-plug on ${ARCH} (tiny/embedded)"
    return
  fi
  if [[ -f "$PLUG_VIM" ]]; then
    echo "✓ vim-plug already installed"
    return
  fi
  echo "Installing vim-plug..."
  _curl -fLo "$PLUG_VIM" --create-dirs \
    https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim 2>/dev/null
  echo "✓ vim-plug installed"
}

install_packages_opkg() {
  # Minimal, SPACE-CHECKED, incremental install for embedded/OpenWrt (opkg).
  # Space is re-checked before EACH package; if we drop below the floor we STOP
  # and log everything skipped (never silently truncate).
  local FLOOR_KB="${OPKG_FLOOR_KB:-2048}"   # 2MB minimum free on root overlay

  _opkg_free_kb() { df /overlay 2>/dev/null | awk 'NR==2{print $4}' || df / 2>/dev/null | awk 'NR==2{print $4}'; }
  _opkg_pkg_exists() { opkg list "$1" 2>/dev/null | grep -q "^$1 "; }

  local avail_kb; avail_kb="$(_opkg_free_kb)"
  if [[ -n "$avail_kb" && "$avail_kb" -lt "$FLOOR_KB" ]]; then
    echo "⚠ Only ${avail_kb}KB free — need $((FLOOR_KB/1024))MB minimum. Skipping packages."
    return
  fi
  echo "Space available: ${avail_kb}KB"
  echo "Updating opkg feeds..."
  opkg update 2>/dev/null || true

  # Ordered essentials. Each line: "<bin> <candidate pkgs...>" — first candidate
  # that exists in the feed wins. git before vim/etc because chezmoi init + the
  # zsh plugin clones need it. nc is usually busybox-provided (skipped as present).
  local -a ORDER=(
    "zsh   zsh"
    "git   git-http git"
    "vim   vim-tiny vim vim-full"
    "bash  bash"
    "curl  curl"
    "nc    netcat"
    "htop  htop"
  )

  local -a SKIPPED=()
  local stopped=0 line bin cands pkg
  for line in "${ORDER[@]}"; do
    read -r bin cands <<<"$line"
    if command -v "$bin" &>/dev/null; then
      echo "  ✓ $bin already present"
      continue
    fi
    if [[ $stopped -eq 1 ]]; then SKIPPED+=("$bin"); continue; fi

    avail_kb="$(_opkg_free_kb)"
    if [[ -n "$avail_kb" && "$avail_kb" -lt "$FLOOR_KB" ]]; then
      echo "  ⚠ ${avail_kb}KB free < ${FLOOR_KB}KB floor — STOPPING; skipping rest"
      stopped=1; SKIPPED+=("$bin"); continue
    fi

    local installed=0
    for pkg in $cands; do
      if _opkg_pkg_exists "$pkg"; then
        echo "  → $pkg (${avail_kb}KB free)"
        if opkg install "$pkg" 2>&1; then installed=1; break; else echo "    ⚠ $pkg failed"; fi
      fi
    done
    [[ $installed -eq 0 ]] && { echo "  ⚠ no installable pkg for '$bin' (tried: $cands) — skipped"; SKIPPED+=("$bin"); }
  done

  [[ ${#SKIPPED[@]} -gt 0 ]] && echo "⚠ opkg skipped: ${SKIPPED[*]}"
  echo "✓ opkg packages done"
}

install_packages() {
  if [[ "$PKG_MGR" == "opkg" ]]; then
    install_packages_opkg
    return
  fi

  # Linux packages handled by chezmoi run_once script
  [[ "$OS" != "darwin" ]] && return

  if ! command -v brew &>/dev/null; then
    echo "⚠ No Homebrew found, skipping packages"
    return
  fi

  local -a PKGS=(
    vim git zsh curl wget rsync unzip zip
    htop btop tree jq ripgrep fzf tmux sesh lsof
    eza apfel dust iproute2mac bat lnav dua-cli
  )

  local -a MISSING=()
  for pkg in "${PKGS[@]}"; do
    local bin="$pkg"
    case "$pkg" in
      ripgrep) bin="rg" ;;
    esac
    if ! command -v "$bin" &>/dev/null && ! command -v "$pkg" &>/dev/null; then
      MISSING+=("$pkg")
    fi
  done

  if [[ ${#MISSING[@]} -eq 0 ]]; then
    echo "✓ All essential packages already installed"
  else
    echo "Installing ${#MISSING[@]} packages: ${MISSING[*]}"
    brew install "${MISSING[@]}"
    echo "✓ Packages installed"
  fi

  # diff-so-fancy: standalone perl script
  if ! command -v diff-so-fancy &>/dev/null; then
    echo "Installing diff-so-fancy..."
    mkdir -p "$HOME/.local/bin"
    _curl -sL https://raw.githubusercontent.com/so-fancy/diff-so-fancy/master/third_party/build_fatpack/diff-so-fancy \
      -o "$HOME/.local/bin/diff-so-fancy" && chmod +x "$HOME/.local/bin/diff-so-fancy"
    echo "✓ diff-so-fancy installed"
  fi
}

install_nerd_font() {
  if [[ $IS_TINY -eq 1 ]]; then
    echo "✓ skipping nerd font on ${ARCH} (headless/embedded)"
    return
  fi
  local FONT_NAME="JetBrainsMono"
  local FONT_URL="https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.tar.xz"
  local FONT_DIR

  case "$OS" in
    darwin) FONT_DIR="$HOME/Library/Fonts" ;;
    linux)  FONT_DIR="$HOME/.local/share/fonts" ;;
  esac

  # Check if already installed
  if ls "$FONT_DIR"/*JetBrains*Nerd* &>/dev/null; then
    echo "✓ JetBrains Mono Nerd Font already installed"
    return
  fi

  echo "Installing JetBrains Mono Nerd Font..."
  mkdir -p "$FONT_DIR"
  local tmp
  tmp="$(mktemp -d)"
  _curl -sL "$FONT_URL" -o "$tmp/font.tar.xz"
  tar -xf "$tmp/font.tar.xz" -C "$tmp"
  # Only copy the regular/bold/italic .ttf files, skip Windows-compat ones
  find "$tmp" -name "*.ttf" ! -name "*Windows*" -exec cp {} "$FONT_DIR/" \;
  rm -rf "$tmp"

  # Rebuild font cache on Linux
  if [[ "$OS" == "linux" ]] && command -v fc-cache &>/dev/null; then
    fc-cache -f "$FONT_DIR"
  fi

  echo "✓ JetBrains Mono Nerd Font installed to $FONT_DIR"
}

# ──────────────────────────────────────────────
# bash → zsh drop-in (embedded, no chsh)
# ──────────────────────────────────────────────
# NOT an alias (aliases only touch the interactive shell and don't help login).
# Appends a guarded `exec zsh -l` to ~/.bashrc + ~/.profile: fires only for an
# interactive terminal, only if not already in zsh, only if zsh exists. Scripts
# with #!/bin/bash are unaffected (they aren't interactive). Idempotent marker.
install_bash_shim() {
  command -v zsh &>/dev/null || { echo "⚠ zsh not found — skipping bash→zsh shim"; return 0; }
  local zsh_path; zsh_path="$(command -v zsh)"
  local marker="# >>> dotfiles bash->zsh >>>"
  local rc
  for rc in "$HOME/.bashrc" "$HOME/.profile"; do
    [[ -e "$rc" ]] || touch "$rc" 2>/dev/null || continue
    grep -qF "$marker" "$rc" 2>/dev/null && { echo "✓ bash→zsh shim already in $rc"; continue; }
    cat >> "$rc" <<EOF

$marker
# Drop into zsh for interactive shells (embedded boxes where chsh is unavailable).
if [ -t 1 ] && [ -z "\$ZSH_VERSION" ] && [ -x "$zsh_path" ]; then
  exec "$zsh_path" -l
fi
# <<< dotfiles bash->zsh <<<
EOF
    echo "✓ bash→zsh shim added to $rc"
  done
}

# ──────────────────────────────────────────────
# Low-power post-apply cleanup — reclaim space
# ──────────────────────────────────────────────
# On embedded/low-power, chezmoi is bootstrap-only. After apply we drop the
# chezmoi binary and strip .git metadata from the source repo + plugin clones
# (the working files stay; only the reflog/objects go). Re-run the bootstrap to
# update later.
cleanup_lowpower() {
  [[ $LOWPOWER -eq 1 ]] || return 0
  echo "Low-power cleanup — reclaiming space..."
  local src d
  src="$(chezmoi source-path 2>/dev/null || echo "$HOME/.local/share/chezmoi")"
  for d in "$src/.git" "$HOME"/.zsh/*/.git "$HOME/.zi"; do
    [[ -e "$d" ]] || continue
    rm -rf "$d" 2>/dev/null && echo "  removed $d"
  done
  local cm; cm="$(command -v chezmoi 2>/dev/null || true)"
  if [[ -n "$cm" && -f "$cm" ]]; then
    rm -f "$cm" 2>/dev/null && echo "  removed chezmoi binary ($cm)"
  fi
  echo "✓ cleanup done"
}

# ──────────────────────────────────────────────
# Harden ~/.vimrc against vim-tiny
# ──────────────────────────────────────────────
# vim-tiny (apk/opkg minimal builds) lacks +syntax, so a bare `syntax on` throws
# E319 on every startup. The bare vimrc template already emits `silent! syntax
# on`, but this catches the mismatch case (e.g. profile guessed wrong, or the
# only vim available is tiny). Actually loads the applied ~/.vimrc, and if vim
# emits an E### error, neutralizes `syntax on/enable` by prefixing `silent!`.
harden_vimrc() {
  local vrc="$HOME/.vimrc"
  command -v vim &>/dev/null || return 0
  [[ -f "$vrc" ]] || return 0
  local err
  err="$(vim -es -c 'qa!' </dev/null 2>&1)"
  echo "$err" | grep -qE 'E[0-9]+:' || { echo "✓ ~/.vimrc loads clean"; return 0; }
  echo "⚠ vim errors loading ~/.vimrc — neutralizing bare 'syntax on':"
  echo "$err" | grep -E 'E[0-9]+:' | head -3 | sed 's/^/    /'
  if sed -i -r 's/^([[:space:]]*)(syntax[[:space:]]+(on|enable))([[:space:]]*)$/\1silent! \2/' "$vrc" 2>/dev/null; then
    echo "✓ patched ~/.vimrc (syntax → silent! syntax)"
  else
    echo "⚠ could not patch ~/.vimrc automatically"
  fi
}

install_chezmoi
# Bare/low-power sources zsh-autosuggestions + zsh-syntax-highlighting directly
# (see dot_zshrc.zi.zsh.tmpl) — the zi manager is skipped to save space.
if [[ $LOWPOWER -eq 1 ]]; then
  echo "✓ skipping zi manager (low-power — plugins sourced directly)"
else
  install_zi
fi
install_vim_plug
install_packages
install_nerd_font
echo

# ──────────────────────────────────────────────
# 3. Interactive Wizard
# ──────────────────────────────────────────────

# Single-select: tiny / lite / full
select_profile() {
  local options=("bare" "lite" "full")
  local descriptions=("Embedded — core plugins, no tmux, no extras" "Lightweight — core plugins, fzf, no tmux" "Everything — CoC, fnm, pyenv, tmux, the works")
  local selected=2  # default: full (lowpower systems never reach here)

  # No terminal → can't prompt; take the default silently.
  if ! _have_tty; then
    PROFILE="${options[$selected]}"
    echo "${DIM}(no tty — profile defaulting to ${PROFILE})${RESET}"
    return
  fi

  echo "${BOLD}Select profile:${RESET}"
  echo "${DIM}(↑/↓ to move, Enter to select)${RESET}"
  echo

  # hide cursor
  _tput civis

  while true; do
    # move cursor up to redraw
    for ((i = 0; i < ${#options[@]}; i++)); do
      if [[ $i -eq $selected ]]; then
        echo -e "\r  ${GREEN}▸ ${options[$i]}${RESET}  ${DIM}${descriptions[$i]}${RESET}   "
      else
        echo -e "\r    ${options[$i]}  ${DIM}${descriptions[$i]}${RESET}   "
      fi
    done

    # read single keypress (from the terminal, NOT the curl pipe on stdin)
    IFS= read -rsn1 key </dev/tty
    case "$key" in
      A|k) ((selected > 0)) && ((selected--)) ;;  # up
      B|j) ((selected < ${#options[@]} - 1)) && ((selected++)) ;;  # down
      "")  break ;;  # enter
    esac

    # move cursor back up
    printf "\033[%dA" "${#options[@]}"
  done

  _tput cnorm  # show cursor
  echo
  PROFILE="${options[$selected]}"
}

# Multi-select: spacebar checklist
select_modules() {
  local -a names=("nvm" "pyenv" "bun" "php" "copilot" "tmux" "fzf" "vscode")
  local -a descs=("fnm (Fast Node Manager)" "Python version manager" "Bun JS runtime" "PHP aliases (phpd, etc.)" "GitHub Copilot CLI" "Tmux + powerline" "Fuzzy finder keybindings" "VSCode terminal integration")
  local -a checked

  # defaults based on profile
  case "$PROFILE" in
    full) checked=(1 1 1 1 1 1 1 1) ;;          # everything
    lite) checked=(1 0 0 0 0 0 1 1) ;;          # nvm + fzf + vscode
    bare) checked=(0 0 0 0 0 0 0 0) ;;          # nothing
  esac

  local cursor=0

  # No terminal, or bare profile (no modules apply) → take defaults silently.
  if ! _have_tty || [[ "$PROFILE" == "bare" ]]; then
    for ((i = 0; i < ${#names[@]}; i++)); do
      eval "MODULE_${names[$i]}=${checked[$i]}"
    done
    return
  fi

  echo "${BOLD}Select modules:${RESET}"
  echo "${DIM}(↑/↓ move, Space toggle, Enter confirm)${RESET}"
  echo

  _tput civis

  while true; do
    for ((i = 0; i < ${#names[@]}; i++)); do
      local mark=" "
      [[ ${checked[$i]} -eq 1 ]] && mark="${GREEN}✔${RESET}"

      if [[ $i -eq $cursor ]]; then
        echo -e "\r  ${CYAN}▸${RESET} [${mark}] ${names[$i]}  ${DIM}${descs[$i]}${RESET}   "
      else
        echo -e "\r    [${mark}] ${names[$i]}  ${DIM}${descs[$i]}${RESET}   "
      fi
    done

    IFS= read -rsn1 key </dev/tty
    case "$key" in
      A|k) ((cursor > 0)) && ((cursor--)) ;;
      B|j) ((cursor < ${#names[@]} - 1)) && ((cursor++)) ;;
      " ") # toggle
        if [[ ${checked[$cursor]} -eq 1 ]]; then
          checked[$cursor]=0
        else
          checked[$cursor]=1
        fi
        ;;
      "") break ;;  # enter
    esac

    printf "\033[%dA" "${#names[@]}"
  done

  _tput cnorm
  echo

  # export results
  for ((i = 0; i < ${#names[@]}; i++)); do
    eval "MODULE_${names[$i]}=${checked[$i]}"
  done
}

if [[ $LOWPOWER -eq 1 ]]; then
  # Low-power hard-override: no menu — bare, all modules off.
  PROFILE="bare"
  echo "${BOLD}Profile:${RESET} bare ${DIM}(forced — low-power: $LOWPOWER_WHY)${RESET}"
  for mod in nvm pyenv bun php copilot tmux fzf vscode; do eval "MODULE_${mod}=0"; done
else
  select_profile
  select_modules
fi

echo
echo "${BOLD}Profile:${RESET} $PROFILE"
echo "${BOLD}Modules:${RESET}"
for mod in nvm pyenv bun php copilot tmux fzf vscode; do
  val="MODULE_${mod}"
  [[ ${!val} -eq 1 ]] && echo "  ${GREEN}✔${RESET} $mod" || echo "  ${DIM}✗ $mod${RESET}"
done
echo

# ──────────────────────────────────────────────
# 4. Write .chezmoidata.yaml
# ──────────────────────────────────────────────
write_chezmoidata() {
  local src_dir
  src_dir="$(chezmoi source-path 2>/dev/null || echo "$HOME/.local/share/chezmoi")"
  DATA_FILE="$src_dir/.chezmoidata.yaml"

  mkdir -p "$src_dir"

  cat > "$DATA_FILE" << YAML
profile: $PROFILE
modules:
  nvm: $(bool $MODULE_nvm)
  pyenv: $(bool $MODULE_pyenv)
  bun: $(bool $MODULE_bun)
  php: $(bool $MODULE_php)
  copilot: $(bool $MODULE_copilot)
  tmux: $(bool $MODULE_tmux)
  fzf: $(bool $MODULE_fzf)
  vscode: $(bool $MODULE_vscode)
YAML

  echo "✓ Wrote $DATA_FILE"
}

bool() { [[ $1 -eq 1 ]] && echo "true" || echo "false"; }

# ──────────────────────────────────────────────
# 5. Init & Apply
# ──────────────────────────────────────────────
write_chezmoidata

# chezmoi init clones the repo via git. On fresh Alpine (apk) git isn't installed
# until `chezmoi apply` runs the linux-packages script — too late for init. Make
# sure git exists first. (opkg already installs git in install_packages_opkg.)
_ensure_git() {
  command -v git &>/dev/null && return 0
  echo "git missing — installing before chezmoi init..."
  case "$PKG_MGR" in
    apk)  $SUDO apk add --no-cache git 2>/dev/null || true ;;
    apt)  $SUDO apt-get update -qq 2>/dev/null || true; $SUDO apt-get install -y -qq --no-install-recommends git 2>/dev/null || true ;;
    opkg) opkg update 2>/dev/null || true; opkg install git-http 2>/dev/null || opkg install git 2>/dev/null || true ;;
  esac
  command -v git &>/dev/null && echo "✓ git installed" || echo "⚠ git still missing — chezmoi init may fail"
}
_ensure_git

echo
echo "Initializing chezmoi..."
if [[ -d "$(chezmoi source-path 2>/dev/null)/.git" ]]; then
  echo "✓ chezmoi already initialized"
else
  chezmoi init "$CHEZMOI_REPO"
fi

# Re-write data file after init (init may have cloned fresh)
write_chezmoidata

echo "Applying dotfiles..."
chezmoi apply -v

# ──────────────────────────────────────────────
# 6. Vim plugins
# ──────────────────────────────────────────────
if command -v vim &>/dev/null && [[ $IS_TINY -eq 0 ]]; then
  echo "Installing vim plugins..."
  vim +PlugInstall +qall
  echo "✓ Vim plugins installed"
fi

# ──────────────────────────────────────────────
# 7. Low-power finalize — bash→zsh shim + reclaim space
# ──────────────────────────────────────────────
# Runs AFTER apply so zsh (installed by the chezmoi run_once linux-packages
# script) is present for the shim.
if [[ $LOWPOWER -eq 1 ]]; then
  harden_vimrc
  install_bash_shim
  cleanup_lowpower
fi

echo
echo "${GREEN}${BOLD}Done!${RESET} Log out and back in, or: exec zsh"
