#!/bin/bash
# Builds Murmur.app into ./release. Pass --install to copy it to /Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

OUT=release
APP="$OUT/Murmur.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Murmur "$APP/Contents/MacOS/Murmur"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [ ! -f "$OUT/AppIcon.icns" ]; then
  swift scripts/make-icon.swift "$OUT/AppIcon.iconset"
  iconutil -c icns "$OUT/AppIcon.iconset" -o "$OUT/AppIcon.icns"
fi
cp "$OUT/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature whose designated requirement only checks the bundle ID, so macOS
# keeps the Microphone and Accessibility permissions when you rebuild.
codesign --force --sign - \
  --identifier com.harrydavies.murmur \
  --requirements '=designated => identifier "com.harrydavies.murmur"' \
  "$APP"

echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  DEST=/Applications
  [ -w "$DEST" ] || DEST="$HOME/Applications"
  mkdir -p "$DEST"
  pkill -x Murmur 2>/dev/null && sleep 0.5 || true
  rm -rf "$DEST/Murmur.app"
  cp -R "$APP" "$DEST/"
  open "$DEST/Murmur.app"
  echo "Installed and launched $DEST/Murmur.app"
fi
