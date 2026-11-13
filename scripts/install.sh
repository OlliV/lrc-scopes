#!/bin/bash
# Installs the built plug-in into Lightroom Classic's auto-loaded Modules folder.
# Lightroom must be restarted (or the plug-in reloaded in the Plug-in Manager).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/build/LRCScopes.lrplugin"
DEST_DIR="$HOME/Library/Application Support/Adobe/Lightroom/Modules"
DEST="$DEST_DIR/LRCScopes.lrplugin"

[[ -d "$SRC" ]] || { echo "Run scripts/build.sh first" >&2; exit 1; }

# With Lightroom running, leave its helper alone: it keeps running from the old copy
# (macOS allows replacing a running app's files) and exits when Lightroom quits or the
# plug-in reloads. Killing it under a live Lightroom would make the plug-in rebind its
# socket mid-session for no reason. Without Lightroom, a stray helper is just quit.
if ! pgrep -x "Adobe Lightroom Classic" >/dev/null; then
    osascript -e 'tell application id "com.lrcscopes.helper" to quit' >/dev/null 2>&1 || true
fi

mkdir -p "$DEST_DIR"
rm -rf "$DEST"
ditto "$SRC" "$DEST"
echo "Installed to $DEST"
