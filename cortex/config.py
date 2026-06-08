"""Cortex configuration.

All paths and model choices live here. Override anything via environment
variables so nothing sensitive (vault path, tokens) is hard-coded in the repo.
"""
from __future__ import annotations

import os
import re
from pathlib import Path

# --- Vault -------------------------------------------------------------------
# The Obsidian vault to index. Defaults to ~/Claude/ per the second-brain setup.
# Resolve() once: macOS FSEvents reports realpath-canonicalized paths, so if the
# vault (or a parent) is a symlink, the watcher's relative_to() mapping would
# silently fail and sync would stop. Resolving here keeps every path comparison
# (watcher, resolve(), iter_notes) consistent with what the OS reports.
VAULT_PATH = Path(os.environ.get("CORTEX_VAULT", str(Path.home() / "Claude"))).expanduser().resolve()

# Recoverable-delete folder (Obsidian's convention). Destructive ops
# (delete / full overwrite) move the prior file here instead of dropping it.
# It is inside IGNORE_GLOBS below, so trashed notes are never indexed.
TRASH_DIR = os.environ.get("CORTEX_TRASH_DIR", ".trash")

# Folders / files to skip while indexing (globs matched against vault-relative path).
# fnmatch '*' spans '/', so 'X/**' excludes everything under X.
IGNORE_GLOBS = [
    ".obsidian/**",
    f"{TRASH_DIR}/**",   # derived from TRASH_DIR so trashed notes are ALWAYS ignored
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

# The web UI's "ask" mode answers with CLAUDE via the local Claude Code CLI
# (`claude -p`) — your existing Claude Code subscription auth, NO API key, no
# per-call API billing. On automatically if the claude binary is found (override
# its path with CORTEX_CLAUDE_BIN). Retrieval stays local; only the answer call
# (question + retrieved snippets) goes to Claude. This is the one egress path.
CLAUDE_BIN = os.environ.get("CORTEX_CLAUDE_BIN", "").strip()
CLAUDE_MODEL = os.environ.get("CORTEX_CLAUDE_MODEL", "sonnet").strip()

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

# --- External source roots (multi-root indexing) -----------------------------
# Read-only directories indexed ALONGSIDE the vault so agents/Claude can search
# your projects/docs ("what's where, what each file contains") without copying
# anything into the vault. Set CORTEX_EXTRA_ROOTS to a colon- or comma-separated
# list of absolute paths, e.g. "~/Downloads/Projects:~/Documents/papers".
# Default: none (vault only). External files are indexed IN PLACE, keyed by
# absolute path, and are NEVER written to — index everything you point at, leave
# the OS alone (system dirs are excluded below regardless).
def _parse_roots(raw: str) -> list[Path]:
    out: list[Path] = []
    for part in re.split(r"[%s,]" % re.escape(os.pathsep), raw or ""):
        part = part.strip()
        if not part:
            continue
        p = Path(part).expanduser().resolve()
        if p.is_dir() and p not in out:
            out.append(p)
    return out


EXTRA_ROOTS = _parse_roots(os.environ.get("CORTEX_EXTRA_ROOTS", ""))

# Which file types to index inside EXTRA_ROOTS — markdown, plain text, PDFs (via
# pypdf) and source code (read verbatim, windowed by the generic chunker; see
# extract.py / chunk.chunk_text). Point CORTEX_EXTRA_ROOTS at a papers folder or a
# project's codebase and these become searchable alongside the vault. The vault
# itself is always *.md. Override the set with CORTEX_INDEX_EXTENSIONS.
INDEX_EXTENSIONS = {
    (e if e.startswith(".") else f".{e}").lower()
    for e in re.split(r"[,\s]+", os.environ.get(
        "CORTEX_INDEX_EXTENSIONS",
        ".md .txt .pdf .py .js .ts .tsx .jsx .mjs .swift .go .rs .java .kt .c .cc "
        ".cpp .h .hpp .rb .php .lua .r .sh .sql .graphql .json .yaml .yml .toml "
        ".html .css .scss .vue .svelte .tex").strip())
    if e
}

# Directory names never descended into inside an external root — system,
# dependency, build and cache noise that must never be embedded (this is the
# "leave out major system files" guard; keeps the index small and on-signal).
EXTERNAL_IGNORE_DIRS = {
    "node_modules", ".venv", "venv", "env", ".env", "__pycache__", ".git", ".hg",
    ".svn", "site-packages", "dist", "build", ".cache", ".cargo", ".npm", ".tox",
    ".mypy_cache", ".pytest_cache", ".ipynb_checkpoints", ".gradle", ".next",
    "DerivedData", "Pods", "vendor", ".terraform", ".idea", ".vscode",
    "Library", "System", "Applications", ".Trash", ".obsidian", ".trash",
    ".smart-env", ".claude",
}

# Skip files bigger than this (bytes) inside external roots — a giant log/dump
# isn't knowledge, and embedding it would bloat the index.
MAX_INDEX_FILE_BYTES = int(os.environ.get("CORTEX_MAX_INDEX_FILE_BYTES", str(2 * 1024 * 1024)))


def ensure_dirs() -> None:
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
