"""In-house vault operations — the headless half of the "one brain".

Everything the old Obsidian plugins did over their REST API, done by reading and
writing the vault's markdown directly: file CRUD, listing, frontmatter, the
wiki-link graph, text + property search, templates, daily notes, and a gated
shell-exec escape hatch. No Obsidian process is required.

The *only* things deliberately absent are live-UI actions (open a note in the
running app, fire an Obsidian command, read the unsaved editor buffer) — those
genuinely need the client and can't be done from disk.

Path safety: every path crossing the API is vault-relative and runs through
`resolve()`, which refuses anything escaping the vault root (no `..`, no abs).
"""
from __future__ import annotations

import fnmatch
import os
import re
import shutil
import stat
import subprocess
import tempfile
from dataclasses import dataclass
from datetime import date, datetime
from io import StringIO
from pathlib import Path

import yaml
from ruamel.yaml import YAML as _RoundTripYAML

from . import config


class VaultError(RuntimeError):
    """Raised for unsafe paths or impossible operations (surfaced to the client)."""


# --- path safety -------------------------------------------------------------

def resolve(rel: str) -> Path:
    """Vault-relative path -> absolute Path, guaranteed inside the vault root."""
    cleaned = (rel or "").strip().lstrip("/")
    if not cleaned:
        raise VaultError("empty path")
    root = config.VAULT_PATH.resolve()
    full = (root / cleaned).resolve()
    if full != root and root not in full.parents:
        raise VaultError(f"path escapes the vault: {rel!r}")
    return full


def rel_of(p: Path) -> str:
    return str(p.resolve().relative_to(config.VAULT_PATH.resolve()))


def _ignored(rel: str) -> bool:
    return any(fnmatch.fnmatch(rel, pat) for pat in config.IGNORE_GLOBS)


def _ensure_allowed(rel: str) -> None:
    """Refuse ops on ignored/protected areas (.obsidian, .trash, .smart-env, …).
    Confines the tools/API to real notes — never config or plugin code, even
    though resolve() would otherwise allow them (they're inside the vault)."""
    if _ignored((rel or "").strip().lstrip("/")):
        raise VaultError(f"path is in a protected/ignored area: {rel}")


# --- safe write primitives ---------------------------------------------------

def _atomic_write(full: Path, content: str) -> None:
    """Write `content` to `full` atomically and durably: a temp file in the same
    directory, flushed and fsync'd, then `os.replace`d into place (atomic on
    POSIX), then the parent directory fsync'd so the rename survives a crash. A
    reader (or a crash) sees either the old complete file or the new complete
    file — never a torn or truncated note.

    The temp name is a dotfile ending in `.tmp` (not `*.md`), so the watcher and
    the indexer both ignore it; only the final `os.replace` surfaces.
    """
    full.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(full.parent), prefix=f".{full.name}.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(content)
            f.flush()
            os.fsync(f.fileno())
        # Preserve the prior file's mode on overwrite — os.replace swaps in a new
        # inode, so without this a note deliberately chmod'd 0600 would silently
        # revert to 0644. New files default to 0644.
        try:
            os.chmod(tmp, stat.S_IMODE(full.stat().st_mode) if full.exists() else 0o644)
        except OSError:
            pass
        os.replace(tmp, full)
        # Make the rename itself durable (best-effort; some platforms disallow
        # fsync on a directory fd).
        try:
            dfd = os.open(str(full.parent), os.O_RDONLY)
            try:
                os.fsync(dfd)
            finally:
                os.close(dfd)
        except OSError:
            pass
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _to_trash(full: Path, *, move: bool) -> str:
    """Put `full` into the vault's .trash for recoverability, mirroring its
    vault-relative path and de-duplicating the name (`note.1.md`, …) so a prior
    trashed version is never clobbered. `move=True` for a delete (the original
    goes away), `move=False` to leave a backup copy before an overwrite.
    Returns the trash destination's vault-relative path.
    """
    root = config.VAULT_PATH.resolve()
    rel = full.resolve().relative_to(root)
    dest = root / config.TRASH_DIR / rel
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists():
        stem, suffix, i = dest.stem, dest.suffix, 1
        while True:
            cand = dest.with_name(f"{stem}.{i}{suffix}")
            if not cand.exists():
                dest = cand
                break
            i += 1
    if move:
        os.replace(str(full), str(dest))
    else:
        shutil.copy2(str(full), str(dest))
    return str(dest.relative_to(root))


