# ollama-predict

Local LLM-powered inline shell command predictions for zsh.

## How it works

```
┌─────────────────┐     Unix socket     ┌─────────────────────┐
│   zsh plugin     │ ◄──────────────────► │  Python sidecar     │
│  (zle widgets)   │   JSON over newline  │  (long-running)     │
│                  │                      │                     │
│  • ghost text    │                      │  • frecency engine  │
│  • key bindings  │                      │  • Ollama API       │
│  • async I/O     │                      │  • feedback learn   │
└─────────────────┘                      └─────────┬───────────┘
                                                    │ HTTP
                                                    ▼
                                           ┌────────────────┐
                                           │  Ollama server  │
                                           │  (qwen3:0.6b)  │
                                           └────────────────┘
```

**On each keystroke (debounced 150ms):**
1. Current buffer + context (cwd, git branch, recent history) sent to sidecar
2. Sidecar queries both frecency-scored history AND the Ollama model **in parallel**
3. If Ollama responds within 300ms, LLM suggestions appear first; otherwise history-only
4. Ghost text appears dimmed to the right of the cursor

## Keybindings

| Key | Action |
|---|---|
| `→` | Accept full suggestion |
| `Tab` | Accept suggestion (or normal completion if none) |
| `Ctrl+→` / `Alt+F` | Accept next word |
| `Ctrl+N` / `Shift+Tab` | Cycle to next suggestion |
| `Ctrl+P` | Cycle to previous suggestion |
| `Escape` | Dismiss suggestion (or vi-cmd-mode if none) |
| `Ctrl+X Ctrl+O` | Toggle plugin on/off |

## Prerequisites

- Python 3.8+
- [Ollama](https://ollama.ai) running locally
- A small model pulled: `ollama pull qwen3:0.6b`
- Optional: `socat` for faster socket communication

## Configuration

Set these environment variables before the plugin is sourced:

```zsh
export OLLAMA_PREDICT_MODEL="qwen3:0.6b"     # Ollama model
export OLLAMA_PREDICT_TIMEOUT="0.3"           # LLM timeout in seconds
export OLLAMA_PREDICT_DEBOUNCE=150            # Keystroke debounce in ms
export OLLAMA_PREDICT_MIN_CHARS=2             # Min chars before predicting
export OLLAMA_PREDICT_ENABLED=1               # 0 to disable
export OLLAMA_PREDICT_STYLE="fg=8"            # Ghost text zsh highlight style
export OLLAMA_PREDICT_MAX=5                   # Max suggestions to return
export OLLAMA_PREDICT_HISTORY_N=20            # History entries for context
```

## Management

```bash
ollama-predict-ctl start    # Start sidecar daemon
ollama-predict-ctl stop     # Stop sidecar
ollama-predict-ctl status   # Check if running
ollama-predict-ctl health   # Query health endpoint
ollama-predict-ctl config   # Show current config
```

## Learning

The plugin learns from your behavior:
- **Accepted suggestions** (Tab/→/Enter) get a frecency boost
- **Dismissed suggestions** (Escape) get a small penalty
- Feedback persists in `~/.local/share/ollama-predict/feedback.json`
- Commands used in the current directory get weighted higher

## chezmoi

Enable in `.chezmoidata.yaml`:
```yaml
modules:
  ollama_predict: true
```
