#!/usr/bin/env bash
set -euo pipefail

DEFAULT_GITHUB_USERNAME=rgr4y

# ── Parse flags ──────────────────────────────────────────────────────────────
AUTO=0
PROFILE=""
GITHUB_USERNAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --auto) AUTO=1; shift ;;
    --lite) PROFILE="bare"; shift ;;
    --full) PROFILE="full"; shift ;;
    --user) [[ $# -lt 2 ]] && { echo "[ing] --user requires an argument"; exit 1; }
            GITHUB_USERNAME="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: ing.sh [--auto] [--lite|--full] [--user NAME]"
      echo "  --auto   Non-interactive (no prompts, uses defaults)"
      echo "  --lite   Minimal profile (fewer plugins/extras)"
      echo "  --full   Full profile (default in interactive mode)"
      echo "  --user   GitHub username (default: ${DEFAULT_GITHUB_USERNAME})"
      exit 0 ;;
    *) echo "[ing] unknown flag: $1"; exit 1 ;;
  esac
done

# ── Detect system capabilities (once, up front) ─────────────────────────────
CAN_INSTALL=0
SUDO=""

if [[ "$(id -u)" -eq 0 ]]; then
  CAN_INSTALL=1
elif command -v sudo &>/dev/null && sudo -n true 2>/dev/null; then
  CAN_INSTALL=1
  SUDO="sudo"
fi

PM=""
INSTALL=""
_APT_UPDATED=0

if command -v apt-get &>/dev/null; then
  PM="apt"
  INSTALL="$SUDO apt-get install -y"
elif command -v yum &>/dev/null; then
  PM="yum"
  INSTALL="$SUDO yum install -y"
elif command -v pacman &>/dev/null; then
  PM="pacman"
  INSTALL="$SUDO pacman -S --noconfirm"
elif command -v brew &>/dev/null; then
  PM="brew"
  INSTALL="brew install"
  CAN_INSTALL=1
fi

_try_install() {
  [[ "$CAN_INSTALL" -eq 0 || -z "$PM" ]] && return 1
  echo "[ing] installing $1..."
  if [[ "$PM" == "apt" && "$_APT_UPDATED" -eq 0 ]]; then
    $SUDO apt-get update -qq
    _APT_UPDATED=1
  fi
  $INSTALL "$1"
}

echo "[ing] system: pm=${PM:-none} sudo=${CAN_INSTALL}"

# ── Prompts (skipped in --auto) ──────────────────────────────────────────────
if [[ "$AUTO" -eq 1 ]]; then
  GITHUB_USERNAME="${GITHUB_USERNAME:-$DEFAULT_GITHUB_USERNAME}"
  PROFILE="${PROFILE:-full}"
else
  if [[ -z "$GITHUB_USERNAME" ]]; then
    if [ -t 0 ] && [ -r /dev/tty ]; then
      printf "[ing] GitHub username (default: %s): " "$DEFAULT_GITHUB_USERNAME" > /dev/tty
      read -r -t 10 GITHUB_USERNAME < /dev/tty || printf '\n[ing] timed out — using default\n' > /dev/tty
    fi
    GITHUB_USERNAME="${GITHUB_USERNAME:-$DEFAULT_GITHUB_USERNAME}"
  fi

  if [[ -z "$PROFILE" ]]; then
    _choice=""
    if [ -t 0 ] && [ -r /dev/tty ]; then
      {
        echo "[ing] Choose your setup:"
        echo "  1) Full (Recommended) — everything enabled"
        echo "  2) Lite — minimal plugins and extras"
        printf "[ing] Enter 1 or 2 (default: full in 10s): "
      } > /dev/tty
      read -r -t 10 _choice < /dev/tty || printf '\n[ing] timed out — defaulting to full\n' > /dev/tty
    fi
    case "${_choice:-1}" in
      1|full|FULL|Full) PROFILE="full" ;;
      2|lite|LITE|Lite|bare|BARE|Bare) PROFILE="bare" ;;
      *) PROFILE="full" ;;
    esac
  fi
fi

echo "[ing] GitHub → ${GITHUB_USERNAME}"
echo "[ing] Profile → ${PROFILE}"

# ── Gate: git (hard requirement) ─────────────────────────────────────────────
if ! command -v git &>/dev/null; then
  echo "[ing] git not found — attempting install..."
  if ! _try_install git; then
    echo "[ing] FATAL: can't install git (no package manager or no sudo)"
    echo "[ing] install git manually and re-run"
    exit 1
  fi
