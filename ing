#!/bin/bash
#!/usr/bin/env bash

DEFAULT_GITHUB_USERNAME=rgr4y

choose_github_username() {
  local input=""
  if [ -t 0 ] && [ -r /dev/tty ]; then
    {
      printf "[ing] GitHub username (default: ${DEFAULT_GITHUB_USERNAME}): "
    } > /dev/tty
    read -r -t 10 input < /dev/tty || { printf '\n[ing] timed out — using default\n' > /dev/tty; }
  fi
  echo "${input:-$DEFAULT_GITHUB_USERNAME}"
}

choose_profile() {
  local choice=""
  if [ -t 0 ] && [ -r /dev/tty ]; then
    {
      echo "[ing] Choose your setup:"
      echo "  1) Full (Recommended) — everything enabled"
      echo "  2) Lite — minimal plugins and extras"
      printf "[ing] Enter 1 or 2 (default: full in 10s): "
    } > /dev/tty
    read -r -t 10 choice < /dev/tty || { printf '\n[ing] timed out — defaulting to full\n' > /dev/tty; }
  fi
  case "${choice:-1}" in
    1|full|FULL|Full) echo "full" ;;
    2|lite|LITE|Lite|bare|BARE|Bare) echo "bare" ;;
    *) echo "full" ;;
  esac
}

GITHUB_USERNAME="$(choose_github_username)"
echo "[ing] GitHub → ${GITHUB_USERNAME}"

PROFILE="$(choose_profile)"
echo "[ing] Profile → ${PROFILE}"

# Ensure git is available
if ! command -v git >/dev/null 2>&1; then
  echo "[ing] git not found — install git first and re-run"
  exit 1
fi

# Always make sure ~/.local/bin is in PATH (chezmoi installs there)
export PATH="$HOME/.local/bin:$PATH"

# Install chezmoi if missing, or upgrade if outdated (older than 30 days)
_install_chezmoi() {
  mkdir -p "$HOME/.local/bin"
  sh -c "$(curl -fsLS get.chezmoi.io)" -- -b "$HOME/.local/bin"
}

if ! command -v chezmoi >/dev/null 2>&1; then
  echo "[ing] chezmoi not found — installing..."
  _install_chezmoi
else
  _chezmoi_bin="$(command -v chezmoi)"
  _chezmoi_age=$(( $(date +%s) - $(date -r "$_chezmoi_bin" +%s 2>/dev/null || echo 0) ))
  if [ "$_chezmoi_age" -gt $((30 * 86400)) ]; then
    echo "[ing] chezmoi is older than 30 days — upgrading..."
    _install_chezmoi
  else
    echo "[ing] chezmoi up to date ($(chezmoi --version 2>&1 | head -1))"
  fi
fi

# Write profile into chezmoi data before apply so templates can use it
CHEZMOI_DATA="$HOME/.config/chezmoi/chezmoi.yaml"
mkdir -p "$(dirname "$CHEZMOI_DATA")"
cat > "$CHEZMOI_DATA" <<EOF
data:
  profile: ${PROFILE}
EOF

if [[ -d "$HOME/.local/share/chezmoi/.git" ]]; then
  chezmoi update
else
  chezmoi init --apply "$GITHUB_USERNAME"
fi

# set zsh as default shell if it isn't already
if command -v zsh >/dev/null 2>&1; then
  ZSH_PATH=$(which zsh)
  if [ "$SHELL" != "$ZSH_PATH" ]; then
    if sudo -n true 2>/dev/null; then
      sudo chsh -s "$ZSH_PATH" "$(whoami)" || true
      echo "[ing] default shell → zsh"
    else
      echo "[ing] can't sudo without password — run: chsh -s $ZSH_PATH"
    fi
  fi
fi

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

rm -f $HOME/.ing-bootstrap.done
rm -f $HOME/.zlogin

# force reconnect so next session starts from a clean login shell
if [[ -n "${SSH_TTY:-}" && -z "${TMUX:-}" ]]; then
  echo "[ing] bootstrap complete; disconnecting so you can reconnect..."
  sleep 1
  kill -HUP "$PPID"
  exit 0
fi
