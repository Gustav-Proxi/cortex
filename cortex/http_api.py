"""Tiny local JSON HTTP API over the Cortex engine.

The stdio MCP server is the door for Claude. This is the *other* door: a plain
JSON endpoint on loopback so code running INSIDE Obsidian (the Cortex plugin) —
or any local UI — can reach the same search/index without speaking MCP. It's
served in a background thread by the watcher, so there's no extra always-on
process. Loopback only (127.0.0.1).

Endpoints:
  GET  /health                  -> {ok, notes, chunks, db}
  POST /search   {query,k}       -> [{path,heading,text,score}]
  POST /related  {path,k}        -> [{...}]
  GET  /note?path=...            -> {path, content}
  GET  /list?folder=&limit=      -> [paths]
  POST /write   {path,content,overwrite} -> {path, action, bytes}
  POST /append  {path,content}   -> {path, action, bytes}
"""
from __future__ import annotations

import json
import mimetypes
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs

from . import claude, config, embed, store, vault

# The local web UI ("Cortex Desktop", browser-served) lives here and is served
# same-origin with the API below, so the UI's fetches need no CORS relaxation.
WEBAPP_DIR = Path(__file__).resolve().parent.parent / "webapp"


def _hits(hits) -> list[dict]:
    return [
        {"path": h.path, "heading": h.heading, "text": h.text, "score": round(h.score, 4)}
        for h in hits
    ]


class _Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):  # keep the watcher log quiet
        pass

    # --- helpers -------------------------------------------------------------
    def _send(self, code: int, obj) -> None:
        body = json.dumps(obj, default=str, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        # No CORS headers: the only caller is the Obsidian plugin via Electron's
        # requestUrl() (not browser-origin-bound). Wildcard CORS on a loopback API
        # that can read AND write the vault would let any visited webpage reach it.
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_json(self) -> dict:
        n = int(self.headers.get("Content-Length", 0) or 0)
        if not n:
            return {}
        try:
            return json.loads(self.rfile.read(n).decode("utf-8"))
        except json.JSONDecodeError:
            return {}

    # --- routes --------------------------------------------------------------
    def do_GET(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        try:
            if u.path == "/health":
                self._send(200, {"ok": True, **store.stats(store.connect())})
            elif u.path == "/note":
                path = (q.get("path") or [""])[0]
                self._send(200, {"path": path, "content": vault.read_any(path)})
            elif u.path == "/list":
                folder = (q.get("folder") or [""])[0] or None
                limit = int((q.get("limit") or ["0"])[0]) or None
                self._send(200, vault.list_notes(folder, limit))
            elif u.path == "/graph":
                self._send(200, vault.link_graph())
            else:
                self._serve_static(u.path)
        except vault.VaultError as e:
            self._send(400, {"error": str(e)})
        except Exception as e:  # noqa: BLE001 — surface any engine error as JSON
            self._send(500, {"error": str(e)})

    def _serve_static(self, urlpath: str) -> None:
        """Serve the local web UI from WEBAPP_DIR (loopback only). Path-safe:
        nothing outside WEBAPP_DIR is reachable; unknown routes fall back to
        index.html so the single-page app can own client-side routing."""
        if not WEBAPP_DIR.is_dir():
            return self._send(404, {"error": "web UI not installed"})
        rel = urlpath.lstrip("/") or "index.html"
        target = (WEBAPP_DIR / rel).resolve()
        if WEBAPP_DIR not in target.parents or not target.is_file():
            target = WEBAPP_DIR / "index.html"   # SPA fallback
            if not target.is_file():
                return self._send(404, {"error": "not found"})
        data = target.read_bytes()
        ctype = mimetypes.guess_type(str(target))[0] or "application/octet-stream"
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        # Loopback dev server: never cache, so an edit shows up on a plain reload.
        self.send_header("Cache-Control", "no-store, max-age=0")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        u = urlparse(self.path)
        data = self._read_json()
        try:
            if u.path == "/search":
                query = (data.get("query") or "").strip()
                k = int(data.get("k", 8))
                if not query:
                    return self._send(400, {"error": "query required"})
                hits = store.search(store.connect(), embed.embed_query(query), k)
                self._send(200, _hits(hits))
            elif u.path == "/hybrid":
                query = (data.get("query") or "").strip()
                k = int(data.get("k", 8))
                if not query:
                    return self._send(400, {"error": "query required"})
                hits = store.search_hybrid(store.connect(), query, embed.embed_query(query), k)
                self._send(200, _hits(hits))
            elif u.path == "/ask":
                query = (data.get("query") or "").strip()
                k = int(data.get("k", 6))
                if not query:
                    return self._send(400, {"error": "query required"})
                claude_bin = claude.find_claude()
                if not claude_bin:
                    return self._send(200, {"answer": None, "sources": [],
                        "error": "Ask is off: the Claude Code CLI wasn't found. Install Claude Code (or set "
                                 "CORTEX_CLAUDE_BIN). Uses your Claude subscription — no API key."})
                hits = store.search_hybrid(store.connect(), query, embed.embed_query(query), k)
                ctx = "\n\n".join(
                    f"[{i+1}] {h.path}" + (f" › {h.heading}" if h.heading else "") + f"\n{h.text}"
                    for i, h in enumerate(hits)) or "(no relevant notes found)"
                system = ("You are Cortex, a concise second-brain over the user's markdown vault. "
                          "Answer from the provided notes only; never invent facts; cite sources as [n].")
                try:
                    ans = claude.answer(query, ctx, system=system, model=config.CLAUDE_MODEL, claude_bin=claude_bin)
                    self._send(200, {"answer": ans, "model": f"claude · {config.CLAUDE_MODEL}", "sources": _hits(hits)})
                except claude.ClaudeError as e:
                    self._send(200, {"answer": None, "sources": _hits(hits), "error": str(e)})
            elif u.path == "/related":
                path = data.get("path") or ""
                k = int(data.get("k", 8))
                text = vault.read_any(path)
                hits = [
                    h for h in store.search(store.connect(), embed.embed_query(text[:4000]), k + 6)
                    if h.path != path
                ]
                self._send(200, _hits(hits[:k]))
            elif u.path == "/write":
                path = data.get("path") or ""
                content = data.get("content", "")
                overwrite = bool(data.get("overwrite", True))
                self._send(200, vault.write_note(path, content, overwrite))
            elif u.path == "/append":
                path = data.get("path") or ""
                content = data.get("content", "")
                self._send(200, vault.append_note(path, content))
            else:
                self._send(404, {"error": "not found"})
        except vault.VaultError as e:
            self._send(400, {"error": str(e)})
        except Exception as e:  # noqa: BLE001
            self._send(500, {"error": str(e)})


def make_server(port: int | None = None) -> ThreadingHTTPServer:
    return ThreadingHTTPServer(("127.0.0.1", port or config.HTTP_API_PORT), _Handler)


def serve(port: int | None = None) -> None:
    srv = make_server(port)
    print(f"cortex http api on http://127.0.0.1:{srv.server_address[1]}")
    srv.serve_forever()


def start_in_thread(port: int | None = None) -> ThreadingHTTPServer:
    """Run the API in a daemon thread (used by the watcher). Returns the server."""
    srv = make_server(port)
    threading.Thread(target=srv.serve_forever, daemon=True, name="cortex-http").start()
    return srv


def main() -> int:
    serve()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