fi
echo "[ing] git ✓"

# ── chezmoi ──────────────────────────────────────────────────────────────────
export PATH="$HOME/.local/bin:$PATH"

_install_chezmoi() {
  mkdir -p "$HOME/.local/bin"
  sh -c "$(curl -fsLS get.chezmoi.io)" -- -b "$HOME/.local/bin"
}

if ! command -v chezmoi &>/dev/null; then
  echo "[ing] chezmoi not found — installing..."
  _install_chezmoi
else
  _chezmoi_bin="$(command -v chezmoi)"
  if find "$_chezmoi_bin" -mtime +30 -print -quit 2>/dev/null | grep -q .; then
    echo "[ing] chezmoi older than 30 days — upgrading..."
    _install_chezmoi
  else
    echo "[ing] chezmoi up to date ($(chezmoi --version 2>&1 | head -1))"
  fi
fi
echo "[ing] chezmoi ✓"

# ── Gate: zsh (install early so we can exec into it) ────────────────────────
HAS_ZSH=0

if command -v zsh &>/dev/null; then
  HAS_ZSH=1
else
  echo "[ing] zsh not found — attempting install..."
  if _try_install zsh && command -v zsh &>/dev/null; then
    HAS_ZSH=1
  else
    echo "[ing] WARNING: can't install zsh — shell customization skipped"
  fi
fi

if [[ "$HAS_ZSH" -eq 1 ]]; then
  echo "[ing] zsh ✓"
  ZSH_PATH="$(command -v zsh)"
  if [ "$SHELL" != "$ZSH_PATH" ]; then
    if [[ "$CAN_INSTALL" -eq 1 ]]; then
      $SUDO chsh -s "$ZSH_PATH" "$(whoami)" || true
      echo "[ing] default shell → zsh"
    else
      echo "[ing] no sudo — run manually: chsh -s $ZSH_PATH"
    fi
  fi
fi

# ── chezmoi apply (dotfiles only — skip heavy package scripts) ──────────────
CHEZMOI_DATA="$HOME/.config/chezmoi/chezmoi.yaml"
mkdir -p "$(dirname "$CHEZMOI_DATA")"
cat > "$CHEZMOI_DATA" <<EOF
data:
  profile: ${PROFILE}
EOF

_DOTFILES_CHANGED=0
if [[ -d "$HOME/.local/share/chezmoi/.git" ]]; then
  _cm_out="$(chezmoi update --exclude=scripts 2>&1)" || true
  [[ -n "$_cm_out" ]] && _DOTFILES_CHANGED=1
else
  chezmoi init "$GITHUB_USERNAME"
  chezmoi apply --exclude=scripts
  _DOTFILES_CHANGED=1
fi
echo "[ing] dotfiles deployed ✓"

_preinstall_zi_plugins() {
  [[ "$HAS_ZSH" -eq 1 ]] || return 0
  [[ -f "$HOME/.zshrc.zi.zsh" ]] || return 0

  local log="$HOME/.zi-preinstall.log"
  local lock="$HOME/.zi-preinstall.lock"

  (
    if ! mkdir "$lock" 2>/dev/null; then
      exit 0
    fi
    trap 'rmdir "$lock"' EXIT

    export GIT_TERMINAL_PROMPT=0
    zsh -f "$HOME/.zshrc.zi.zsh"
  ) >"$log" 2>&1 &
  disown "$!" 2>/dev/null || true
}

_preinstall_zi_plugins

