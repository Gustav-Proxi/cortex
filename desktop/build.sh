#!/bin/bash
# Build Cortex.app — a native WKWebView shell over the local engine UI.
# Needs Xcode command-line tools (swiftc). No other dependencies.
set -euo pipefail
cd "$(dirname "$0")"

APP="Cortex.app"
CON="$APP/Contents"
rm -rf "$APP"
mkdir -p "$CON/MacOS" "$CON/Resources"
cp Info.plist "$CON/Info.plist"

swiftc -O -o "$CON/MacOS/Cortex" Cortex.swift \
    -framework Cocoa -framework WebKit \
    -target arm64-apple-macosx12.0

# Ad-hoc sign so Gatekeeper lets a locally-built app run without quarantine pain.
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "Built $PWD/$APP"
echo "Run:        open '$PWD/$APP'"
echo "Install:    cp -R '$PWD/$APP' /Applications/   (then add to Login Items to auto-open)"
