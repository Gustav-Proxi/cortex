# Cortex — Obsidian plugin

The **in-Obsidian face** of the Cortex brain. The engine (embeddings, sqlite-vec
index, file access) runs *outside* Obsidian at `~/cortex`; this plugin reaches
it over the loopback JSON API (`http://127.0.0.1:8788`, served by the cortex
watcher). The arrow points **plugin → engine** — Obsidian is never the source of
truth.

## Features

- **Semantic search pane** — embeddings query lookup across the whole vault.
- **Auto-connections** — embedding-nearest notes for the note you're viewing,
  refreshing as you navigate (the in-house equivalent of Smart Connections).
  Toggle in settings.
- **Look up selection** — semantic search on highlighted editor text.
- **Capture** — create a note straight into the vault via the engine (`＋` in the
  pane, or the "Capture a note" command).

Commands: *Open search*, *Connections for current note*, *Look up selection
(semantic)*, *Capture a note*. Ribbon: the brain-circuit icon.

## How it's installed (symlink — single source of truth)

The source lives here in the repo. Obsidian loads it via a symlink so there's no
copy to keep in sync:

```bash
ln -s ~/cortex/obsidian-plugin ~/Claude/.obsidian/plugins/cortex
# then enable "Cortex" in Settings → Community plugins (reload Obsidian)
```

Edit files here → reload Obsidian (⌘R) to pick up changes. No build step: it's
hand-written CommonJS (`main.js`), and Obsidian provides the `obsidian` API at
runtime. `manifest.json` declares `isDesktopOnly` because it talks to a local
server.

## Requires

The cortex watcher must be running (it serves the HTTP API). It auto-starts on
login via `~/Library/LaunchAgents/dev.cortex.watch.plist`. If the pane
shows "engine offline", start it: `launchctl load -w …` or `python -m cortex.watch`.
