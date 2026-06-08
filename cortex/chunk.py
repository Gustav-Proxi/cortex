"""Markdown -> chunks, heading-aware.

Strategy: strip YAML frontmatter (kept as metadata), walk the note splitting on
ATX headings so each chunk carries its nearest heading path for context, then
pack heading sections into ~CHUNK_CHARS windows with a small overlap so a
sentence straddling a boundary is still retrievable.
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Iterator

from . import config

_FRONTMATTER = re.compile(r"^---\n(.*?)\n---\n", re.DOTALL)
_HEADING = re.compile(r"^(#{1,6})\s+(.*)$", re.MULTILINE)


@dataclass
class Chunk:
    path: str          # vault-relative path
    heading: str       # breadcrumb like "Session State > Mission"
    text: str
    chunk_index: int


def _strip_frontmatter(md: str) -> str:
    return _FRONTMATTER.sub("", md, count=1)


def _sections(md: str) -> Iterator[tuple[str, str]]:
    """Yield (heading_breadcrumb, body_text) sections split on headings."""
    matches = list(_HEADING.finditer(md))
    if not matches:
        yield "", md.strip()
        return

    # Preamble before the first heading.
    if matches[0].start() > 0:
        pre = md[: matches[0].start()].strip()
        if pre:
            yield "", pre

    crumb: list[str] = []
    for i, m in enumerate(matches):
        level = len(m.group(1))
        title = m.group(2).strip()
        crumb = crumb[: level - 1]
        crumb.append(title)
        start = m.end()
        end = matches[i + 1].start() if i + 1 < len(matches) else len(md)
        body = md[start:end].strip()
        breadcrumb = " > ".join(crumb)
        if body:
            yield breadcrumb, body
        else:
            # Heading with no body of its own (parent of subsections); still
            # index the title so the section is discoverable.
            yield breadcrumb, title


def _pack(text: str, size: int, overlap: int) -> Iterator[str]:
    text = text.strip()
    if len(text) <= size:
        if text:
            yield text
        return
    start = 0
    n = len(text)
    while start < n:
        end = min(start + size, n)
        # Prefer to break on a paragraph/sentence boundary near the window edge.
        if end < n:
            window = text[start:end]
            for sep in ("\n\n", "\n", ". "):
                cut = window.rfind(sep)
                if cut > size * 0.5:
                    end = start + cut + len(sep)
                    break
        yield text[start:end].strip()
        if end >= n:
            break
        start = max(end - overlap, start + 1)


def chunk_markdown(path: str, md: str) -> list[Chunk]:
    body = _strip_frontmatter(md)
    out: list[Chunk] = []
    idx = 0
    for breadcrumb, section in _sections(body):
        for piece in _pack(section, config.CHUNK_CHARS, config.CHUNK_OVERLAP):
            if not piece.strip():
                continue
            out.append(Chunk(path=path, heading=breadcrumb, text=piece, chunk_index=idx))
            idx += 1
    return out


def chunk_text(path: str, text: str) -> list[Chunk]:
    """Chunk arbitrary text — PDF text, source code, plain text — with no frontmatter
    or heading parsing (the markdown chunker would mis-split code). Just packs the
    raw text into ~CHUNK_CHARS windows. Used for everything that isn't markdown."""
    out: list[Chunk] = []
    for idx, piece in enumerate(_pack(text, config.CHUNK_CHARS, config.CHUNK_OVERLAP)):
        if piece.strip():
            out.append(Chunk(path=path, heading="", text=piece, chunk_index=idx))
    return out
