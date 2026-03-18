#!/usr/bin/env zsh
# ──────────────────────────────────────────────────────────────────────────
# ollama-predict.plugin.zsh
# Inline ghost-text command predictions using local Ollama + frecency history
# ──────────────────────────────────────────────────────────────────────────

# Guard against double-sourcing
(( ${+_OLLAMA_PREDICT_LOADED} )) && return
typeset -g _OLLAMA_PREDICT_LOADED=1

# ── Config (override via env before sourcing) ─────────────────────────────
: ${OLLAMA_PREDICT_SOCK:="/tmp/ollama-predict-$(id -u).sock"}
: ${OLLAMA_PREDICT_DEBOUNCE:=150}       # ms debounce on keystrokes
: ${OLLAMA_PREDICT_HISTORY_N:=20}       # last N history entries sent as context
: ${OLLAMA_PREDICT_ENABLED:=1}          # master toggle
: ${OLLAMA_PREDICT_STYLE:=fg=8}         # ghost text color (dim gray)
: ${OLLAMA_PREDICT_MIN_CHARS:=2}        # min chars before predicting
: ${OLLAMA_PREDICT_DATA:="$HOME/.local/share/ollama-predict"}

# Plugin root directory
typeset -g _OP_DIR="${0:A:h}"

# ── State ──────────────────────────────────────────────────────────────────
typeset -g  _op_suggestion=""            # current full suggestion text
typeset -ga _op_suggestions=()           # all suggestions from last response
typeset -gi _op_suggestion_idx=0         # which suggestion is shown (1-based)
typeset -gi _op_seq=0                    # monotonic sequence counter
typeset -gi _op_async_fd=-1              # fd watched by zle -F
typeset -g  _op_fifo=""                  # named pipe path
typeset -g  _op_sidecar_pid=""           # sidecar PID

# ── Sidecar lifecycle ─────────────────────────────────────────────────────
_op_sidecar_start() {
    local pidfile="$OLLAMA_PREDICT_DATA/sidecar.pid"
    if [[ -f "$pidfile" ]]; then
        local pid=$(<"$pidfile")
        if kill -0 "$pid" 2>/dev/null; then
            _op_sidecar_pid="$pid"
            return 0
        fi
    fi

    python3 "$_OP_DIR/sidecar.py" &>/dev/null &!
    _op_sidecar_pid=$!

    local i=0
    while [[ ! -S "$OLLAMA_PREDICT_SOCK" ]] && (( i < 20 )); do
        sleep 0.05
        (( i++ ))
    done
    [[ -S "$OLLAMA_PREDICT_SOCK" ]]
}

_op_sidecar_stop() {
    [[ -n "$_op_sidecar_pid" ]] && kill "$_op_sidecar_pid" 2>/dev/null
    _op_sidecar_pid=""
}

# ── Socket send (blocking, used inside background jobs only) ──────────────
_op_sock_send() {
    local payload="$1" sock="$OLLAMA_PREDICT_SOCK"
    if command -v socat &>/dev/null; then
        printf '%s\n' "$payload" | socat -t0.5 - UNIX-CONNECT:"$sock" 2>/dev/null
    else
        python3 -c "
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(0.5)
s.connect(sys.argv[1])
s.sendall((sys.argv[2] + '\n').encode())
buf = b''
while b'\n' not in buf:
    c = s.recv(4096)
    if not c: break
    buf += c
s.close()
sys.stdout.buffer.write(buf)
" "$sock" "$payload" 2>/dev/null
    fi
}

# ── Build JSON request ────────────────────────────────────────────────────
_op_build_json() {
    local buffer="$1" cwd="$2" branch="$3"
    shift 3
    # remaining args are history entries
    python3 -c "
import json, sys
print(json.dumps({
    'action': 'predict',
    'buffer': sys.argv[1],
    'cwd': sys.argv[2],
    'git_branch': sys.argv[3],
    'history': sys.argv[4:]
}))" "$buffer" "$cwd" "$branch" "$@"
}

# ── Ghost text rendering ─────────────────────────────────────────────────
_op_show_ghost() {
    local suggestion="$1"
    if [[ -z "$suggestion" || -z "$BUFFER" ]]; then
        _op_clear_ghost
        return
    fi

    # Show the part after what's already typed
    if [[ "$suggestion" == "$BUFFER"* ]]; then
        POSTDISPLAY="${suggestion#$BUFFER}"
        _op_suggestion="$suggestion"
    elif [[ "${suggestion:l}" == "${BUFFER:l}"* ]]; then
        POSTDISPLAY="${suggestion:${#BUFFER}}"
        _op_suggestion="$suggestion"
    else
        _op_clear_ghost
        return
    fi

    if [[ -n "$POSTDISPLAY" ]]; then
        region_highlight=("P0 ${#POSTDISPLAY} ${OLLAMA_PREDICT_STYLE}")
    fi
}

