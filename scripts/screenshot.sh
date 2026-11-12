#!/bin/zsh
# Regenerate the UI state screenshots used in docs/screenshots.
set -euo pipefail
cd "$(dirname "$0")/.."
BIN=$(swift build --show-bin-path)/AstroField
OUT=docs/screenshots
mkdir -p "$OUT"

shoot() {
  local name="$1" demo="$2" delay="$3"
  ASTROFIELD_DEMO="$demo" ASTROFIELD_SHOT_PATH="$OUT/$name.png" \
    ASTROFIELD_SHOT_DELAY="$delay" ASTROFIELD_SHOT_EXIT=1 "$BIN" >/dev/null 2>&1
  echo "$OUT/$name.png"
}

shoot 01-idle idle 5
shoot 02-exposing exposing 6
shoot 03-focus focus 7
shoot 04-analysis analysis 5
shoot 05-corners corners 5
shoot 06-stack stack 8
shoot 07-trial trial 10
shoot 08-compare compare 11
shoot 09-disconnected disconnected 3
shoot 14-integration integration 13
shoot 15-focus-bracket focusbracket 9
shoot 16-trails trails 9
shoot 17-groups groups 8

ASTROFIELD_DEMO=idle ASTROFIELD_WINDOW_SIZE=1180x760 \
  ASTROFIELD_SHOT_PATH="$OUT/12-small-window.png" ASTROFIELD_SHOT_DELAY=5 \
  ASTROFIELD_SHOT_EXIT=1 "$BIN" >/dev/null 2>&1
echo "$OUT/12-small-window.png"
ASTROFIELD_DEMO=idle ASTROFIELD_WINDOW_SIZE=1920x1080 \
  ASTROFIELD_SHOT_PATH="$OUT/13-large-window.png" ASTROFIELD_SHOT_DELAY=5 \
  ASTROFIELD_SHOT_EXIT=1 "$BIN" >/dev/null 2>&1
echo "$OUT/13-large-window.png"

ASTROFIELD_NIGHT=1 ASTROFIELD_DEMO=idle ASTROFIELD_SHOT_PATH="$OUT/10-night.png" \
  ASTROFIELD_SHOT_DELAY=4 ASTROFIELD_SHOT_EXIT=1 "$BIN" >/dev/null 2>&1
echo "$OUT/10-night.png"

if [ -d "logs/hw-z7ii/bulb" ]; then
  ASTROFIELD_PLAYBACK_DIR="$PWD/logs/hw-z7ii/bulb" ASTROFIELD_DEMO=analysis \
    ASTROFIELD_SHOT_PATH="$OUT/11-nef-playback.png" ASTROFIELD_SHOT_DELAY=9 \
    ASTROFIELD_SHOT_EXIT=1 "$BIN" >/dev/null 2>&1
  echo "$OUT/11-nef-playback.png"
fi
