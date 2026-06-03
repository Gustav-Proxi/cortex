"""Literature helpers — resolve a DOI or arXiv id to paper metadata, and format
it as APA + BibTeX. Network via stdlib urllib (CrossRef + arXiv public APIs).
"""
from __future__ import annotations

import json
import os
import re
import urllib.error
import urllib.parse
import urllib.request
from xml.etree import ElementTree as ET

_ARXIV = re.compile(r"(\d{4}\.\d{4,5})(?:v\d+)?")
# CrossRef/arXiv "polite pool" contact. Defaults to the project URL (no personal
# data); set CORTEX_CONTACT_EMAIL to use a mailto and get polite-pool treatment.
_CONTACT = os.environ.get("CORTEX_CONTACT_EMAIL", "")
_UA = (
    f"cortex/0.1 (mailto:{_CONTACT})" if _CONTACT
    else "cortex/0.1 (+https://github.com/Gustav-Proxi/cortex)"
)


def _get(url: str, accept: str = "application/json", timeout: int = 20) -> bytes:
    req = urllib.request.Request(url, headers={"Accept": accept, "User-Agent": _UA})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def _from_crossref(doi: str) -> dict:
    data = json.loads(_get(f"https://api.crossref.org/works/{urllib.parse.quote(doi)}"))
    m = data["message"]
    authors = [
        f"{a.get('family', '')}, {a.get('given', '')[:1]}." for a in m.get("author", []) if a.get("family")
    ]
    year = None
    for key in ("published-print", "published-online", "issued", "created"):
        parts = m.get(key, {}).get("date-parts", [[None]])
        if parts and parts[0] and parts[0][0]:
            year = parts[0][0]
            break
    return {
        "id": doi, "type": "doi",
        "title": (m.get("title") or [""])[0],
        "authors": authors, "year": year,
        "venue": (m.get("container-title") or [""])[0],
        "doi": m.get("DOI"), "url": m.get("URL"),
    }


def _from_arxiv(arxiv_id: str) -> dict:
    raw = _get(f"http://export.arxiv.org/api/query?id_list={arxiv_id}", accept="application/atom+xml")
    ns = {"a": "http://www.w3.org/2005/Atom"}
    entry = ET.fromstring(raw).find("a:entry", ns)
    if entry is None:
        raise ValueError(f"arXiv id not found: {arxiv_id}")
    title = re.sub(r"\s+", " ", (entry.findtext("a:title", default="", namespaces=ns) or "").strip())
    authors = []
    for a in entry.findall("a:author", ns):
        nm = (a.findtext("a:name", default="", namespaces=ns) or "").strip().split()
        if nm:
            authors.append(f"{nm[-1]}, {nm[0][:1]}.")
    pub = entry.findtext("a:published", default="", namespaces=ns) or ""
    return {
        "id": arxiv_id, "type": "arxiv",
        "title": title, "authors": authors,
        "year": int(pub[:4]) if pub[:4].isdigit() else None,
        "venue": f"arXiv:{arxiv_id}", "doi": None,
        "url": f"https://arxiv.org/abs/{arxiv_id}",
    }


def lookup(identifier: str) -> dict:
    """DOI or arXiv id/URL -> metadata + APA + BibTeX (or {error})."""
    ident = identifier.strip()
    is_doi = ident.startswith("10.") or "doi.org/" in ident.lower()
    am = _ARXIV.search(ident.lower().replace("arxiv:", ""))
    try:
        if is_doi:
            doi = ident.split("doi.org/")[-1] if "doi.org/" in ident.lower() else ident
            meta = _from_crossref(doi)
        elif am:
            meta = _from_arxiv(am.group(1))
        else:
            meta = _from_crossref(ident)  # last resort: treat as a bare DOI
    except (urllib.error.URLError, ValueError, KeyError, json.JSONDecodeError) as e:
        return {"error": f"lookup failed for {identifier!r}: {e}"}
    meta["apa"] = _apa(meta)
    meta["bibtex"] = _bibtex(meta)
    return meta


def _apa(m: dict) -> str:
    authors = ", ".join(m["authors"]) if m["authors"] else "Unknown"
    year = m["year"] or "n.d."
    title = (m["title"] or "").rstrip(".")
    venue = m.get("venue") or ""
    tail = f" https://doi.org/{m['doi']}" if m.get("doi") else (f" {m['url']}" if m.get("url") else "")
    return f"{authors} ({year}). {title}. {venue}.{tail}".strip()


def _bibtex(m: dict) -> str:
    first = (m["authors"][0].split(",")[0] if m["authors"] else "unknown").lower()
    key = re.sub(r"\W", "", first) + str(m["year"] or "")
    fields = [
        f"  title={{{m['title']}}}",
        f"  author={{{' and '.join(m['authors'])}}}",
        f"  year={{{m['year'] or ''}}}",
    ]
    if m.get("venue"):
        fields.append(f"  journal={{{m['venue']}}}")
    if m.get("doi"):
        fields.append(f"  doi={{{m['doi']}}}")
    if m.get("url"):
        fields.append(f"  url={{{m['url']}}}")
    kind = "misc" if m["type"] == "arxiv" else "article"
    return f"@{kind}{{{key},\n" + ",\n".join(fields) + "\n}"