# ── Cleanup + banner ────────────────────────────────────────────────────────
printf '\n'
cat <<'FART'
[0;1;35;95moo[0;1;31;91moo[0m            [0;1;33;93moo[0;1;32;92moo[0m   [0;1;34;94m.[0;1;35;95mo8[0;1;31;91m8o[0;1;33;93m.[0m                            [0;1;36;96m.[0m   
[0;1;31;91m`8[0;1;33;93m88[0m            [0;1;32;92m`8[0;1;36;96m88[0m   [0;1;35;95m8[0;1;31;91m88[0m [0;1;33;93m`[0;1;32;92m"[0m                          [0;1;36;96m.[0;1;34;94mo8[0m   
 [0;1;33;93m8[0;1;32;92m88[0m   [0;1;34;94m.[0;1;35;95moo[0;1;31;91moo[0;1;33;93mo.[0m   [0;1;36;96m8[0;1;34;94m88[0m  [0;1;31;91mo8[0;1;33;93m88[0;1;32;92moo[0m       [0;1;31;91m.[0;1;33;93moo[0;1;32;92moo[0;1;36;96m.[0m   [0;1;35;95moo[0;1;31;91moo[0m [0;1;33;93md[0;1;32;92m8b[0m [0;1;36;96m.[0;1;34;94mo8[0;1;35;95m88[0;1;31;91moo[0m 
 [0;1;32;92m8[0;1;36;96m88[0m  [0;1;35;95md8[0;1;31;91m8'[0m [0;1;33;93m`[0;1;32;92m88[0;1;36;96mb[0m  [0;1;34;94m8[0;1;35;95m88[0m   [0;1;33;93m8[0;1;32;92m88[0m        [0;1;33;93m`P[0m  [0;1;36;96m)8[0;1;34;94m8b[0m  [0;1;31;91m`8[0;1;33;93m88[0;1;32;92m""[0;1;36;96m8P[0m   [0;1;35;95m8[0;1;31;91m88[0m   
 [0;1;36;96m8[0;1;34;94m88[0m  [0;1;31;91m88[0;1;33;93m8[0m   [0;1;36;96m88[0;1;34;94m8[0m  [0;1;35;95m8[0;1;31;91m88[0m   [0;1;32;92m8[0;1;36;96m88[0m         [0;1;32;92m.[0;1;36;96moP[0;1;34;94m"8[0;1;35;95m88[0m   [0;1;33;93m8[0;1;32;92m88[0m       [0;1;31;91m8[0;1;33;93m88[0m   
 [0;1;34;94m8[0;1;35;95m88[0m  [0;1;33;93m88[0;1;32;92m8[0m   [0;1;34;94m88[0;1;35;95m8[0m  [0;1;31;91m8[0;1;33;93m88[0m   [0;1;36;96m8[0;1;34;94m88[0m    [0;1;33;93m.o[0;1;32;92m.[0m [0;1;36;96md8[0;1;34;94m([0m  [0;1;35;95m8[0;1;31;91m88[0m   [0;1;32;92m8[0;1;36;96m88[0m       [0;1;33;93m8[0;1;32;92m88[0m [0;1;36;96m.[0m 
[0;1;35;95mo8[0;1;31;91m88[0;1;33;93mo[0m [0;1;32;92m`Y[0;1;36;96m8b[0;1;34;94mod[0;1;35;95m8P[0;1;31;91m'[0m [0;1;33;93mo8[0;1;32;92m88[0;1;36;96mo[0m [0;1;34;94mo8[0;1;35;95m88[0;1;31;91mo[0m   [0;1;32;92mY8[0;1;36;96mP[0m [0;1;34;94m`Y[0;1;35;95m88[0;1;31;91m8"[0;1;33;93m"8[0;1;32;92mo[0m [0;1;36;96md8[0;1;34;94m88[0;1;35;95mb[0m      [0;1;32;92m"[0;1;36;96m88[0;1;34;94m8"[0m 
FART

printf '\n'

rm -f "$HOME/.ing-bootstrap.done"
rm -f "$HOME/.zlogin"

# ── Package scripts (async if interactive, sync otherwise) ──────────────────
_run_scripts() {
  DEBIAN_FRONTEND=noninteractive chezmoi apply
}

if [[ -t 0 ]]; then
  echo "[ing] installing packages in background (log: ~/.ing-install.log)..."
  _run_scripts &>"$HOME/.ing-install.log" &
  disown
else
  echo "[ing] installing packages..."
  _run_scripts
fi

# ── Launch shell ────────────────────────────────────────────────────────────
_parent_comm="$(ps -p "$PPID" -o comm= 2>/dev/null || true)"
_zsh_already_active=0
[[ "$_parent_comm" == *zsh* ]] && _zsh_already_active=1

if [[ -n "${SSH_TTY:-}" && -z "${TMUX:-}" && "$_zsh_already_active" -eq 0 ]]; then
  echo "[ing] bootstrap complete; disconnecting so you can reconnect..."
  sleep 1
  kill -HUP "$PPID"
  exit 0
fi

if [[ "$HAS_ZSH" -eq 1 && "${_DOTFILES_CHANGED:-0}" -eq 1 ]]; then
  if [[ "$_zsh_already_active" -eq 1 ]]; then
    echo "[ing] zsh already running — run 'source ~/.zshrc' to reload config"
  else
    echo "[ing] launching fresh zsh..."
    exec zsh -l
  fi
fi
