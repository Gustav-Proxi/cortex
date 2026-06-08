"""Indexer + CLI.

  python -m cortex.index build      # embed everything new/changed (incremental)
  python -m cortex.index build --full   # wipe + re-embed every note
  python -m cortex.index search "query text"
  python -m cortex.index stats

Incremental: a note is re-embedded only if its mtime is newer than what the
store has, and notes deleted from disk are pruned from the store.
"""
from __future__ import annotations

import argparse
import fnmatch
import os
import sys
from pathlib import Path

from . import config, embed, extract, store
from .chunk import chunk_markdown, chunk_text


def _ignored(rel: str) -> bool:
    return any(fnmatch.fnmatch(rel, pat) for pat in config.IGNORE_GLOBS)


def path_id(p: Path) -> str:
    """Stable index key for a file: vault-relative for vault notes (unchanged,
    backward-compatible), absolute for files under an external root. The leading
    "/" is how the rest of the engine tells an external file from a vault note."""
    rp = p.resolve()
    try:
        return str(rp.relative_to(config.VAULT_PATH))
    except ValueError:
        return str(rp)


def iter_notes() -> list[Path]:
    out = []
    for p in config.VAULT_PATH.rglob("*.md"):
        rel = str(p.relative_to(config.VAULT_PATH))
        if not _ignored(rel):
            out.append(p)
    return out


def iter_external() -> list[Path]:
    """Files to index from CORTEX_EXTRA_ROOTS: only INDEX_EXTENSIONS, never
    descending into system/dependency/cache dirs or hidden dirs, size-capped."""
    out: list[Path] = []
    for root in config.EXTRA_ROOTS:
        for dirpath, dirnames, filenames in os.walk(root):
            # Prune ignored + hidden dirs in place so os.walk never descends them.
            dirnames[:] = [d for d in dirnames
                           if d not in config.EXTERNAL_IGNORE_DIRS and not d.startswith(".")]
            for fn in filenames:
                if fn.startswith("."):
                    continue
                if os.path.splitext(fn)[1].lower() not in config.INDEX_EXTENSIONS:
                    continue
                p = Path(dirpath) / fn
                try:
                    if p.stat().st_size > config.MAX_INDEX_FILE_BYTES:
                        continue
                except OSError:
                    continue
                out.append(p)
    return out


def _belongs_to_reconciled(path_str: str) -> bool:
    """Is this stored path within a root THIS run reconciles? Vault-relative
    paths always are. Absolute (external) paths only if under a configured
    EXTRA_ROOT — so a watcher running without CORTEX_EXTRA_ROOTS prunes stale
    vault notes but never wipes an external index built by a CLI run that had
    the roots set."""
    if not path_str.startswith("/"):
        return True
    p = Path(path_str)
    return any(p == r or r in p.parents for r in config.EXTRA_ROOTS)


def index_file(db, path: Path, *, force: bool = False) -> int:
    pid = path_id(path)
    # Never embed ignored vault paths (.obsidian, .trash, …). The watcher enqueues
    # any touched *.md by name, so without this guard a note moved into .trash —
    # or an edit under .obsidian — would slip into the index and drift from what a
    # full rebuild (which filters IGNORE_GLOBS) produces. (Vault-relative ids only;
    # external files are already filtered by iter_external.) Prune any stale entry.
    if not pid.startswith("/") and _ignored(pid):
        store.delete_path(db, pid)
        db.commit()
        return 0
    mtime = path.stat().st_mtime
    if not force and store.file_mtime(db, pid) == mtime:
        return 0
    if extract.is_markdown(path):
        chunks = chunk_markdown(pid, path.read_text(encoding="utf-8", errors="replace"))
    else:                                   # PDF / source code / plain text from extra roots
        text = extract.extract_text(path)
        chunks = chunk_text(pid, text) if text else []
    store.delete_path(db, pid)
    if not chunks:
        db.commit()
        return 0
    # Embed the heading breadcrumb alongside the chunk text: the breadcrumb
    # carries the section's context ("Note > H2 > H3"), which sharpens recall
    # for short or ambiguous chunks. embed_documents adds the search_document:
    # prefix, so this stays within the nomic task-prefix invariant.
    vectors = embed.embed_documents(
        [f"{c.heading}\n{c.text}" if c.heading else c.text for c in chunks]
    )
    rows = [(c.path, c.heading, c.text, mtime, c.chunk_index) for c in chunks]
    store.upsert_chunks(db, rows, vectors)
    db.commit()
    return len(chunks)


def build(full: bool = False) -> None:
    db = store.connect()
    files = iter_notes() + iter_external()      # vault notes + configured external roots
    on_disk = {path_id(p) for p in files}

    if full:
        # Full reset, but only of paths this run reconciles — so `build --full`
        # without CORTEX_EXTRA_ROOTS set rebuilds the vault without nuking an
        # external index built under a different (root-configured) invocation.
        for path in store.all_paths(db):
            if _belongs_to_reconciled(path):
                store.delete_path(db, path)
        db.commit()
    else:
        # Prune files that vanished from disk (within reconciled roots only).
        for stale in store.all_paths(db) - on_disk:
            if _belongs_to_reconciled(stale):
                store.delete_path(db, stale)
        db.commit()

    total = 0
    ext_n = len(config.EXTRA_ROOTS)
    for i, path in enumerate(files, 1):
        try:
            n = index_file(db, path, force=full)
        except Exception as e:  # one bad file shouldn't kill the whole run
            print(f"  ! skip {path.name}: {e}", file=sys.stderr)
            continue
        if n:
            total += n
            print(f"  [{i}/{len(files)}] {path.name}: {n} chunks")
    s = store.stats(db)
    extra = f" ({s.get('external', 0)} external from {ext_n} root(s))" if ext_n else ""
    print(f"\nDone. {s['notes']} files / {s['chunks']} chunks indexed (+{total} this run){extra}.")
    print(f"DB: {s['db']}")


def search(query: str, k: int) -> None:
    db = store.connect()
    qvec = embed.embed_query(query)
    for h in store.search(db, qvec, k):
        loc = f"{h.path}" + (f"  ›  {h.heading}" if h.heading else "")
        snippet = " ".join(h.text.split())[:200]
        print(f"\n[{h.score:.3f}] {loc}\n    {snippet}")


def main(argv=None) -> int:
    p = argparse.ArgumentParser(prog="cortex.index")
    sub = p.add_subparsers(dest="cmd", required=True)

    b = sub.add_parser("build", help="index new/changed notes")
    b.add_argument("--full", action="store_true", help="wipe and re-embed everything")

    s = sub.add_parser("search", help="semantic search")
    s.add_argument("query")
    s.add_argument("-k", type=int, default=8)

    sub.add_parser("stats", help="show index stats")

    args = p.parse_args(argv)
    if args.cmd == "build":
        build(full=args.full)
    elif args.cmd == "search":
        search(args.query, args.k)
    elif args.cmd == "stats":
        print(store.stats(store.connect()))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
