# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Cortex is the **in-house brain** over an Obsidian vault (`~/Claude`), exposed as one **MCP server** living at `~/cortex`. It embeds notes locally via Ollama for semantic recall *and* reads/writes the vault's markdown directly (file CRUD, wiki-links, frontmatter, templates, daily notes), so it **replaces** the old Obsidian REST-API / MCP-Connector plugins outright — no plugin, no HTTP bridge, no bearer token.

The repo lives at `~/cortex` **on purpose** — outside `~/Documents`, which macOS syncs to iCloud; a venv in an iCloud folder triggers an upload storm and `EDEADLK` lock-contention crashes (this bit us, hence the move). The only things Cortex can't do are live-UI actions (open a note in the running app, fire an Obsidian command) — those need the client.

## Commands

All commands run from the repo root against the repo-local `.venv`. `CORTEX_VAULT` must point at the vault for every invocation (it has no persistent config file).

```bash
# Setup (Ollama + model + venv + first index)
CORTEX_VAULT="$HOME/Claude" bash install.sh

# Indexing CLI
./.venv/bin/python -m cortex.index build           # incremental: only notes whose mtime changed
./.venv/bin/python -m cortex.index build --full     # wipe and re-embed every note
./.venv/bin/python -m cortex.index search "query" -k 8
./.venv/bin/python -m cortex.index stats

# MCP server
./.venv/bin/python -m cortex.server                 # stdio (Claude desktop / Code)
./.venv/bin/python -m cortex.server --http          # streamable-http on 127.0.0.1:8787 (Phase 3)

# Sync watcher (foreground; or via the launchd plist for login-start)
./.venv/bin/python -m cortex.watch
```

Console-script equivalents (`cortex-index`, `cortex-server`, `cortex-watch`) are declared in `pyproject.toml` but the docs/launchd all invoke via `python -m`.

There is **no test suite and no lint config** in this repo. Do not invent `pytest`/`ruff` commands — if you add tests or tooling, wire them into `pyproject.toml` first.

## Architecture

A one-way pipeline, one module per stage. Read these in order to understand it:

```
vault *.md → chunk.py → embed.py (Ollama) → store.py (sqlite-vec)
                                                  ↑
            index.py orchestrates ───────────────┤
            vault.py (file CRUD · links · search)─┤
            server.py (27 MCP tools → Claude) ────┤
            http_api.py (JSON :8788 → Obsidian) ──┤
            watch.py (sync + serves http_api) ────┘
```

Two faces over one engine: **Claude** via `server.py` (MCP, stdio, full
read+write) and **Obsidian** via `http_api.py` (loopback JSON, consumed by the
in-vault plugin under `obsidian-plugin/`, which is symlinked to
`~/Claude/.obsidian/plugins/cortex`).