def iter_notes(folder: str | None = None):
    """Yield vault-relative paths of all non-ignored markdown notes."""
    base = resolve(folder) if folder else config.VAULT_PATH
    if not base.exists():
        return
    root = config.VAULT_PATH.resolve()
    for p in sorted(base.rglob("*.md")):
        # Lexical (un-resolved) vault-relative path: lets IGNORE_GLOBS skip
        # .obsidian etc. A symlink whose target escapes the vault (e.g. the
        # plugin symlink → ~/cortex) would make .resolve() throw, so guard it.
        try:
            rel = str(p.relative_to(root))
        except ValueError:
            continue
        if not _ignored(rel):
            yield rel


# --- frontmatter -------------------------------------------------------------

_FM = re.compile(r"^---\n(.*?)\n---\n?", re.DOTALL)
_HEADING = re.compile(r"^(#{1,6})\s+(.*)$", re.MULTILINE)
_WIKILINK = re.compile(r"\[\[([^\]|#]+)(?:[#|][^\]]*)?\]\]")


def split_frontmatter(md: str) -> tuple[dict, str]:
    """Return (frontmatter_dict, body). Empty dict when there's no YAML block."""
    m = _FM.match(md)
    if not m:
        return {}, md
    try:
        data = yaml.safe_load(m.group(1)) or {}
        if not isinstance(data, dict):
            data = {}
    except yaml.YAMLError:
        data = {}
    return data, md[m.end():]


def _join_frontmatter(fm: dict, body: str) -> str:
    if not fm:
        return body
    block = yaml.safe_dump(fm, sort_keys=False, allow_unicode=True).strip()
    return f"---\n{block}\n---\n{body}"


# --- read --------------------------------------------------------------------

def read_note(rel: str) -> str:
    _ensure_allowed(rel)
    full = resolve(rel)
    if not full.exists():
        raise VaultError(f"note not found: {rel}")
    return full.read_text(encoding="utf-8", errors="replace")


def _under_extra_root(p: Path) -> bool:
    rp = p.resolve()
    return any(rp == r or r in rp.parents for r in config.EXTRA_ROOTS)


def read_any(path_id: str) -> str:
    """Read a vault note (vault-relative) OR an indexed external file (an absolute
    path under a configured EXTRA_ROOT — read-only). Search can return external
    hits, so the read tools accept their absolute paths; external files are never
    writable, and only paths actually under a configured root are allowed."""
    cand = (path_id or "").strip()
    if os.path.isabs(cand):
        full = Path(cand).resolve()
        if not _under_extra_root(full):
            raise VaultError(f"path is not under an indexed root: {path_id}")
        if not full.exists():
            raise VaultError(f"file not found: {path_id}")
        return full.read_text(encoding="utf-8", errors="replace")
    return read_note(cand)


def get_section(rel: str, heading: str) -> str:
    """Return the body under the given ATX heading (matched case-insensitively)."""
    md = read_note(rel)
    matches = list(_HEADING.finditer(md))
    want = heading.strip().lower()
    for i, m in enumerate(matches):
        if m.group(2).strip().lower() == want:
            start = m.end()
            end = matches[i + 1].start() if i + 1 < len(matches) else len(md)
            return md[start:end].strip()
    raise VaultError(f"heading {heading!r} not found in {rel}")


def metadata(rel: str) -> dict:
    """Frontmatter + structural stats for a note (no body)."""
    full = resolve(rel)
    if not full.exists():
        raise VaultError(f"note not found: {rel}")
    md = full.read_text(encoding="utf-8", errors="replace")
    fm, body = split_frontmatter(md)
    st = full.stat()
    return {
        "path": rel,
        "frontmatter": fm,
        "headings": [m.group(2).strip() for m in _HEADING.finditer(body)],
        "outgoing_links": sorted(set(_WIKILINK.findall(body))),
        "words": len(body.split()),
        "bytes": st.st_size,
        "modified": datetime.fromtimestamp(st.st_mtime).isoformat(timespec="seconds"),
    }


# --- write / mutate ----------------------------------------------------------

