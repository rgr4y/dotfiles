#!/bin/zsh

# Detect VSCode terminal and skip tmux if found.
if [[ "$TERM_PROGRAM" == "vscode" ]]; then
  return 0 2>/dev/null || exit 0
fi

PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

BASE_SESSION_NAME="tm"
SUFFIX=0

# Find the next available session name (tm_0, tm_1, tm_2, ...)
find_next_session_name() {
  local i=0
  while tmux has-session -t "${BASE_SESSION_NAME}_$i" 2>/dev/null; do
    i=$((i + 1))
  done
  echo "${BASE_SESSION_NAME}_$i"
}

# Check for existing tmux sessions
EXISTING_SESSION=$(tmux list-sessions 2>/dev/null | awk '{print $1}' | sed 's/://')

if [[ -n "$EXISTING_SESSION" ]]; then
  # Check for detached sessions
  DETACHED_SESSION=$(tmux list-sessions 2>/dev/null | grep -v attached | head -1 | awk '{print $1}' | sed 's/://')

  if [[ -n "$DETACHED_SESSION" ]]; then
    echo "Attaching to detached session: $DETACHED_SESSION"
    tmux attach-session -t "$DETACHED_SESSION"
  else
    tmux list-sessions
    echo #################
    SESSION_NAME=$(find_next_session_name)
    tmux new-session -s "$SESSION_NAME"
  fi
else
  tmux new-session -s "${BASE_SESSION_NAME}_0"
fi
