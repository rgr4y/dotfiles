#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────
# Dotfiles Bootstrap — install.sh
# curl -sL lolf.art/ing.sh | bash
# ──────────────────────────────────────────────

CHEZMOI_REPO="https://github.com/rgr4y/dotfiles.git"
CHEZMOI_BIN="$HOME/.local/bin/chezmoi"
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
    ver="$(curl -fsL https://api.github.com/repos/twpayne/chezmoi/releases/latest 2>/dev/null \
           | grep -o '"tag_name": *"[^"]*"' | head -1 | grep -o 'v[0-9][0-9.]*')"
    if [[ -z "$ver" ]]; then
      echo "⚠ Can't fetch latest chezmoi version, trying get.chezmoi.io..."
      sh -c "$(curl -fsLS get.chezmoi.io)" -- -b "$dest"
      return
    fi

    local url="https://github.com/twpayne/chezmoi/releases/download/${ver}/chezmoi-linux-${arch}"
    echo "  Downloading chezmoi ${ver} for linux/${arch}..."
    if curl -fsL "$url" -o "${dest}/chezmoi" && chmod +x "${dest}/chezmoi"; then
      return 0
    fi

    # Binary not available — try .tar.gz
    url="https://github.com/twpayne/chezmoi/releases/download/${ver}/chezmoi_${ver#v}_linux_${arch}.tar.gz"
    echo "  Trying tarball: ${url}..."
    local tmp
    tmp="$(mktemp -d)"
    if curl -fsL "$url" -o "$tmp/chezmoi.tar.gz" && tar -xzf "$tmp/chezmoi.tar.gz" -C "$tmp" chezmoi 2>/dev/null; then
      mv "$tmp/chezmoi" "${dest}/chezmoi" && chmod +x "${dest}/chezmoi"
      rm -rf "$tmp"
      return 0
    fi
    rm -rf "$tmp"
    echo "⚠ Direct download failed, falling back to get.chezmoi.io..."
  fi

  sh -c "$(curl -fsLS get.chezmoi.io)" -- -b "$dest"
}

install_chezmoi() {
  mkdir -p "$HOME/.local/bin"
  export PATH="$HOME/.local/bin:$PATH"

  if ! command -v chezmoi &>/dev/null; then
    echo "Installing chezmoi..."
    _chezmoi_download "$HOME/.local/bin"
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
  _lat="$(curl -fsL https://api.github.com/repos/twpayne/chezmoi/releases/latest 2>/dev/null \
          | grep -o '"tag_name": *"[^"]*"' | head -1 | grep -o 'v[0-9][0-9.]*')"
  if [[ -n "$_lat" && "$_cur" != "$_lat" ]]; then
    echo "chezmoi ${_cur} → ${_lat} — upgrading..."
    _chezmoi_download "$HOME/.local/bin"
    echo "✓ chezmoi upgraded"
  else
    echo "✓ chezmoi ${_cur:-unknown} is latest"
  fi
}

install_zi() {
  if [[ $IS_TINY -eq 1 ]]; then
    echo "✓ skipping zi on ${ARCH} (tiny/embedded)"
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
  curl -fLo "$PLUG_VIM" --create-dirs \
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
    curl -sL https://raw.githubusercontent.com/so-fancy/diff-so-fancy/master/third_party/build_fatpack/diff-so-fancy \
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
  curl -sL "$FONT_URL" -o "$tmp/font.tar.xz"
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

# Terminal UI helpers
_tput() { tput "$@" 2>/dev/null || true; }
BOLD=$(_tput bold)
DIM=$(_tput dim)
RESET=$(_tput sgr0)
GREEN=$(_tput setaf 2)
CYAN=$(_tput setaf 6)
YELLOW=$(_tput setaf 3)

# Single-select: bare or full
select_profile() {
  local options=("bare" "full")
  local descriptions=("Minimal — syntax highlighting, basic vim, no extras" "Everything — CoC, fnm, pyenv, tmux, the works")
  local selected=0

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
  if [[ "$PROFILE" == "full" ]]; then
    checked=(1 1 1 1 1 1 1 1)
  else
    checked=(0 0 0 0 0 0 0 0)
  fi

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