def write_note(rel: str, content: str, overwrite: bool = True) -> dict:
    _ensure_allowed(rel)
    full = resolve(rel)
    existed = full.exists()
    if existed and not overwrite:
        raise VaultError(f"refusing to overwrite (overwrite=False): {rel}")
    if existed and full.read_text(encoding="utf-8", errors="replace") == content:
        # Identical content: skip the .trash backup and the rewrite entirely, so
        # a repeated identical overwrite doesn't churn .trash or trigger a needless
        # re-embed. (.trash is not auto-pruned; this keeps it from filling up.)
        return {"path": rel, "action": "unchanged", "bytes": len(content.encode())}
    res = {"path": rel, "action": "updated" if existed else "created"}
    if existed:  # a full overwrite replaces all prior content — keep a recoverable copy
        res["backup"] = _to_trash(full, move=False)
    _atomic_write(full, content)
    res["bytes"] = len(content.encode())
    return res


def append_note(rel: str, content: str) -> dict:
    _ensure_allowed(rel)
    full = resolve(rel)
    existing = full.read_text(encoding="utf-8", errors="replace") if full.exists() else ""
    sep = "" if (not existing or existing.endswith("\n")) else "\n"
    new = existing + sep + content
    _atomic_write(full, new)
    return {"path": rel, "action": "appended", "bytes": len(new.encode())}


def patch_section(rel: str, heading: str, content: str, mode: str = "append") -> dict:
    """Insert under an ATX heading. mode: append | prepend | replace.

    Creates the heading at end-of-file if it doesn't exist yet.
    """
    if mode not in ("append", "prepend", "replace"):
        raise VaultError(f"bad mode {mode!r} (append|prepend|replace)")
    md = read_note(rel)
    matches = list(_HEADING.finditer(md))
    want = heading.strip().lower()
    target = next((m for m in matches if m.group(2).strip().lower() == want), None)

    if target is None:  # heading absent -> create it at the end
        sep = "" if md.endswith("\n") or not md else "\n"
        md = f"{md}{sep}\n## {heading.strip()}\n\n{content.strip()}\n"
    else:
        idx = matches.index(target)
        body_start = target.end()
        body_end = matches[idx + 1].start() if idx + 1 < len(matches) else len(md)
        section_body = md[body_start:body_end]
        if mode == "replace":
            new_body = f"\n{content.strip()}\n\n"
        elif mode == "prepend":
            new_body = f"\n{content.strip()}\n{section_body.lstrip(chr(10))}"
        else:  # append
            new_body = f"{section_body.rstrip()}\n\n{content.strip()}\n\n"
        md = md[:body_start] + new_body + md[body_end:]

    _atomic_write(resolve(rel), md)
    return {"path": rel, "action": f"patch:{mode}", "heading": heading}


def set_frontmatter(rel: str, key: str, value) -> dict:
    """Set one frontmatter property, preserving the rest of the YAML block's
    formatting and comments (round-tripped via ruamel — no reflow of untouched
    keys)."""
    _ensure_allowed(rel)
    md = read_note(rel)
    m = _FM.match(md)
    if m:
        y = _RoundTripYAML()
        y.preserve_quotes = True
        data = y.load(m.group(1))
        if data is None:
            data = {}
        data[key] = value
        buf = StringIO()
        y.dump(data, buf)
        new_md = f"---\n{buf.getvalue().rstrip(chr(10))}\n---\n{md[m.end():]}"
    else:
        new_md = f"---\n{key}: {value}\n---\n{md}"
    _atomic_write(resolve(rel), new_md)
    return {"path": rel, "action": "frontmatter", "set": {key: value}}


def delete_note(rel: str) -> dict:
    _ensure_allowed(rel)
    full = resolve(rel)
    if not full.exists():
        raise VaultError(f"note not found: {rel}")
    trashed = _to_trash(full, move=True)  # recoverable: moved to .trash, not unlinked
    return {"path": rel, "action": "deleted", "trashed": trashed}


