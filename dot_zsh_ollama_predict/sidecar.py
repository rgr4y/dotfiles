#!/usr/bin/env python3
"""
ollama-predict sidecar daemon
Long-running process that serves shell command predictions via Unix socket.
Combines local Ollama LLM inference with frecency-scored history matching.
"""

import asyncio
import json
import os
import re
import signal
import sys
import time
import logging
from collections import defaultdict
from pathlib import Path
from urllib.request import urlopen, Request
from urllib.error import URLError

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
OLLAMA_URL = os.environ.get("OLLAMA_PREDICT_URL", "http://127.0.0.1:11434")
OLLAMA_MODEL = os.environ.get("OLLAMA_PREDICT_MODEL", "qwen3:0.6b")
SOCKET_PATH = os.environ.get(
    "OLLAMA_PREDICT_SOCK",
    f"/tmp/ollama-predict-{os.getuid()}.sock",
)
LLM_TIMEOUT = float(os.environ.get("OLLAMA_PREDICT_TIMEOUT", "0.3"))
MAX_SUGGESTIONS = int(os.environ.get("OLLAMA_PREDICT_MAX", "5"))
FEEDBACK_DIR = Path(os.environ.get(
    "OLLAMA_PREDICT_DATA",
    os.path.expanduser("~/.local/share/ollama-predict"),
))
LOG_LEVEL = os.environ.get("OLLAMA_PREDICT_LOG", "WARNING")

