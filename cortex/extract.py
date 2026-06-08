"""Turn a file into indexable text. Markdown/plain text and source code are read
verbatim; PDFs go through pypdf. Binary / unsupported types return None and are
skipped. This is what lets Cortex index a papers folder or a project's codebase
(via CORTEX_EXTRA_ROOTS) alongside the markdown vault, not just `.md`.
"""
from __future__ import annotations

from pathlib import Path

# Read-as-is: plain text / markup / source code / config. The generic text chunker
# windows these; only markdown gets the heading-aware chunker.
TEXT_EXTS = {
    ".md", ".markdown", ".txt", ".rst", ".org", ".tex", ".bib",
    ".py", ".pyi", ".js", ".ts", ".tsx", ".jsx", ".mjs", ".cjs",
    ".swift", ".go", ".rs", ".java", ".kt", ".scala", ".dart",
    ".c", ".cc", ".cpp", ".cxx", ".h", ".hpp", ".m", ".mm",
    ".rb", ".php", ".pl", ".lua", ".r", ".jl", ".ex", ".exs",
    ".sh", ".bash", ".zsh", ".fish", ".ps1",
    ".sql", ".graphql", ".proto",
    ".json", ".jsonc", ".yaml", ".yml", ".toml", ".ini", ".cfg", ".conf",
    ".html", ".htm", ".css", ".scss", ".sass", ".less", ".vue", ".svelte",
    ".gradle", ".cmake", ".dockerfile",
}


def is_markdown(path: Path) -> bool:
    return path.suffix.lower() in (".md", ".markdown")


def is_supported(path: Path) -> bool:
    s = path.suffix.lower()
    return s == ".pdf" or s in TEXT_EXTS


def extract_text(path: Path) -> str | None:
    """Indexable text for a file, or None to skip it."""
    s = path.suffix.lower()
    if s == ".pdf":
        return _pdf_text(path)
    if s in TEXT_EXTS:
        try:
            return path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            return None
    return None


def _pdf_text(path: Path) -> str | None:
    try:
        from pypdf import PdfReader
    except ImportError:
        return None                       # pypdf optional — skip PDFs gracefully if absent
    try:
        reader = PdfReader(str(path))
        parts = []
        for page in reader.pages:
            try:
                t = page.extract_text() or ""
            except Exception:             # noqa: BLE001 — a bad page shouldn't kill the file
                t = ""
            if t.strip():
                parts.append(t)
        return "\n\n".join(parts) or None
    except Exception:                     # noqa: BLE001 — encrypted/corrupt PDF → skip
        return None