def move_note(src: str, dst: str, update_links: bool = True) -> dict:
    """Move/rename a note. When update_links, rewrite [[wikilinks]] vault-wide —
    both bare `[[Note]]` and path-style `[[folder/Note]]` forms (the trailing
    lookahead also covers `[[Note|alias]]` and `[[Note#heading]]`)."""
    _ensure_allowed(src)
    _ensure_allowed(dst)
    s, d = resolve(src), resolve(dst)
    if not s.exists():
        raise VaultError(f"note not found: {src}")
    if d.exists():
        raise VaultError(f"destination exists: {dst}")
    d.parent.mkdir(parents=True, exist_ok=True)
    s.rename(d)

    rewired = 0
    if update_links:
        forms = []  # (compiled pattern, replacement prefix)
        if Path(src).stem != Path(dst).stem:
            forms.append((re.compile(r"\[\[" + re.escape(Path(src).stem) + r"(?=[\]|#])"),
                          f"[[{Path(dst).stem}"))
        old_path = src[:-3] if src.endswith(".md") else src
        new_path = dst[:-3] if dst.endswith(".md") else dst
        if old_path != new_path:
            forms.append((re.compile(r"\[\[" + re.escape(old_path) + r"(?=[\]|#])"),
                          f"[[{new_path}"))
        if forms:
            for note_rel in iter_notes():
                p = resolve(note_rel)
                txt = p.read_text(encoding="utf-8", errors="replace")
                out, n = txt, 0
                for pat, repl in forms:
                    out, c = pat.subn(repl, out)
                    n += c
                if n:
                    _atomic_write(p, out)
                    rewired += n
    return {"src": src, "dst": dst, "action": "moved", "links_rewired": rewired}


# --- listing / structure -----------------------------------------------------

def list_notes(folder: str | None = None, limit: int | None = None) -> list[str]:
    out = list(iter_notes(folder))
    return out[:limit] if limit else out


def list_folders() -> list[str]:
    root = config.VAULT_PATH.resolve()
    out = []
    for p in sorted(root.rglob("*")):
        if p.is_dir():
            # Lexical relative path so a symlinked dir (e.g. the .obsidian
            # plugin symlink → ~/cortex) is matched by IGNORE_GLOBS and skipped
            # rather than crashing rel_of()'s .resolve().relative_to().
            try:
                rel = str(p.relative_to(root))
            except ValueError:
                continue
            if not _ignored(rel + "/") and not _ignored(rel):
                out.append(rel)
    return out


def vault_stats() -> dict:
    notes = list(iter_notes())
    total_bytes = sum(resolve(r).stat().st_size for r in notes)
    return {
        "vault": str(config.VAULT_PATH),
        "notes": len(notes),
        "bytes": total_bytes,
        "folders": len(list_folders()),
    }


# --- search ------------------------------------------------------------------

@dataclass
class TextHit:
    path: str
    line: int
    text: str


def search_text(query: str, regex: bool = False, case_sensitive: bool = False,
                folder: str | None = None, k: int = 50) -> list[TextHit]:
    """Literal or regex grep across vault markdown. Returns path:line matches."""
    flags = 0 if case_sensitive else re.IGNORECASE
    pat = re.compile(query if regex else re.escape(query), flags)
    hits: list[TextHit] = []
    for rel in iter_notes(folder):
        try:
            text = resolve(rel).read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for i, line in enumerate(text.splitlines(), 1):
            if pat.search(line):
                hits.append(TextHit(path=rel, line=i, text=line.strip()[:200]))
                if len(hits) >= k:
                    return hits
    return hits


def search_frontmatter(field: str, value: str | None = None) -> list[str]:
    """Notes whose frontmatter has `field` (== `value` if given). Great for the
    property-organised vault: type/status/domain live in YAML, not as tags."""
    out = []
    want = None if value is None else str(value).lower()
    for rel in iter_notes():
        fm, _ = split_frontmatter(resolve(rel).read_text(encoding="utf-8", errors="replace"))
        if field not in fm:
            continue
        if want is None:
            out.append(rel)
            continue
        fv = fm[field]
        vals = fv if isinstance(fv, list) else [fv]
        if any(str(v).lower() == want for v in vals):
            out.append(rel)
    return out


# --- wiki-link graph ---------------------------------------------------------

def outgoing_links(rel: str) -> list[str]:
    """[[targets]] this note points to (base names, dedented)."""
    md = read_note(rel)
    _, body = split_frontmatter(md)
    return sorted(set(_WIKILINK.findall(body)))


def backlinks(rel: str) -> list[str]:
    """Notes that link to this one via [[base-name]]."""
    base = Path(rel).stem
    pat = re.compile(r"\[\[" + re.escape(base) + r"(?=[\]|#])")
    out = []
    for other in iter_notes():
        if other == rel:
            continue
        if pat.search(resolve(other).read_text(encoding="utf-8", errors="replace")):
            out.append(other)
    return out


