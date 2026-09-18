#!/usr/bin/env bash
set -euo pipefail

# abc.sh — barebones bootstrap that runs PRE ing.sh.
# Just the stuff done on every fresh box: SSH keys + a sane $EDITOR.
# No package manager, no chezmoi, no shell swap. Fast and dependency-free.

DEFAULT_GITHUB_USERNAME=rgr4y

# ── Args ─────────────────────────────────────────────────────────────────────
GH_USER="${GH_USER:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) [[ $# -lt 2 ]] && { echo "[abc] --user requires an argument"; exit 1; }
            GH_USER="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: abc.sh [--user NAME]"
      echo "  --user   GitHub username for SSH keys (env GH_USER, default: ${DEFAULT_GITHUB_USERNAME})"
      exit 0 ;;
    *) echo "[abc] unknown flag: $1"; exit 1 ;;
  esac
done

GH_USER="${GH_USER:-$DEFAULT_GITHUB_USERNAME}"

# ── SSH authorized_keys from GitHub (idempotent) ─────────────────────────────
echo "[abc] pulling keys for github.com/${GH_USER}"
mkdir -p ~/.ssh && chmod 700 ~/.ssh
touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys

_keys="$(curl -fsSL "https://github.com/${GH_USER}.keys" || true)"
if [[ -z "$_keys" ]]; then
  echo "[abc] WARNING: no keys fetched (bad user or no network) — skipping"
else
  _added=0
  while IFS= read -r _k; do
    [[ -z "$_k" ]] && continue
    grep -qxF "$_k" ~/.ssh/authorized_keys || { printf '%s\n' "$_k" >> ~/.ssh/authorized_keys; _added=$((_added+1)); }
  done <<< "$_keys"
  echo "[abc] authorized_keys ✓ (${_added} new)"
fi

# ── $EDITOR + vim wrapper ────────────────────────────────────────────────────
# Pick the rc file for the login shell.
_shell="$(basename "${SHELL:-/bin/sh}")"
case "$_shell" in
  zsh)  RC="$HOME/.zshrc" ;;
  bash) RC="$HOME/.bashrc" ;;
  *)    RC="$HOME/.profile" ;;
esac
touch "$RC"

MARKER="# >>> abc.sh editor >>>"
if grep -qF "$MARKER" "$RC"; then
  echo "[abc] editor block already in ${RC} — skipping"
else
  {
    echo ""
    echo "$MARKER"
    echo "export EDITOR=vim"
    if ! command -v vim >/dev/null 2>&1; then
      # vim not installed now — wrapper falls through to vi until it is
      echo "vim() { if command -v vim >/dev/null 2>&1; then command vim \"\$@\"; else command vi \"\$@\"; fi; }"
    fi
    echo "# <<< abc.sh editor <<<"
  } >> "$RC"
  if command -v vim >/dev/null 2>&1; then
    echo "[abc] EDITOR=vim → ${RC} (vim on PATH ✓)"
  else
    echo "[abc] EDITOR=vim + vi-fallback wrapper → ${RC} (vim missing)"
  fi
fi

echo "[abc] done. run ing.sh next for the full setup."