- **`config.py`** — every path and model choice, all env-overridable. `IGNORE_GLOBS` skips `.obsidian`, `.trash`, `.git`, `.smart-env` (Smart Connections cache), and `.claude`. Also holds daily-note settings and the `ALLOW_EXEC` gate. DB defaults to `~/.cortex/index.db`, deliberately *outside* the vault so it never indexes itself.
- **`chunk.py`** — strips YAML frontmatter, splits markdown on ATX headings into sections each carrying a `"Parent > Child"` breadcrumb, then packs sections into ~`CHUNK_CHARS` windows with `CHUNK_OVERLAP`, preferring to cut on paragraph/sentence boundaries.
- **`embed.py`** — talks to Ollama over **stdlib `urllib`** (no `requests`/`ollama` dependency). Local only.
- **`store.py`** — sqlite-vec vectors **+ an FTS5 keyword index** (triggers keep them in lockstep; backfilled on first `connect`). `search` (vector, L2→similarity) and `search_hybrid` (reciprocal-rank fusion of vector + BM25). See invariants below.
- **`index.py`** — incremental indexer + the `build/search/stats` CLI. One bad note is skipped, not fatal.
- **`server.py`** — FastMCP server exposing **27 tools** (search / read / write / links / templates / daily / gated-exec) as thin wrappers: search/recall tools hit `store`+`embed`; everything else delegates to `vault`. `_safe()` turns `VaultError` into clean client messages; `_coerce()` lightly types frontmatter values.
- **`vault.py`** — the headless file layer: path-safe CRUD, frontmatter via **pyyaml**, the wiki-link graph (`backlinks`/`outgoing_links`), `search_text`/`search_frontmatter`, templates (`{{var}}`), daily notes, and gated `run_command`. Every public path runs through `resolve()`, which refuses anything escaping the vault root.
- **`watch.py`** — watchdog observer that trails edits by a couple seconds; keeps the index current after the write tools touch files. Also starts `http_api` in a daemon thread, so one background process does both sync and the local API.
- **`http_api.py`** — a tiny stdlib JSON HTTP API on loopback (`:8788`) so code *inside* Obsidian (the plugin) can reach the engine without speaking MCP. Routes: `/health`, `/search`, `/related`, `/note`, `/list`, `/write`, `/append`. Permissive CORS (Obsidian's `app://` origin). (No generation endpoint — Cortex does **retrieval only**; Claude is the generator.)
- **`research.py`** — `upcoming_deadlines` (parses ISO *and* "Jun 7"-style dates out of STATE.md) and `suggest_links` (semantic neighbours a note doesn't yet `[[link]]`).
- **`papers.py`** — DOI/arXiv → metadata + APA + BibTeX via CrossRef/arXiv (stdlib urllib; returns `{error}` offline).
- **`obsidian-plugin/`** — the in-Obsidian face (hand-written CommonJS, no build): semantic search pane, **auto-connections** (embeddings lookup for the active note, Smart-Connections-style), look-up-selection, and capture (write). Talks to `http_api`. Symlinked into the vault's plugin folder.

### Critical invariants (the cross-file gotchas)

1. **nomic-embed-text requires task prefixes.** Documents are embedded as `"search_document: <text>"`, queries as `"search_query: <text>"`. This is enforced in `embed.py` (`embed_documents` vs `embed_query`) and is **not optional** — mixing them silently destroys retrieval quality. Any new embedding path must keep this split.
2. **`EMBED_DIM` must match the model.** The `vec0` virtual table is created with a fixed `float[EMBED_DIM]` width (768 for nomic). `embed.py` hard-checks every vector's length and raises `EmbedError` on mismatch. Changing models means changing `CORTEX_EMBED_DIM` *and* rebuilding `--full`.
3. **Two tables joined by rowid.** `chunks` (metadata: path, heading, text, mtime, chunk_index) and `vec_chunks` (the `vec0` vectors). They are kept in lockstep: `vec_chunks.rowid == chunks.id`. To delete a note's vectors you must look its ids up from `chunks` first (`delete_path`), because `vec0` can't filter by `path`.
4. **Re-index = delete-then-insert by path.** `index_file` always `delete_path`s before re-inserting, so the store never holds stale chunks after an edit. Incremental skipping is keyed purely on `st_mtime` equality; `build()` also prunes notes that vanished from disk (`all_paths - on_disk`).
5. **Scores are L2-derived, not true cosine.** `vec0`'s default distance is L2; `store.search` converts it to a `1/(1+distance)` similarity in `(0,1]` (higher = closer). The `Hit.score` comment says "cosine" but the math is this conversion — don't rely on it being a real cosine value.
6. **The watcher debounces deliberately.** Obsidian writes a file several times per save, so `watch.py` buffers `.md` modifications in a pending dict and only re-embeds after `debounce` (2s) of quiet via a background `flush_loop` thread. Deletions, by contrast, prune immediately.
7. **All vault I/O is path-safe.** Every read/write path in `vault.py` goes through `resolve()`, which rejects absolute paths and `..` escapes outside the vault root. Any new file tool **must** route through it — don't open paths directly.
8. **The write tools don't embed inline.** `write_note`/`patch_note`/etc. only touch disk; the running watcher re-embeds within ~2s. If the watcher is down, search lags until the next `reindex`/`build` — by design (keeps writes fast and decoupled from Ollama).

## Security / data handling

- `~/.cortex/index.db` **embeds full note text** — it is gitignored (`*.db`, `.cortex/`) and must stay out of any synced or public folder.
- Going in-house removed the Obsidian REST bearer token from live configs, but older `STATE.md` / `CRITICAL_FACTS.md` snapshots may still contain it — don't surface or commit it.
- `run_command` is gated behind `CORTEX_ALLOW_EXEC=1` (off by default) so an agent can't run arbitrary shell. Keep it off unless you mean it.
- Before any `--http` / remote exposure, front it with auth and serve only a sanitized public subset — never the private research vault.
