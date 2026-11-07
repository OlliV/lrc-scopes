#!/bin/bash
# Installs the built plug-in into Lightroom Classic's auto-loaded Modules folder.
# Lightroom must be restarted (or the plug-in reloaded in the Plug-in Manager).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/build/LRCScopes.lrplugin"
DEST_DIR="$HOME/Library/Application Support/Adobe/Lightroom/Modules"
DEST="$DEST_DIR/LRCScopes.lrplugin"

[[ -d "$SRC" ]] || { echo "Run scripts/build.sh first" >&2; exit 1; }

# A running helper holds its executable open; ask it to go away cleanly first.
osascript -e 'tell application id "com.lrcscopes.helper" to quit' >/dev/null 2>&1 || true

mkdir -p "$DEST_DIR"
rm -rf "$DEST"
ditto "$SRC" "$DEST"
echo "Installed to $DEST"