def link_graph() -> dict:
    """Whole-vault wiki-link graph for the UI: every note as a node (with its
    folder + frontmatter type/status/domain/tags for coloring) and one edge per
    resolved [[wikilink]]. Links are resolved by basename (Obsidian-style), so
    both `[[Note]]` and `[[folder/Note]]` land on the same target."""
    notes = list(iter_notes())
    by_stem: dict[str, str] = {}
    for rel in notes:
        by_stem.setdefault(Path(rel).stem, rel)

    nodes, edges, seen = [], [], set()
    for rel in notes:
        md = resolve(rel).read_text(encoding="utf-8", errors="replace")
        fm, body = split_frontmatter(md)
        parent = str(Path(rel).parent)
        tags = fm.get("tags")
        nodes.append({
            "id": rel,
            "label": Path(rel).stem,
            "folder": "" if parent == "." else parent,
            "type": fm.get("type"),
            "status": fm.get("status"),
            "domain": fm.get("domain"),
            "tags": tags if isinstance(tags, list) else ([tags] if tags else []),
        })
        for target in set(_WIKILINK.findall(body)):
            dst = by_stem.get(Path(target).stem)
            if dst and dst != rel and (rel, dst) not in seen:
                seen.add((rel, dst))
                edges.append({"source": rel, "target": dst})
    return {"nodes": nodes, "edges": edges}


# --- templates ---------------------------------------------------------------

def render_template(template_rel: str, variables: dict | None = None) -> str:
    """Read a template note and substitute {{var}} placeholders.

    Built-ins always available: {{date}}, {{time}}, {{datetime}}. Anything in
    `variables` overrides / extends them. Unknown placeholders are left intact.
    """
    text = read_note(template_rel)
    now = datetime.now()
    ctx = {
        "date": now.strftime("%Y-%m-%d"),
        "time": now.strftime("%H:%M"),
        "datetime": now.strftime("%Y-%m-%d %H:%M"),
        **(variables or {}),
    }
    def sub(m):
        key = m.group(1).strip()
        return str(ctx.get(key, m.group(0)))
    return re.sub(r"\{\{\s*([\w-]+)\s*\}\}", sub, text)


def create_from_template(template_rel: str, target_rel: str,
                         variables: dict | None = None, overwrite: bool = False) -> dict:
    content = render_template(template_rel, variables)
    res = write_note(target_rel, content, overwrite=overwrite)
    res["from_template"] = template_rel
    return res


# --- daily / periodic notes --------------------------------------------------

def daily_note_path(when: str | None = None) -> str:
    d = date.today() if not when else datetime.strptime(when, "%Y-%m-%d").date()
    name = d.strftime(config.DAILY_FORMAT) + ".md"
    folder = config.DAILY_FOLDER.strip("/")
    return f"{folder}/{name}" if folder else name


def daily_note(when: str | None = None, template: str | None = None,
               create: bool = True) -> dict:
    """Path to a daily note; create it (optionally from a template) if missing."""
    rel = daily_note_path(when)
    full = resolve(rel)
    if full.exists():
        return {"path": rel, "action": "exists"}
    if not create:
        return {"path": rel, "action": "absent"}
    if template:
        return create_from_template(template, rel, {"date": rel.rsplit("/", 1)[-1][:-3]})
    return write_note(rel, f"# {rel.rsplit('/', 1)[-1][:-3]}\n\n", overwrite=False)


# --- gated shell execution ---------------------------------------------------

def run_command(command: str, cwd: str | None = None) -> dict:
    """Run a shell command — OFF unless CORTEX_ALLOW_EXEC=1 (see config).

    Parity with the plugin's command execution, but opt-in: the gate keeps an
    agent from running arbitrary shell against your machine by default.
    """
    if not config.ALLOW_EXEC:
        raise VaultError(
            "command execution is disabled. Set CORTEX_ALLOW_EXEC=1 in the "
            "server env to enable run_command."
        )
    workdir = resolve(cwd) if cwd else config.VAULT_PATH
    proc = subprocess.run(
        command, shell=True, cwd=str(workdir), capture_output=True,
        text=True, timeout=config.EXEC_TIMEOUT,
    )
    return {
        "command": command,
        "cwd": str(workdir),
        "exit_code": proc.returncode,
        "stdout": proc.stdout[-8000:],
        "stderr": proc.stderr[-4000:],
    }
