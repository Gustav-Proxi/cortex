"""Research-workflow helpers: surface upcoming deadlines from STATE.md, and
suggest [[wikilinks]] for semantically-near but unlinked notes.
"""
from __future__ import annotations

import re
from datetime import date, datetime, timedelta

from . import embed, store, vault

_ISO = re.compile(r"\b(\d{4}-\d{2}-\d{2})\b")
# Month-name dates as STATE.md actually writes them: "May 31", "Jun 7", "Sep 24, 2026".
_MON = re.compile(
    r"\b(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\.?\s+(\d{1,2})(?:,?\s+(\d{4}))?\b"
)
_MONTHS = {m: i for i, m in enumerate(
    ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"], 1)}


def _dates_in(line: str, today: date) -> list[date]:
    found = []
    for m in _ISO.finditer(line):
        try:
            found.append(datetime.strptime(m.group(1), "%Y-%m-%d").date())
        except ValueError:
            pass
    for m in _MON.finditer(line):
        mon = _MONTHS[m.group(1).lower()]
        year = int(m.group(3)) if m.group(3) else today.year
        try:
            d = date(year, mon, int(m.group(2)))
        except ValueError:
            continue
        # No explicit year + well in the past -> it means next year's instance.
        if not m.group(3) and d < today - timedelta(days=120):
            try:
                d = date(year + 1, mon, int(m.group(2)))
            except ValueError:
                pass
        found.append(d)
    return found


def upcoming_deadlines(days_ahead: int = 21, source: str = "STATE.md") -> list[dict]:
    """Dated gates/deadlines in `source` (default STATE.md) within
    [today-3d, today+days_ahead], soonest first. Reads both ISO (2026-06-07) and
    month-name ("Jun 7", "Sep 24, 2026") forms. Small backward window keeps a
    just-missed gate from vanishing."""
    try:
        text = vault.read_note(source)
    except vault.VaultError:
        return []
    today = date.today()
    lo, hi = today - timedelta(days=3), today + timedelta(days=days_ahead)
    out, seen = [], set()
    for line in text.splitlines():
        ctx = re.sub(r"\s+", " ", line).strip().strip("|").strip()
        for d in _dates_in(line, today):
            if lo <= d <= hi and (d.isoformat(), ctx) not in seen:
                seen.add((d.isoformat(), ctx))
                out.append({"date": d.isoformat(), "in_days": (d - today).days, "context": ctx[:200]})
    out.sort(key=lambda x: x["in_days"])
    return out


def suggest_links(path: str, k: int = 8) -> list[dict]:
    """Notes semantically near `path` that it does NOT already link to —
    candidates for [[wikilinks]] (supports the 'every note should connect' habit)."""
    text = vault.read_note(path)
    linked = set(vault.outgoing_links(path))
    hits = store.search(store.connect(), embed.embed_query(text[:4000]), k + 12)
    out, seen = [], set()
    for h in hits:
        if h.path == path:
            continue
        stem = h.path.rsplit("/", 1)[-1]
        stem = stem[:-3] if stem.endswith(".md") else stem
        if stem in linked or stem in seen:
            continue
        seen.add(stem)
        out.append({"note": h.path, "wikilink": f"[[{stem}]]", "score": round(h.score, 4)})
        if len(out) >= k:
            break
    return out
