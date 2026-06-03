"""Cortex MCP server (FastMCP, stdio) — the single in-house brain.

One local process that gives any MCP client (Claude Code / desktop) the whole
vault: semantic + literal search, the wiki-link graph, full file management,
frontmatter, templates, daily notes, and a gated shell escape hatch. It reads
and writes the vault's markdown directly — no Obsidian plugin, no REST bridge,
no bearer token. The file watcher keeps the embedding index fresh, so anything
these tools write is searchable within a couple of seconds.

Not here (needs the running app): opening a note in the UI, firing Obsidian
commands, the unsaved editor buffer.

Run:
  python -m cortex.server          # stdio (Claude desktop / Code)
  python -m cortex.server --http   # streamable-http on 127.0.0.1:8787
"""
from __future__ import annotations

import argparse
import json
import re

from mcp.server.fastmcp import FastMCP

from . import config, embed, index, papers, research, store, vault

mcp = FastMCP("cortex")


# --- formatting helpers ------------------------------------------------------

def _fmt_hits(hits) -> str:
    if not hits:
        return "No matches in the vault index. Run the reindex tool if it's empty."
    out = []
    for h in hits:
        loc = h.path + (f"  ›  {h.heading}" if h.heading else "")
        out.append(f"### [{h.score:.3f}] {loc}\n{' '.join(h.text.split())}")
    return "\n\n".join(out)


def _json(obj) -> str:
    return json.dumps(obj, indent=2, default=str, ensure_ascii=False)


def _coerce(value: str):
    """Light typing for frontmatter values passed as strings."""
    v = value.strip()
    low = v.lower()
    if low in ("true", "false"):
        return low == "true"
    if low in ("null", "none", "~"):
        return None
    if re.fullmatch(r"-?\d+", v):
        return int(v)
    if ", " in v:
        return [p.strip() for p in v.split(",") if p.strip()]
    return v


def _safe(fn, *a, **kw) -> str:
    """Run a vault op, turning VaultError into a clean client-facing message."""
    try:
        return _json(fn(*a, **kw))
    except vault.VaultError as e:
        return f"Error: {e}"


# ============================================================================
# Search & recall
# ============================================================================

@mcp.tool()
def semantic_search(query: str, k: int = 8) -> str:
    """Meaning-based search across the entire vault (embeddings, not keywords).

    Use for conceptual questions — "what did I decide about baselines?",
    "notes about hallucination" — where the wording won't match literally.
    Returns ranked passages with path, heading breadcrumb and similarity score.
    """
    db = store.connect()
    return _fmt_hits(store.search(db, embed.embed_query(query), k))


@mcp.tool()
def related_notes(path: str, k: int = 8) -> str:
    """Notes semantically related to a given note (vault-relative path).

    Embeds the note's content and returns the nearest other passages, excluding
    the note itself — like Smart Connections' "related notes" pane.
    """
    try:
        text = vault.read_any(path)
    except vault.VaultError as e:
        return f"Error: {e}"
    db = store.connect()
    hits = [h for h in store.search(db, embed.embed_query(text[:4000]), k + 6) if h.path != path]
    return _fmt_hits(hits[:k])


@mcp.tool()
def search_text(query: str, regex: bool = False, case_sensitive: bool = False,
                folder: str = "", k: int = 50) -> str:
    """Literal or regex grep across vault markdown (exact strings, not meaning).

    Use when you need precise matches — a function name, an exact phrase, a date.
    Returns up to `k` path:line hits. Scope to a subfolder with `folder`.
    """
    hits = vault.search_text(query, regex=regex, case_sensitive=case_sensitive,
                             folder=folder or None, k=k)
    return _json([{"path": h.path, "line": h.line, "text": h.text} for h in hits])


