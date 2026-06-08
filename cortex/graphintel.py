"""Graph intelligence over the vault's wiki-link + semantic graph — graphify-style
analytics, but on *notes* and fused with Cortex's embeddings:

    shortest_path · hubs ('god nodes') · communities · bridges (semantic-close but
    unlinked, ideally cross-cluster) · export (mermaid/graphml/cypher/json) · overview

Pure-Python over `vault.link_graph()` + the existing embedding store — no new deps.
"""
from __future__ import annotations

import json
from collections import defaultdict, deque
from pathlib import Path

from . import embed, store, vault


# --- graph plumbing ----------------------------------------------------------

def _graph():
    """(nodes: {id: meta}, adj: {id: set[id]} undirected, edges: [{source,target}])."""
    g = vault.link_graph()
    nodes = {n["id"]: n for n in g["nodes"]}
    adj: dict[str, set] = defaultdict(set)
    for e in g["edges"]:
        adj[e["source"]].add(e["target"])
        adj[e["target"]].add(e["source"])          # undirected for analytics
    for nid in nodes:
        adj.setdefault(nid, set())
    return nodes, adj, g["edges"]


def _stem(nid: str) -> str:
    return Path(nid).stem


def _resolve(name: str, nodes: dict) -> str | None:
    if name in nodes:
        return name
    s = Path(name).stem.lower()
    for nid in nodes:
        if Path(nid).stem.lower() == s:
            return nid
    return None


# --- shortest path -----------------------------------------------------------

def shortest_path(a: str, b: str) -> dict:
    """Fewest [[wikilink]] hops between two notes (BFS, undirected)."""
    nodes, adj, _ = _graph()
    sa, sb = _resolve(a, nodes), _resolve(b, nodes)
    if not sa:
        return {"error": f"unknown note: {a}"}
    if not sb:
        return {"error": f"unknown note: {b}"}
    prev = {sa: None}
    q = deque([sa])
    while q:
        cur = q.popleft()
        if cur == sb:
            break
        for nb in sorted(adj[cur]):
            if nb not in prev:
                prev[nb] = cur
                q.append(nb)
    if sb not in prev:
        return {"from": sa, "to": sb, "path": None, "hops": None,
                "note": "no [[wikilink]] path connects these notes"}
    path = []
    cur: str | None = sb
    while cur is not None:
        path.append(cur)
        cur = prev[cur]
    path.reverse()
    return {"from": sa, "to": sb, "hops": len(path) - 1,
            "path": [_stem(p) for p in path], "path_ids": path}


# --- hubs / 'god nodes' ------------------------------------------------------

def hubs(k: int = 15) -> list[dict]:
    """The most-connected notes — the gravitational centres of the vault."""
    nodes, adj, _ = _graph()
    deg = sorted(((nid, len(adj[nid])) for nid in nodes), key=lambda x: (-x[1], x[0]))
    return [{"id": nid, "label": _stem(nid), "degree": d, "domain": nodes[nid].get("domain")}
            for nid, d in deg[:k] if d > 0]


# --- communities (label propagation) ----------------------------------------

# Navigational notes that link to *everything* (tables of contents) — they must not
# drive topical clustering, or the whole vault collapses into one community.
_META_STEMS = {"index", "state", "critical_facts", "claude", "handoff"}


def _is_meta(nid: str, nodes: dict) -> bool:
    if (nodes[nid].get("type") or "") in ("folder-index", "state", "handoff"):
        return True
    return Path(nid).stem.lower() in _META_STEMS


def _label_communities(active: set, adj: dict) -> dict[str, int]:
    """Deterministic label propagation over `active` notes → {note_id: label}."""
    label = {nid: i for i, nid in enumerate(sorted(active))}
    for _ in range(30):
        changed = False
        for nid in sorted(active):
            counts: dict[int, int] = defaultdict(int)
            for nb in adj[nid]:
                if nb in label:                    # only count active neighbours
                    counts[label[nb]] += 1
            if not counts:
                continue
            best = min(counts.items(), key=lambda kv: (-kv[1], kv[0]))[0]   # most common, tie → smallest
            if label[nid] != best:
                label[nid] = best
                changed = True
        if not changed:
            break
    return label


def _community_map(nodes: dict, adj: dict) -> tuple[dict[str, int], list[list[str]]]:
    active = {nid for nid in nodes if adj[nid] and not _is_meta(nid, nodes)}
    label = _label_communities(active, adj)
    groups: dict[int, list[str]] = defaultdict(list)
    for nid, lb in label.items():
        groups[lb].append(nid)
    clusters = sorted(groups.values(), key=lambda g: (-len(g), g[0]))
    by_node = {nid: i for i, members in enumerate(clusters) for nid in members}
    return by_node, clusters


