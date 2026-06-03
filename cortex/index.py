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
import sys
from pathlib import Path

from . import config, embed, store
from .chunk import chunk_markdown


def _ignored(rel: str) -> bool:
    return any(fnmatch.fnmatch(rel, pat) for pat in config.IGNORE_GLOBS)


def iter_notes() -> list[Path]:
    out = []
    for p in config.VAULT_PATH.rglob("*.md"):
        rel = str(p.relative_to(config.VAULT_PATH))
        if not _ignored(rel):
            out.append(p)
    return out


def index_file(db, path: Path, *, force: bool = False) -> int:
    rel = str(path.relative_to(config.VAULT_PATH))
    mtime = path.stat().st_mtime
    if not force and store.file_mtime(db, rel) == mtime:
        return 0
    chunks = chunk_markdown(rel, path.read_text(encoding="utf-8", errors="replace"))
    store.delete_path(db, rel)
    if not chunks:
        db.commit()
        return 0
    vectors = embed.embed_documents([c.text for c in chunks])
    rows = [(c.path, c.heading, c.text, mtime, c.chunk_index) for c in chunks]
    store.upsert_chunks(db, rows, vectors)
    db.commit()
    return len(chunks)


def build(full: bool = False) -> None:
    db = store.connect()
    if full:
        for path in store.all_paths(db):
            store.delete_path(db, path)
        db.commit()
    notes = iter_notes()
    on_disk = {str(p.relative_to(config.VAULT_PATH)) for p in notes}

    # Prune notes that no longer exist on disk.
    for stale in store.all_paths(db) - on_disk:
        store.delete_path(db, stale)
    db.commit()

    total = 0
    for i, path in enumerate(notes, 1):
        try:
            n = index_file(db, path, force=full)
        except Exception as e:  # one bad note shouldn't kill the whole run
            print(f"  ! skip {path.name}: {e}", file=sys.stderr)
            continue
        if n:
            total += n
            print(f"  [{i}/{len(notes)}] {path.name}: {n} chunks")
    s = store.stats(db)
    print(f"\nDone. {s['notes']} notes / {s['chunks']} chunks indexed (+{total} this run).")
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
