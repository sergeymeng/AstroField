#!/bin/zsh
# Rebuild the icon used by both SwiftPM and the standalone application.
set -euo pipefail
cd "$(dirname "$0")/.."

ICON_SOURCE="assets/branding/app-icon.png"
ICON_OUTPUT="Sources/AstroField/Resources/AppIcon.icns"
mkdir -p .build "$(dirname "$ICON_OUTPUT")"
ICON_WORK_DIR=$(mktemp -d "$PWD/.build/app-icon.XXXXXX")
trap 'rm -rf "$ICON_WORK_DIR"' EXIT
ICONSET="$ICON_WORK_DIR/AppIcon.iconset"
mkdir -p "$ICONSET"

for SIZE in 16 32 128 256 512; do
    sips -z "$SIZE" "$SIZE" "$ICON_SOURCE" --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
    RETINA_SIZE=$((SIZE * 2))
    sips -z "$RETINA_SIZE" "$RETINA_SIZE" "$ICON_SOURCE" --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done

iconutil --convert icns "$ICONSET" --output "$ICON_WORK_DIR/AppIcon.icns"
mv "$ICON_WORK_DIR/AppIcon.icns" "$ICON_OUTPUT"
echo "built $ICON_OUTPUT"