def communities() -> dict:
    """Cluster the vault into communities of densely-linked notes."""
    nodes, adj, _ = _graph()
    _, clusters = _community_map(nodes, adj)
    out = []
    for i, members in enumerate(clusters):
        hub = max(members, key=lambda nid: len(adj[nid]))
        doms = defaultdict(int)
        for m in members:
            d = nodes[m].get("domain")
            if d:
                doms[d] += 1
        out.append({"id": i, "size": len(members), "hub": _stem(hub),
                    "top_domain": (max(doms, key=doms.get) if doms else None),
                    "members": [_stem(m) for m in members]})
    return {"count": len(out), "clusters": out}


# --- semantic bridges (Cortex × graphify) -----------------------------------

def _semantic_pairs(per_note: int, min_score: float):
    db = store.connect()
    seen, pairs = set(), []
    for rel in vault.list_notes(None, None):
        try:
            text = vault.read_note(rel)
        except vault.VaultError:
            continue
        for h in store.search(db, embed.embed_query(text[:4000]), per_note + 1):
            if h.path == rel or h.path.startswith("/") or (min_score and h.score < min_score):
                continue
            a, b = (rel, h.path) if rel < h.path else (h.path, rel)
            if (a, b) in seen:
                continue
            seen.add((a, b))
            pairs.append((a, b, round(h.score, 4)))
    return pairs


def bridges(k: int = 20, min_score: float = 0.0) -> list[dict]:
    """Surprising connections: notes that read as related (high embedding similarity)
    but are NOT [[wikilinked]] — prioritising pairs that sit in *different* clusters.
    These are the candidate cross-pollinations a knowledge base usually misses."""
    nodes, adj, _ = _graph()
    comm, _ = _community_map(nodes, adj)
    out = []
    for a, b, score in _semantic_pairs(per_note=4, min_score=min_score):
        if b in adj.get(a, ()):                    # already linked — not surprising
            continue
        ca, cb = comm.get(a), comm.get(b)
        cross = ca is not None and cb is not None and ca != cb
        out.append({"a": _stem(a), "b": _stem(b), "score": score, "cross_cluster": cross})
    out.sort(key=lambda x: (not x["cross_cluster"], -x["score"]))
    return out[:k]


# --- exports -----------------------------------------------------------------

def export(fmt: str = "mermaid") -> str:
    nodes, adj, edges = _graph()
    fmt = (fmt or "mermaid").lower()
    nid = {n: f"n{i}" for i, n in enumerate(nodes)}

    if fmt == "mermaid":
        lines = ["graph LR"]
        for e in edges:
            lines.append(f'  {nid[e["source"]]}["{_stem(e["source"])}"] --> '
                         f'{nid[e["target"]]}["{_stem(e["target"])}"]')
        return "\n".join(lines)

    if fmt == "cypher":
        out = []
        for n, i in nid.items():
            lab = _stem(n).replace("'", "\\'")
            dom = (nodes[n].get("domain") or "").replace("'", "\\'")
            out.append(f"CREATE ({i}:Note {{name:'{lab}', path:'{n}', domain:'{dom}'}})")
        for e in edges:
            out.append(f'CREATE ({nid[e["source"]]})-[:LINKS_TO]->({nid[e["target"]]})')
        return "\n".join(out) + ";"

    if fmt == "graphml":
        out = ['<?xml version="1.0" encoding="UTF-8"?>',
               '<graphml xmlns="http://graphml.graphdrawing.org/xmlns">',
               '  <key id="label" for="node" attr.name="label" attr.type="string"/>',
               '  <key id="domain" for="node" attr.name="domain" attr.type="string"/>',
               '  <graph edgedefault="directed">']
        for n, i in nid.items():
            lab = _xml(_stem(n)); dom = _xml(nodes[n].get("domain") or "")
            out.append(f'    <node id="{i}"><data key="label">{lab}</data>'
                       f'<data key="domain">{dom}</data></node>')
        for j, e in enumerate(edges):
            out.append(f'    <edge id="e{j}" source="{nid[e["source"]]}" target="{nid[e["target"]]}"/>')
        out += ['  </graph>', '</graphml>']
        return "\n".join(out)

    if fmt == "json":
        return json.dumps({"nodes": [{"id": n, "label": _stem(n), **{k: nodes[n].get(k) for k in ("domain", "status", "type")}} for n in nodes],
                           "edges": edges}, indent=2, ensure_ascii=False)

    return f"unknown format: {fmt} (use mermaid|cypher|graphml|json)"


def _xml(s: str) -> str:
    return (s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
             .replace('"', "&quot;"))


# --- overview ('GRAPH_REPORT') ----------------------------------------------

def overview() -> dict:
    """A one-shot read of the vault's shape: size, hubs, communities, orphans, bridges."""
    nodes, adj, edges = _graph()
    orphans = sorted(_stem(nid) for nid in nodes if not adj[nid])
    _, clusters = _community_map(nodes, adj)
    return {
        "notes": len(nodes),
        "links": len(edges),
        "communities": len(clusters),
        "orphans": orphans,
        "top_hubs": hubs(8),
        "largest_communities": [{"hub": _stem(max(c, key=lambda n: len(adj[n]))), "size": len(c)}
                                for c in clusters[:5]],
        "surprising_bridges": bridges(6),
    }
