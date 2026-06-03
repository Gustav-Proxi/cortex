"""Cortex configuration.

All paths and model choices live here. Override anything via environment
variables so nothing sensitive (vault path, tokens) is hard-coded in the repo.
"""
from __future__ import annotations

import os
from pathlib import Path

# --- Vault -------------------------------------------------------------------
# The Obsidian vault to index. Defaults to ~/Claude/ per the second-brain setup.
VAULT_PATH = Path(os.environ.get("CORTEX_VAULT", str(Path.home() / "Claude"))).expanduser()

# Folders / files to skip while indexing (globs matched against vault-relative path).
# fnmatch '*' spans '/', so 'X/**' excludes everything under X.
IGNORE_GLOBS = [
    ".obsidian/**",
    ".trash/**",
    ".git/**",
    ".smart-env/**",   # Smart Connections' embedding cache — large, not notes
    ".claude/**",      # Claude Code command/prompt files, not vault knowledge
    "**/.DS_Store",
    # Add your own high-churn folders here, e.g. "99-Task-Snapshots/**".
]

# --- Embedding model ---------------------------------------------------------
# Local, private, runs on the M4 via Ollama. nomic-embed-text is 768-dim and
# REQUIRES task prefixes ("search_document:" / "search_query:").
OLLAMA_HOST = os.environ.get("OLLAMA_HOST", "http://127.0.0.1:11434")
EMBED_MODEL = os.environ.get("CORTEX_EMBED_MODEL", "nomic-embed-text")
EMBED_DIM = int(os.environ.get("CORTEX_EMBED_DIM", "768"))

# --- Vector store ------------------------------------------------------------
# Single sqlite file. Lives outside the vault by default so it never gets
# embedded into itself or synced/committed by accident.
DB_PATH = Path(
    os.environ.get("CORTEX_DB", str(Path.home() / ".cortex" / "index.db"))
).expanduser()

# --- Chunking ----------------------------------------------------------------
# Split notes by heading, then pack into ~chunk_chars windows with overlap.
CHUNK_CHARS = int(os.environ.get("CORTEX_CHUNK_CHARS", "1200"))
CHUNK_OVERLAP = int(os.environ.get("CORTEX_CHUNK_OVERLAP", "150"))

# --- Daily / periodic notes --------------------------------------------------
# Where new daily notes land and how they're named. Mirrors Obsidian's core
# "Daily notes" settings; override if your vault differs.
DAILY_FOLDER = os.environ.get("CORTEX_DAILY_FOLDER", "daily")
DAILY_FORMAT = os.environ.get("CORTEX_DAILY_FORMAT", "%Y-%m-%d")

# --- Local HTTP API ----------------------------------------------------------
# A tiny JSON endpoint (loopback) the watcher serves so things INSIDE Obsidian —
# the Cortex plugin — can reach the engine without speaking MCP. Not the MCP port.
HTTP_API_PORT = int(os.environ.get("CORTEX_HTTP_API_PORT", "8788"))

# --- Gated shell execution ---------------------------------------------------
# Parity with the plugin's "command execution", but OFF unless explicitly
# enabled — the run_command tool refuses to run anything until you opt in with
# CORTEX_ALLOW_EXEC=1. The MCP client still gates each call with its own prompt.
ALLOW_EXEC = os.environ.get("CORTEX_ALLOW_EXEC", "").lower() in ("1", "true", "yes", "on")
EXEC_TIMEOUT = int(os.environ.get("CORTEX_EXEC_TIMEOUT", "60"))


def ensure_dirs() -> None:
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