@mcp.tool()
def search_property(field: str, value: str = "") -> str:
    """Find notes by a YAML frontmatter property (e.g. type=project-context,
    status=active, domain=nlp). This vault organises by properties, not #tags —
    use this to answer "all active projects", "every literature note", etc.
    Omit `value` to find every note that simply has the field.
    """
    return _json(vault.search_frontmatter(field, value or None))


@mcp.tool()
def backlinks(path: str) -> str:
    """Notes that link TO this note via [[wikilinks]] (incoming edges)."""
    return _safe(vault.backlinks, path)


@mcp.tool()
def outgoing_links(path: str) -> str:
    """[[wikilink]] targets this note points to (outgoing edges)."""
    return _safe(vault.outgoing_links, path)


# ============================================================================
# Read
# ============================================================================

@mcp.tool()
def get_note(path: str) -> str:
    """Full text of a note. Accepts a vault-relative path, or the absolute path
    of an indexed external file (from CORTEX_EXTRA_ROOTS) as returned by search —
    external files are read-only."""
    try:
        return vault.read_any(path)
    except vault.VaultError as e:
        return f"Error: {e}"


@mcp.tool()
def get_section(path: str, heading: str) -> str:
    """Just the body under a given heading in a note (case-insensitive match)."""
    try:
        return vault.get_section(path, heading)
    except vault.VaultError as e:
        return f"Error: {e}"


@mcp.tool()
def get_metadata(path: str) -> str:
    """Frontmatter + structure for a note: properties, headings, outgoing links,
    word/byte counts, last-modified. No body — cheap to call before reading."""
    return _safe(vault.metadata, path)


@mcp.tool()
def list_notes(folder: str = "", limit: int = 0) -> str:
    """List vault-relative note paths, optionally under `folder`, capped at
    `limit` (0 = all). Ignores .obsidian, .trash and other configured globs."""
    return _json(vault.list_notes(folder or None, limit or None))


@mcp.tool()
def list_folders() -> str:
    """List every folder in the vault (the structural skeleton)."""
    return _json(vault.list_folders())


@mcp.tool()
def vault_stats() -> str:
    """Counts: notes, folders, total bytes, vault path — plus index stats."""
    s = vault.vault_stats()
    try:
        s["index"] = store.stats(store.connect())
    except Exception as e:  # index optional / Ollama down
        s["index"] = f"unavailable: {e}"
    return _json(s)


# ============================================================================
# Write & manage  (the watcher reindexes anything written here within ~2s)
# ============================================================================

@mcp.tool()
def write_note(path: str, content: str, overwrite: bool = True) -> str:
    """Create or overwrite a note with `content`. Makes parent folders. Set
    overwrite=False to refuse clobbering an existing note."""
    return _safe(vault.write_note, path, content, overwrite)


@mcp.tool()
def append_note(path: str, content: str) -> str:
    """Append `content` to a note (creating it if absent), with a clean newline."""
    return _safe(vault.append_note, path, content)


@mcp.tool()
def patch_note(path: str, heading: str, content: str, mode: str = "append") -> str:
    """Insert `content` under an ATX `heading`. mode: append | prepend | replace.
    Creates the heading at end-of-file if it doesn't exist."""
    return _safe(vault.patch_section, path, heading, content, mode)


@mcp.tool()
def set_property(path: str, key: str, value: str) -> str:
    """Set one frontmatter property (creating the YAML block if needed). Values
    are lightly typed: true/false→bool, integers→int, "a, b"→list, else string."""
    return _safe(vault.set_frontmatter, path, key, _coerce(value))


@mcp.tool()
def delete_note(path: str) -> str:
    """Delete a note from the vault (and the watcher prunes it from the index)."""
    return _safe(vault.delete_note, path)


@mcp.tool()
def move_note(src: str, dst: str, update_links: bool = True) -> str:
    """Move/rename a note. With update_links, rewrites [[wikilinks]] vault-wide
    so nothing breaks. Returns how many links were rewired."""
    return _safe(vault.move_note, src, dst, update_links)


# ============================================================================
# Templates & daily notes
# ============================================================================