logging.basicConfig(
    level=getattr(logging, LOG_LEVEL.upper(), logging.WARNING),
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger("ollama-predict")

# ---------------------------------------------------------------------------
# Frecency engine — scores history entries by frequency + recency
# ---------------------------------------------------------------------------
class FrecencyEngine:
    """Score shell history entries by frequency × recency, optionally scoped to cwd."""

    def __init__(self):
        # cmd -> list of timestamps
        self._global: dict[str, list[float]] = defaultdict(list)
        # (cwd, cmd) -> list of timestamps
        self._by_dir: dict[tuple[str, str], list[float]] = defaultdict(list)
        # learned feedback: cmd -> accept_count
        self._feedback: dict[str, int] = defaultdict(int)
        self._load_feedback()

    # -- persistence for feedback -------------------------------------------
    def _feedback_path(self) -> Path:
        return FEEDBACK_DIR / "feedback.json"

    def _load_feedback(self):
        p = self._feedback_path()
        if p.exists():
            try:
                data = json.loads(p.read_text())
                self._feedback = defaultdict(int, data)
            except Exception:
                pass

    def save_feedback(self):
        FEEDBACK_DIR.mkdir(parents=True, exist_ok=True)
        p = self._feedback_path()
        # Keep only top 2000 entries
        items = sorted(self._feedback.items(), key=lambda x: -x[1])[:2000]
        p.write_text(json.dumps(dict(items)))

    def record_accept(self, cmd: str):
        self._feedback[cmd] += 1

    def record_reject(self, cmd: str):
        self._feedback[cmd] = max(0, self._feedback.get(cmd, 0) - 1)

    # -- ingest history -----------------------------------------------------
    def ingest(self, commands: list[dict]):
        """Ingest history entries: [{"cmd": "...", "cwd": "...", "ts": float}, ...]"""
        now = time.time()
        for entry in commands:
            cmd = entry.get("cmd", "").strip()
            if not cmd:
                continue
            ts = entry.get("ts", now)
            cwd = entry.get("cwd", "")
            self._global[cmd].append(ts)
            if cwd:
                self._by_dir[(cwd, cmd)].append(ts)

    # -- scoring ------------------------------------------------------------
    def _recency_weight(self, ts: float, now: float) -> float:
        age_hours = (now - ts) / 3600
        if age_hours < 1:
            return 4.0
        elif age_hours < 24:
            return 2.0
        elif age_hours < 168:  # 1 week
            return 1.0
        return 0.5

    def score(self, cmd: str, cwd: str = "") -> float:
        now = time.time()
        s = 0.0
        for ts in self._global.get(cmd, []):
            s += self._recency_weight(ts, now)
        # Boost for same directory
        if cwd:
            for ts in self._by_dir.get((cwd, cmd), []):
                s += self._recency_weight(ts, now) * 2.0
        # Boost for accepted feedback
        s += self._feedback.get(cmd, 0) * 3.0
        return s

    def suggest(self, prefix: str, cwd: str = "", limit: int = 5) -> list[tuple[str, float]]:
        """Return history commands matching prefix, sorted by frecency score."""
        prefix_lower = prefix.lower()
        candidates = []
        for cmd in self._global:
            if cmd.lower().startswith(prefix_lower) and cmd != prefix:
                candidates.append((cmd, self.score(cmd, cwd)))
        candidates.sort(key=lambda x: -x[1])
        return candidates[:limit]


# ---------------------------------------------------------------------------
# Ollama LLM client
# ---------------------------------------------------------------------------
async def query_ollama(buffer: str, cwd: str, git_branch: str,
                       history: list[str]) -> list[str]:
    """Query Ollama for command completions. Returns list of suggestions."""
    recent = "\n".join(f"  {c}" for c in history[-5:]) if history else "  (none)"
    prompt = (
        f"Complete this shell command. Return ONLY the full completed command, no explanation.\n"
        f"If multiple likely completions, return up to 3 separated by newlines.\n"
        f"Dir: {cwd}\n"
        f"{'Git: ' + git_branch if git_branch else ''}\n"
        f"Recent commands:\n{recent}\n"
        f"$ {buffer}"
    )

    payload = json.dumps({
        "model": OLLAMA_MODEL,
        "prompt": prompt,
        "stream": False,
        "options": {
            "temperature": 0.3,
            "num_predict": 80,
            "top_p": 0.9,
            "stop": ["\n\n", "```", "Dir:", "Recent"],
        },
    }).encode()

    def _do_request():
        req = Request(
            f"{OLLAMA_URL}/api/generate",
            data=payload,
            headers={"Content-Type": "application/json"},
        )
        try:
            with urlopen(req, timeout=LLM_TIMEOUT) as resp:
                data = json.loads(resp.read())
                return data.get("response", "").strip()
        except (URLError, TimeoutError, OSError) as e:
            log.debug("Ollama request failed: %s", e)
            return ""

    loop = asyncio.get_running_loop()
    try:
        raw = await asyncio.wait_for(
            loop.run_in_executor(None, _do_request),
            timeout=LLM_TIMEOUT + 0.05,
        )
    except asyncio.TimeoutError:
        log.debug("Ollama timed out")
        return []

    if not raw:
        return []

    # Parse response: split on newlines, clean up
    suggestions = []
    for line in raw.split("\n"):
        line = line.strip()
        # Remove numbering like "1." or "- "
        line = re.sub(r"^[\d]+[.)]\s*", "", line)
        line = re.sub(r"^[-•]\s*", "", line)
        # Remove leading "$ "
        line = re.sub(r"^\$\s*", "", line)
        line = line.strip()
        if line and line != buffer and len(line) > len(buffer):
            suggestions.append(line)
    return suggestions[:3]


# ---------------------------------------------------------------------------
# Request handler
# ---------------------------------------------------------------------------
frecency = FrecencyEngine()
_save_counter = 0


async def handle_request(data: dict) -> dict:
    global _save_counter
    action = data.get("action", "predict")

    if action == "predict":
        buffer = data.get("buffer", "").strip()
        cwd = data.get("cwd", "")
        git_branch = data.get("git_branch", "")
        history = data.get("history", [])

        if not buffer:
            return {"suggestions": []}

        # Ingest history for frecency scoring
        now = time.time()
        frecency.ingest([{"cmd": c, "cwd": cwd, "ts": now - i * 60}
                         for i, c in enumerate(reversed(history))])

        # Run history matching and LLM in parallel
        hist_task = asyncio.get_running_loop().run_in_executor(
            None, lambda: frecency.suggest(buffer, cwd, MAX_SUGGESTIONS)
        )
        llm_task = query_ollama(buffer, cwd, git_branch, history)

        hist_results, llm_results = await asyncio.gather(hist_task, llm_task)

        # Merge: LLM suggestions first (if any), then history, deduplicated
        seen = set()
        suggestions = []

        for cmd in llm_results:
            key = cmd.strip().lower()
            if key not in seen:
                seen.add(key)
                suggestions.append({"text": cmd, "source": "llm"})

        for cmd, score in hist_results:
            key = cmd.strip().lower()
            if key not in seen:
                seen.add(key)
                suggestions.append({"text": cmd, "source": "history", "score": score})

        return {"suggestions": suggestions[:MAX_SUGGESTIONS]}

    elif action == "feedback":
        cmd = data.get("cmd", "")
        accepted = data.get("accepted", False)
        if cmd:
            if accepted:
                frecency.record_accept(cmd)
            else:
                frecency.record_reject(cmd)
            _save_counter += 1
            if _save_counter % 10 == 0:
                frecency.save_feedback()
        return {"ok": True}

    elif action == "health":
        return {"status": "ok", "model": OLLAMA_MODEL, "pid": os.getpid()}

    return {"error": "unknown action"}


# ---------------------------------------------------------------------------
# Unix socket server
# ---------------------------------------------------------------------------
async def handle_client(reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
    try:
        while True:
            line = await asyncio.wait_for(reader.readline(), timeout=30.0)
            if not line:
                break
            try:
                data = json.loads(line.decode())
            except json.JSONDecodeError:
                writer.write(json.dumps({"error": "invalid json"}).encode() + b"\n")
                await writer.drain()
                continue

            result = await handle_request(data)
            writer.write(json.dumps(result).encode() + b"\n")
            await writer.drain()
    except (asyncio.TimeoutError, ConnectionResetError, BrokenPipeError):
        pass
    finally:
        writer.close()


async def main():
    # Clean up stale socket
    sock_path = Path(SOCKET_PATH)
    if sock_path.exists():
        sock_path.unlink()

    server = await asyncio.start_unix_server(handle_client, path=SOCKET_PATH)
    os.chmod(SOCKET_PATH, 0o600)
    log.info("Sidecar listening on %s (model=%s)", SOCKET_PATH, OLLAMA_MODEL)
    print(f"ollama-predict sidecar pid={os.getpid()} sock={SOCKET_PATH}", file=sys.stderr)

    # Write pidfile
    FEEDBACK_DIR.mkdir(parents=True, exist_ok=True)
    pidfile = FEEDBACK_DIR / "sidecar.pid"
    pidfile.write_text(str(os.getpid()))

    def _shutdown(sig, _):
        log.info("Shutting down (signal %s)", sig)
        frecency.save_feedback()
        sock_path.unlink(missing_ok=True)
        pidfile.unlink(missing_ok=True)
        sys.exit(0)

    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)

    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
