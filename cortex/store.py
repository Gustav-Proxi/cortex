"""sqlite-vec vector store.

One file, two tables:
  - chunks: metadata (path, heading, text, file mtime, chunk index)
  - vec_chunks: vec0 virtual table holding the float[768] vectors, keyed by the
    same rowid as chunks.id so a KNN hit joins straight back to its note.

Re-indexing a note deletes its old rows first, so the store always reflects the
current file (no stale chunks after an edit).
"""
from __future__ import annotations

import re
import sqlite3
import struct
from dataclasses import dataclass

import sqlite_vec

from . import config


@dataclass
class Hit:
    path: str
    heading: str
    text: str
    score: float  # similarity in (0, 1] via 1/(1+L2); hybrid uses an RRF score


def _serialize(vec: list[float]) -> bytes:
    return struct.pack(f"{len(vec)}f", *vec)


def connect() -> sqlite3.Connection:
    config.ensure_dirs()
    # Several processes hit this DB at once (watcher, MCP server, CLI). WAL lets
    # readers and the one writer coexist, and the busy timeout makes a writer
    # wait for a lock instead of failing with "database is locked".
    db = sqlite3.connect(str(config.DB_PATH), timeout=30.0)
    db.execute("PRAGMA busy_timeout=30000")
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA synchronous=NORMAL")  # WAL-safe; fewer fsyncs under concurrent writers
    db.enable_load_extension(True)
    sqlite_vec.load(db)
    db.enable_load_extension(False)
    db.execute(
        """
        CREATE TABLE IF NOT EXISTS chunks (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            path TEXT NOT NULL,
            heading TEXT,
            text TEXT NOT NULL,
            mtime REAL NOT NULL,
            chunk_index INTEGER NOT NULL
        )
        """
    )
    db.execute("CREATE INDEX IF NOT EXISTS idx_chunks_path ON chunks(path)")
    db.execute(
        f"CREATE VIRTUAL TABLE IF NOT EXISTS vec_chunks "
        f"USING vec0(embedding float[{config.EMBED_DIM}])"
    )
    # Full-text (BM25) index over chunk text, kept in lockstep with `chunks` via
    # triggers — powers hybrid (keyword + vector) search.
    db.execute(
        "CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts "
        "USING fts5(text, content='chunks', content_rowid='id')"
    )
    db.execute(
        "CREATE TRIGGER IF NOT EXISTS chunks_ai AFTER INSERT ON chunks BEGIN "
        "INSERT INTO chunks_fts(rowid, text) VALUES (new.id, new.text); END"
    )
    db.execute(
        "CREATE TRIGGER IF NOT EXISTS chunks_ad AFTER DELETE ON chunks BEGIN "
        "INSERT INTO chunks_fts(chunks_fts, rowid, text) VALUES('delete', old.id, old.text); END"
    )
    db.commit()
    # Backfill FTS for chunks indexed before it existed (no re-embed needed).
    if (db.execute("SELECT count(*) FROM chunks_fts").fetchone()[0] == 0
            and db.execute("SELECT count(*) FROM chunks").fetchone()[0]):
        db.execute("INSERT INTO chunks_fts(rowid, text) SELECT id, text FROM chunks")
        db.commit()
    return db


def file_mtime(db: sqlite3.Connection, path: str) -> float | None:
    row = db.execute("SELECT mtime FROM chunks WHERE path = ? LIMIT 1", (path,)).fetchone()
    return row[0] if row else None


def delete_path(db: sqlite3.Connection, path: str) -> None:
    ids = [r[0] for r in db.execute("SELECT id FROM chunks WHERE path = ?", (path,))]
    if ids:
        qmarks = ",".join("?" * len(ids))
        db.execute(f"DELETE FROM vec_chunks WHERE rowid IN ({qmarks})", ids)
        db.execute("DELETE FROM chunks WHERE path = ?", (path,))


def upsert_chunks(db: sqlite3.Connection, rows: list[tuple], vectors: list[list[float]]) -> None:
    """rows: (path, heading, text, mtime, chunk_index). Caller deletes path first."""
    for (path, heading, text, mtime, idx), vec in zip(rows, vectors):
        cur = db.execute(
            "INSERT INTO chunks (path, heading, text, mtime, chunk_index) VALUES (?,?,?,?,?)",
            (path, heading, text, mtime, idx),
        )
        db.execute(
            "INSERT INTO vec_chunks (rowid, embedding) VALUES (?, ?)",
            (cur.lastrowid, _serialize(vec)),
        )


def search(db: sqlite3.Connection, query_vec: list[float], k: int = 8) -> list[Hit]:
    rows = db.execute(
        """
        SELECT c.path, c.heading, c.text, v.distance
        FROM vec_chunks v
        JOIN chunks c ON c.id = v.rowid
        WHERE v.embedding MATCH ? AND k = ?
        ORDER BY v.distance
        """,
        (_serialize(query_vec), k),
    ).fetchall()
    # vec0 default distance is L2; convert to a friendly similarity score.
    hits = []
    for path, heading, text, dist in rows:
        hits.append(Hit(path=path, heading=heading or "", text=text,
                        score=1.0 / (1.0 + max(0.0, dist))))
    return hits


def _fts_query(text: str) -> str:
    """Free text -> a safe FTS5 MATCH expression (OR of quoted terms)."""
    return " OR ".join(f'"{t}"' for t in re.findall(r"\w+", text))


def search_hybrid(db: sqlite3.Connection, query_text: str, query_vec: list[float],
                  k: int = 8) -> list[Hit]:
    """Reciprocal-rank fusion of vector (semantic) + FTS5 (keyword) results, so
    exact terms/names rank alongside meaning. Hit.score is the RRF weight here,
    not a similarity."""
    pool = max(k * 4, 20)
    vrows = db.execute(
        "SELECT rowid FROM vec_chunks WHERE embedding MATCH ? AND k = ? ORDER BY distance",
        (_serialize(query_vec), pool),
    ).fetchall()
    frows = []
    fq = _fts_query(query_text)
    if fq:
        try:
            frows = db.execute(
                "SELECT rowid FROM chunks_fts WHERE chunks_fts MATCH ? ORDER BY rank LIMIT ?",
                (fq, pool),
            ).fetchall()
        except sqlite3.OperationalError:
            frows = []
    C = 60.0
    scores: dict[int, float] = {}
    for rank, (rid,) in enumerate(vrows):
        scores[rid] = scores.get(rid, 0.0) + 1.0 / (C + rank)
    for rank, (rid,) in enumerate(frows):
        scores[rid] = scores.get(rid, 0.0) + 1.0 / (C + rank)
    if not scores:
        return []
    top = sorted(scores, key=scores.get, reverse=True)[:k]
    qmarks = ",".join("?" * len(top))
    byid = {
        row[0]: row
        for row in db.execute(
            f"SELECT id, path, heading, text FROM chunks WHERE id IN ({qmarks})", top
        )
    }
    out = []
    for rid in top:
        row = byid.get(rid)
        if row:
            _, path, heading, text = row
            out.append(Hit(path=path, heading=heading or "", text=text, score=round(scores[rid], 4)))
    return out


def all_paths(db: sqlite3.Connection) -> set[str]:
    return {r[0] for r in db.execute("SELECT DISTINCT path FROM chunks")}


def stats(db: sqlite3.Connection) -> dict:
    n_chunks = db.execute("SELECT COUNT(*) FROM chunks").fetchone()[0]
    n_notes = db.execute("SELECT COUNT(DISTINCT path) FROM chunks").fetchone()[0]
    return {"notes": n_notes, "chunks": n_chunks, "db": str(config.DB_PATH)}
