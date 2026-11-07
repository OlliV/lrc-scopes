#!/bin/bash
# Builds the native helper as a universal, signed .app and assembles the plug-in
# into build/LRCScopes.lrplugin.
#
#   scripts/build.sh                 ad-hoc signed (local use)
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build.sh   distributable
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="1.0.0"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

OUT="$ROOT/build"
PLUGIN_OUT="$OUT/LRCScopes.lrplugin"
APP="$PLUGIN_OUT/bin/LRC Scopes.app"

echo "==> Building helper (universal, release)"
cd "$ROOT/helper"
swift build -c release --arch arm64 --arch x86_64
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

echo "==> Assembling plug-in"
rm -rf "$PLUGIN_OUT"
mkdir -p "$PLUGIN_OUT"
# Ship only the plug-in's Lua sources (tests stay out of the bundle).
cp "$ROOT"/plugin/LRCScopes.lrplugin/*.lua "$PLUGIN_OUT/"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/LRCScopes" "$APP/Contents/MacOS/LRCScopes"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" \
    "$ROOT/helper/Resources/Info.plist" > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> Signing ($SIGN_IDENTITY)"
SIGN_ARGS=(--force --sign "$SIGN_IDENTITY" --timestamp=none)
if [[ "$SIGN_IDENTITY" != "-" ]]; then
    SIGN_ARGS=(--force --sign "$SIGN_IDENTITY" --options runtime --timestamp)
fi
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --strict --verbose=1 "$APP"

lipo -info "$APP/Contents/MacOS/LRCScopes"
echo "==> Built $PLUGIN_OUT"
