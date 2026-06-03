"""File watcher — keeps the index in sync as you edit the vault.

Debounces rapid saves (Obsidian writes a file several times in a burst) and
re-embeds only the touched note. Deleted notes are pruned. This is the "sync"
layer: the vector index trails the vault by a couple of seconds, no manual
rebuilds.

  python -m cortex.watch
"""
from __future__ import annotations

import threading
import time
from pathlib import Path

from watchdog.events import FileSystemEventHandler
from watchdog.observers import Observer

from . import config, http_api, index, store


class _Handler(FileSystemEventHandler):
    def __init__(self, debounce: float = 2.0):
        self.debounce = debounce
        self._pending: dict[str, float] = {}
        self._lock = threading.Lock()

    def _touch(self, src: str) -> None:
        if not src.endswith(".md"):
            return
        with self._lock:
            self._pending[src] = time.time()

    def on_modified(self, event):
        if not event.is_directory:
            self._touch(event.src_path)

    def on_created(self, event):
        if not event.is_directory:
            self._touch(event.src_path)

    def on_moved(self, event):
        if not event.is_directory:
            self._touch(event.dest_path)

    def on_deleted(self, event):
        if event.is_directory or not event.src_path.endswith(".md"):
            return
        try:
            rel = str(Path(event.src_path).relative_to(config.VAULT_PATH))
        except ValueError:
            return
        db = store.connect()
        store.delete_path(db, rel)
        db.commit()
        print(f"pruned {rel}")

    def flush_loop(self):
        db = store.connect()
        while True:
            time.sleep(1.0)
            now = time.time()
            ready = []
            with self._lock:
                for src, ts in list(self._pending.items()):
                    if now - ts >= self.debounce:
                        ready.append(src)
                        del self._pending[src]
            for src in ready:
                path = Path(src)
                if not path.exists():
                    continue
                try:
                    n = index.index_file(db, path, force=False)
                    if n:
                        print(f"reindexed {path.name}: {n} chunks")
                except Exception as e:
                    print(f"! {path.name}: {e}")


def main() -> int:
    handler = _Handler()
    threading.Thread(target=handler.flush_loop, daemon=True).start()
    # Catch up on edits/deletions made while the watcher was off (offline drift) —
    # incremental, in the background so startup isn't blocked.
    def _reconcile():
        try:
            index.build(full=False)
        except Exception as e:
            print(f"startup reconcile skipped: {e}")
    threading.Thread(target=_reconcile, daemon=True).start()
    # Serve the local JSON API for the in-Obsidian Cortex plugin (same process).
    try:
        http_api.start_in_thread()
        print(f"cortex http api on http://127.0.0.1:{config.HTTP_API_PORT}")
    except OSError as e:
        print(f"http api not started ({e}) — watcher continues without it")
    obs = Observer()
    obs.schedule(handler, str(config.VAULT_PATH), recursive=True)
    obs.start()
    print(f"watching {config.VAULT_PATH} (Ctrl-C to stop)")
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        obs.stop()
    obs.join()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
