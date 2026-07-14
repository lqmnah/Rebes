#!/bin/zsh
# Builds a drag-to-install DMG for Rebes! from dist/Rebes.app.
# Usage: ./scripts/make-dmg.sh   (run scripts/build-app.sh first)
set -e

APP="dist/Rebes.app"
VOL="Rebes!"
DMG="dist/Rebes-1.0.dmg"

[[ -d "$APP" ]] || { echo "Missing $APP — run ./scripts/build-app.sh first"; exit 1; }

STAGE="$(mktemp -d)/Rebes"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create \
  -volname "$VOL" \
  -srcfolder "$STAGE" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$DMG" >/dev/null

rm -rf "$(dirname "$STAGE")"
echo "Built $DMG"
hdiutil imageinfo "$DMG" 2>/dev/null | grep -E "Format:|Checksum" | head -2 || true
