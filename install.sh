#!/usr/bin/env bash
# Cortex one-shot setup for macOS (Apple Silicon).
# Run from the repo root:  bash install.sh
set -euo pipefail

CORTEX_VAULT="${CORTEX_VAULT:-$HOME/Claude}"
EMBED_MODEL="${CORTEX_EMBED_MODEL:-nomic-embed-text}"

echo "==> Vault: $CORTEX_VAULT"
[ -d "$CORTEX_VAULT" ] || { echo "Vault not found at $CORTEX_VAULT. Set CORTEX_VAULT."; exit 1; }

# 1. Ollama
if ! command -v ollama >/dev/null 2>&1; then
  echo "==> Installing Ollama (brew)"
  brew install ollama || { echo "Install Ollama from https://ollama.com then re-run."; exit 1; }
fi
echo "==> Starting Ollama (if not already running)"
pgrep -x ollama >/dev/null 2>&1 || (ollama serve >/tmp/ollama.log 2>&1 &) && sleep 2
echo "==> Pulling embedding model: $EMBED_MODEL"
ollama pull "$EMBED_MODEL"

# 2. Python venv + deps
echo "==> Creating venv + installing cortex"
python3 -m venv .venv
./.venv/bin/pip install --quiet --upgrade pip
./.venv/bin/pip install --quiet -e .

# 3. First full index
echo "==> Building the index (first run embeds the whole vault)"
CORTEX_VAULT="$CORTEX_VAULT" ./.venv/bin/python -m cortex.index build

# 4. Install the background watcher as a launchd agent (auto-start on login)
echo "==> Installing the cortex watcher LaunchAgent (auto-start on login)"
PLIST="$HOME/Library/LaunchAgents/dev.cortex.watch.plist"
sed -e "s#__VENV_PYTHON__#$PWD/.venv/bin/python#" \
    -e "s#__WORKDIR__#$PWD#" \
    -e "s#__VAULT__#$CORTEX_VAULT#" \
  launchd/cortex.watch.plist.template > "$PLIST"
launchctl load -w "$PLIST" 2>/dev/null || echo "    (could not auto-load; run: launchctl load -w \"$PLIST\")"

echo
echo "Done. Quick test:"
echo "  CORTEX_VAULT=\"$CORTEX_VAULT\" ./.venv/bin/python -m cortex.index search \"project baselines\""
echo
echo "Next: connect the MCP server to your client — see README 'Connect it to an MCP client'."
