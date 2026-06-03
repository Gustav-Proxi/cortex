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
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

from . import config, embed, store, vault


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
                self._send(200, {"path": path, "content": vault.read_note(path)})
            elif u.path == "/list":
                folder = (q.get("folder") or [""])[0] or None
                limit = int((q.get("limit") or ["0"])[0]) or None
                self._send(200, vault.list_notes(folder, limit))
            else:
                self._send(404, {"error": "not found"})
        except vault.VaultError as e:
            self._send(400, {"error": str(e)})
        except Exception as e:  # noqa: BLE001 — surface any engine error as JSON
            self._send(500, {"error": str(e)})

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
            elif u.path == "/related":
                path = data.get("path") or ""
                k = int(data.get("k", 8))
                text = vault.read_note(path)
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