_op_clear_ghost() {
    POSTDISPLAY=""
    _op_suggestion=""
    _op_suggestions=()
    _op_suggestion_idx=0
    region_highlight=()
}

# ── Async callback (called by zle -F when data arrives on fifo) ──────────
_op_async_read() {
    local fd="$1"
    local line=""

    # Read one line from the fd
    if ! IFS= read -r -u "$fd" line 2>/dev/null; then
        # EOF or error — reopen the fifo to keep zle -F alive
        zle -F "$fd"
        exec {fd}<&-
        exec {_op_async_fd}<>"$_op_fifo"
        zle -F "$_op_async_fd" _op_async_read
        return
    fi

    [[ -z "$line" ]] && return

    # Line format: SEQ<TAB>JSON_RESPONSE
    local seq="${line%%	*}"
    local resp="${line#*	}"

    # Stale? Ignore.
    (( seq != _op_seq )) && return

    # Parse suggestions from JSON response
    _op_suggestions=()
    _op_suggestion_idx=0

    local -a parsed
    parsed=("${(@f)$(python3 -c "
import json, sys
try:
    d = json.loads(sys.argv[1])
    for s in d.get('suggestions', []):
        print(s['text'])
except: pass
" "$resp" 2>/dev/null)}")

    local s
    for s in "${parsed[@]}"; do
        [[ -n "$s" ]] && _op_suggestions+=("$s")
    done

    if (( ${#_op_suggestions} > 0 )); then
        _op_suggestion_idx=1
        _op_show_ghost "${_op_suggestions[1]}"
    else
        _op_clear_ghost
    fi

    zle -R
}

# ── Trigger prediction (debounced) ────────────────────────────────────────
_op_trigger_predict() {
    (( ! OLLAMA_PREDICT_ENABLED )) && return
    [[ ! -S "$OLLAMA_PREDICT_SOCK" ]] && return

    local buf="$BUFFER"
    (( ${#buf} < OLLAMA_PREDICT_MIN_CHARS )) && { _op_clear_ghost; zle -R; return; }

    # Bump sequence — any in-flight request with older seq is stale
    (( _op_seq++ ))
    local my_seq=$_op_seq

    # Capture context now (fast — no subshells for the hot path)
    local cwd="$PWD"
    local branch=""
    # Fast git branch detection: read HEAD file directly
    if [[ -f .git/HEAD ]]; then
        local head=$(<.git/HEAD)
        if [[ "$head" == ref:\ refs/heads/* ]]; then
            branch="${head#ref: refs/heads/}"
        fi
    fi

    # Gather recent history
    local -a hist=()
    local hline
    fc -l -n -${OLLAMA_PREDICT_HISTORY_N} 2>/dev/null | while IFS= read -r hline; do
        hline="${hline## }"
        [[ -n "$hline" ]] && hist+=("$hline")
    done

    local fifo="$_op_fifo"

    # Background job: debounce → build request → query sidecar → write to fifo
    {
        sleep $(printf '%.3f' "$(( OLLAMA_PREDICT_DEBOUNCE / 1000.0 ))")

        local json
        json=$(_op_build_json "$buf" "$cwd" "$branch" "${hist[@]}")
        [[ -z "$json" ]] && exit 0

        local resp
        resp=$(_op_sock_send "$json")
        [[ -z "$resp" ]] && exit 0

        # Write SEQ<TAB>RESPONSE to fifo (atomic for lines < PIPE_BUF)
        printf '%s\t%s\n' "$my_seq" "$resp" >> "$fifo"
    } &!
}

# ── ZLE widgets ───────────────────────────────────────────────────────────

# Accept full suggestion
_op_accept() {
    if [[ -n "$_op_suggestion" && -n "$POSTDISPLAY" ]]; then
        _op_feedback "$_op_suggestion" true
        BUFFER="$_op_suggestion"
        CURSOR=${#BUFFER}
        _op_clear_ghost
        zle -R
    else
        zle .forward-char  # default → behavior
    fi
}

# Accept next word from suggestion
_op_accept_word() {
    if [[ -n "$_op_suggestion" && "$_op_suggestion" != "$BUFFER" ]]; then
        local rest="${_op_suggestion#$BUFFER}"
        local word
        if [[ "$rest" =~ ^[[:space:]]*[^[:space:]]+ ]]; then
            word="$MATCH"
        else
            word="$rest"
        fi
        BUFFER="${BUFFER}${word}"
        CURSOR=${#BUFFER}
        _op_show_ghost "$_op_suggestion"
        zle -R
    fi
}

# Cycle suggestions forward
_op_next_suggestion() {
    if (( ${#_op_suggestions} > 1 )); then
        (( _op_suggestion_idx = (_op_suggestion_idx % ${#_op_suggestions}) + 1 ))
        _op_show_ghost "${_op_suggestions[$_op_suggestion_idx]}"
        zle -R
    fi
}

# Cycle suggestions backward
_op_prev_suggestion() {
    if (( ${#_op_suggestions} > 1 )); then
        (( _op_suggestion_idx = _op_suggestion_idx <= 1 ? ${#_op_suggestions} : _op_suggestion_idx - 1 ))
        _op_show_ghost "${_op_suggestions[$_op_suggestion_idx]}"
        zle -R
    fi
}

# Dismiss / Escape
_op_dismiss() {
    if [[ -n "$_op_suggestion" ]]; then
        _op_feedback "$_op_suggestion" false
        _op_clear_ghost
        zle -R
    else
        zle vi-cmd-mode
    fi
}

# Smart Tab: accept suggestion or fall through to default completion
_op_tab() {
    if [[ -n "$_op_suggestion" && -n "$POSTDISPLAY" ]]; then
        _op_accept
    else
        zle expand-or-complete
    fi
}

# Enter: clear ghost, submit line
_op_accept_line() {
    if [[ -n "$_op_suggestion" && "$BUFFER" == "$_op_suggestion" ]]; then
        _op_feedback "$_op_suggestion" true
    fi
    _op_clear_ghost
    zle .accept-line
}

# Self-insert wrapper
_op_self_insert() {
    zle .self-insert
    _op_trigger_predict
}

# Backspace wrapper
_op_backward_delete() {
    zle .backward-delete-char
    if (( ${#BUFFER} < OLLAMA_PREDICT_MIN_CHARS )); then
        _op_clear_ghost
        zle -R
    else
        _op_trigger_predict
    fi
}

# Toggle on/off
_op_toggle() {
    if (( OLLAMA_PREDICT_ENABLED )); then
        OLLAMA_PREDICT_ENABLED=0
        _op_clear_ghost; zle -R
        zle -M "ollama-predict: OFF"
    else
        OLLAMA_PREDICT_ENABLED=1
        zle -M "ollama-predict: ON"
    fi
}

# Async feedback (fire-and-forget)
_op_feedback() {
    local cmd="$1" accepted="$2"
    [[ ! -S "$OLLAMA_PREDICT_SOCK" ]] && return
    {
        local json
        json=$(python3 -c "
import json, sys
print(json.dumps({'action':'feedback','cmd':sys.argv[1],'accepted':sys.argv[2]=='true'}))" \
            "$cmd" "$accepted" 2>/dev/null)
        [[ -n "$json" ]] && _op_sock_send "$json" >/dev/null
    } &!
}

# ── Register widgets ──────────────────────────────────────────────────────
zle -N _op_self_insert
zle -N _op_backward_delete
zle -N _op_accept
zle -N _op_accept_word
zle -N _op_next_suggestion
zle -N _op_prev_suggestion
zle -N _op_dismiss
zle -N _op_tab
zle -N _op_accept_line
zle -N _op_toggle

# ── Keybindings ───────────────────────────────────────────────────────────
_op_bind_keys() {
    # Trigger predictions on printable keystrokes
    bindkey -M viins -R ' '-'~' _op_self_insert
    bindkey -M viins '^?' _op_backward_delete         # backspace

    # Accept full suggestion
    bindkey -M viins '^[[C' _op_accept                # → arrow

    # Smart tab: accept suggestion or complete
    bindkey -M viins '\t' _op_tab

    # Accept next word
    bindkey -M viins '^[[1;5C' _op_accept_word        # Ctrl+→
    bindkey -M viins '\ef' _op_accept_word             # Alt+F

    # Cycle through suggestions
    bindkey -M viins '^N' _op_next_suggestion          # Ctrl+N
    bindkey -M viins '^P' _op_prev_suggestion          # Ctrl+P
    bindkey -M viins '^[[Z' _op_next_suggestion        # Shift+Tab

    # Dismiss
    bindkey -M viins '\e' _op_dismiss                  # Escape

    # Toggle plugin
    bindkey -M viins '^X^O' _op_toggle                 # Ctrl+X Ctrl+O

    # Enter
    bindkey -M viins '^M' _op_accept_line
}

# ── Initialization ────────────────────────────────────────────────────────
_op_init() {
    (( ! OLLAMA_PREDICT_ENABLED )) && return

    mkdir -p "$OLLAMA_PREDICT_DATA" 2>/dev/null

    # Create per-shell fifo for async communication
    _op_fifo="${TMPDIR:-/tmp}/op-fifo-$$"
    [[ -p "$_op_fifo" ]] || mkfifo "$_op_fifo"

    # Open fifo read-write so open(2) doesn't block
    exec {_op_async_fd}<>"$_op_fifo"
    zle -F "$_op_async_fd" _op_async_read

    # Start sidecar in background (don't block shell init)
    { _op_sidecar_start } &!

    _op_bind_keys
}

_op_cleanup() {
    if (( _op_async_fd >= 0 )); then
        zle -F "$_op_async_fd" 2>/dev/null
        exec {_op_async_fd}<&- 2>/dev/null
    fi
    rm -f "$_op_fifo" 2>/dev/null
}
trap '_op_cleanup' EXIT INT TERM HUP

_op_init
