#!/bin/bash
# Build Cortex.app — native SwiftUI client of the local engine (:8788).
# Needs Xcode command-line tools (swiftc). No Xcode project, no Rust, no runtime.
set -euo pipefail
cd "$(dirname "$0")"

APP="Cortex.app"
CON="$APP/Contents"
rm -rf "$APP"
mkdir -p "$CON/MacOS" "$CON/Resources"
cp Info.plist "$CON/Info.plist"
[ -f Cortex.icns ] && cp Cortex.icns "$CON/Resources/Cortex.icns"

# All app sources except shot.swift (a standalone screenshot dev-tool with its
# own entry point) and the retired *.webkit-legacy shell.
SRC=$(ls *.swift | grep -v '^shot\.swift$')
echo "Compiling: $SRC"

swiftc -O -o "$CON/MacOS/Cortex" $SRC \
    -framework SwiftUI -framework AppKit -framework SpriteKit \
    -target arm64-apple-macosx13.0

# Ad-hoc sign so Gatekeeper runs a locally-built app without quarantine pain.
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "Built $PWD/$APP"
echo "Run:        open '$PWD/$APP'"
echo "Install:    cp -R '$PWD/$APP' /Applications/"
