"""Generation via the local Claude Code CLI (`claude -p`) — uses the user's
existing Claude Code subscription auth, NOT an API key. The one egress path,
used only by the web UI's /ask. Retrieval stays local; the question plus the
retrieved note snippets are sent to Claude. MCP is disabled (--strict-mcp-config)
so the answer is a fast, tool-free text completion."""
from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

from . import config


class ClaudeError(RuntimeError):
    pass


_CANDIDATES = [
    "/opt/homebrew/bin/claude",
    str(Path.home() / ".local/bin/claude"),
    "/usr/local/bin/claude",
]
# launchd gives the watcher a bare PATH; claude (and its node runtime) live here.
_PATH = ":".join([
    "/opt/homebrew/bin", str(Path.home() / ".local/bin"), "/usr/local/bin",
    "/usr/bin", "/bin", os.environ.get("PATH", ""),
])


def find_claude() -> str | None:
    """Absolute path to the claude binary, or None if not installed."""
    if config.CLAUDE_BIN:
        return config.CLAUDE_BIN if Path(config.CLAUDE_BIN).exists() else None
    found = shutil.which("claude", path=_PATH)
    if found:
        return found
    return next((c for c in _CANDIDATES if Path(c).exists()), None)


def answer(question: str, context: str, *, system: str, model: str, claude_bin: str,
           timeout: int = 120) -> str:
    prompt = (f"Question: {question}\n\nNotes from my vault:\n{context}\n\n"
              "Answer the question using only these notes. Cite sources inline as [n]. "
              "If the notes don't contain the answer, say so in one line.")
    cmd = [claude_bin, "-p", prompt, "--system-prompt", system, "--strict-mcp-config"]
    if model:
        cmd += ["--model", model]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout,
                              env={**os.environ, "PATH": _PATH})
    except subprocess.TimeoutExpired:
        raise ClaudeError(f"claude timed out after {timeout}s")
    except OSError as e:
        raise ClaudeError(f"could not run claude: {e}")
    if proc.returncode != 0:
        raise ClaudeError((proc.stderr or proc.stdout or "claude failed").strip()[-300:])
    return proc.stdout.strip()