@mcp.tool()
def create_from_template(template: str, target: str, variables: str = "",
                         overwrite: bool = False) -> str:
    """Create `target` from a template note, substituting {{placeholders}}.
    {{date}}/{{time}}/{{datetime}} are built in; pass more as a JSON object in
    `variables` (e.g. '{"title": "Project Alpha", "lead": "Alice"}')."""
    try:
        vars_dict = json.loads(variables) if variables.strip() else {}
    except json.JSONDecodeError as e:
        return f"Error: variables must be a JSON object ({e})"
    return _safe(vault.create_from_template, template, target, vars_dict, overwrite)


@mcp.tool()
def daily_note(date: str = "", template: str = "", create: bool = True) -> str:
    """Path to a daily note (default today; `date` as YYYY-MM-DD), creating it if
    missing — optionally from a `template`. Honors CORTEX_DAILY_FOLDER/FORMAT."""
    return _safe(vault.daily_note, date or None, template or None, create)


# ============================================================================
# Sharper search & research
# ============================================================================

@mcp.tool()
def search_filtered(query: str, field: str, value: str = "", k: int = 8) -> str:
    """Semantic search constrained to notes whose frontmatter matches a property —
    e.g. field='status' value='active', or field='type' value='literature'. Pairs
    meaning-based ranking with this vault's property organisation."""
    allowed = set(vault.search_frontmatter(field, value or None))
    if not allowed:
        return f"No notes with {field}={value or '(any)'}."
    db = store.connect()
    hits = [h for h in store.search(db, embed.embed_query(query), max(k * 6, 30)) if h.path in allowed]
    return _fmt_hits(hits[:k])


@mcp.tool()
def hybrid_search(query: str, k: int = 8) -> str:
    """Hybrid keyword + semantic search (BM25 ⊕ vector, rank-fused). Beats pure
    semantic when exact terms matter — a method name, an acronym, a file name."""
    db = store.connect()
    return _fmt_hits(store.search_hybrid(db, query, embed.embed_query(query), k))


@mcp.tool()
def lookup_paper(identifier: str) -> str:
    """Resolve a DOI or arXiv id/URL to paper metadata + an APA citation + BibTeX
    (via CrossRef / arXiv). For building literature notes."""
    return _json(papers.lookup(identifier))


@mcp.tool()
def deadlines(days_ahead: int = 21) -> str:
    """Upcoming dated gates/deadlines parsed from STATE.md within the window,
    soonest first — surfaces what's due without re-reading the whole file."""
    return _json(research.upcoming_deadlines(days_ahead))


@mcp.tool()
def suggest_links(path: str, k: int = 8) -> str:
    """Notes semantically near this one that it does NOT already [[link]] to —
    candidate wikilinks to add, to keep the graph connected."""
    return _safe(research.suggest_links, path, k)


# ============================================================================
# Index & system
# ============================================================================

@mcp.tool()
def reindex() -> str:
    """Re-embed notes changed since the last index (incremental, fast). The
    watcher normally does this automatically; call this to force a refresh."""
    index.build(full=False)
    return _json(store.stats(store.connect()))


@mcp.tool()
def run_command(command: str, cwd: str = "") -> str:
    """Run a shell command in the vault (or `cwd` subfolder). DISABLED unless the
    server was started with CORTEX_ALLOW_EXEC=1 — a deliberate gate so an agent
    can't run arbitrary shell by default. Returns exit code, stdout, stderr."""
    return _safe(vault.run_command, command, cwd or None)


def main(argv=None) -> int:
    p = argparse.ArgumentParser(prog="cortex.server")
    p.add_argument("--http", action="store_true", help="serve streamable-http instead of stdio")
    args = p.parse_args(argv)
    if args.http:
        mcp.settings.host = "127.0.0.1"
        mcp.settings.port = 8787
        mcp.run(transport="streamable-http")
    else:
        mcp.run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
