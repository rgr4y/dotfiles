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
LOW_DISK_MB="${LOW_DISK_MB:-50}"
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

HAS_ZSH=0
if command -v zsh &>/dev/null; then
  HAS_ZSH=1
fi

PKG_MGR=""
if command -v brew &>/dev/null; then
  PKG_MGR="brew"
elif command -v apt-get &>/dev/null; then
  PKG_MGR="apt"
elif command -v opkg &>/dev/null; then
  PKG_MGR="opkg"
fi

# Detect tiny/embedded systems: opkg or 32-bit ARM (armv6l, armv7l, armhf, etc.)
IS_TINY=0
ARCH="$(uname -m)"
case "$ARCH" in
  armv[67]*|armhf) IS_TINY=1 ;;
esac
[[ "$PKG_MGR" == "opkg" ]] && IS_TINY=1

echo "┌─────────────────────────────────────┐"
echo "│  Dotfiles Bootstrap                 │"
echo "│  OS: $OS  sudo: $HAS_SUDO  zsh: $HAS_ZSH       │"
echo "│  pkg: ${PKG_MGR:-none}                          │"
echo "└─────────────────────────────────────┘"
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
    IFS= read -rsn1 key
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
  CHEZMOI_BIN_DIR="$(_select_chezmoi_dir)"

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
  # Minimal packages for embedded/OpenWrt systems
  # Check available space first — need at least 2MB free on root overlay
  local avail_kb
  avail_kb=$(df /overlay 2>/dev/null | awk 'NR==2{print $4}' || df / | awk 'NR==2{print $4}')
  if [[ -n "$avail_kb" && "$avail_kb" -lt 2048 ]]; then
    echo "⚠ Only ${avail_kb}KB free — need 2MB minimum for packages. Skipping."
    return
  fi
  echo "Space available: ${avail_kb}KB"

  # Bare essentials only — these are tiny systems
  local -a PKGS=(vim-full git-http zsh curl wget rsync htop)

  local -a MISSING=()
  for pkg in "${PKGS[@]}"; do
    local bin="$pkg"
    case "$pkg" in
      vim-full) bin="vim" ;;
      git-http) bin="git" ;;
    esac
    if ! command -v "$bin" &>/dev/null; then
      MISSING+=("$pkg")
    fi
  done

  if [[ ${#MISSING[@]} -eq 0 ]]; then
    echo "✓ All essential packages already installed"
    return
  fi

  echo "Updating opkg feeds..."
  opkg update 2>/dev/null || true

  echo "Installing ${#MISSING[@]} packages: ${MISSING[*]}"
  for pkg in "${MISSING[@]}"; do
    echo "  → $pkg"
    opkg install "$pkg" 2>&1 || echo "  ⚠ Failed to install $pkg (may need more space)"
  done
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

install_chezmoi
install_zi
install_vim_plug
install_packages
install_nerd_font
echo

# ──────────────────────────────────────────────
# 3. Interactive Wizard
# ──────────────────────────────────────────────

# Single-select: tiny / lite / full
select_profile() {
  local options=("tiny" "lite" "full")
  local descriptions=("Embedded — core plugins, no tmux, no extras" "Lightweight — core plugins, fzf, no tmux" "Everything — CoC, fnm, pyenv, tmux, the works")
  local selected=0

  # Pre-select based on detected environment
  if [[ $IS_TINY -eq 1 ]]; then
    selected=0
  else
    selected=2
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

    # read single keypress
    IFS= read -rsn1 key
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
    tiny) checked=(0 0 0 0 0 0 0 0) ;;          # nothing
  esac

  local cursor=0

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

    IFS= read -rsn1 key
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

select_profile
select_modules

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

echo
echo "${GREEN}${BOLD}Done!${RESET} Log out and back in, or: exec zsh"
