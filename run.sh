#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"

swift build
BIN=$(swift build --show-bin-path)
if [[ -n "${NIKON_SDK_HEADERS:-}" ]]; then
  FRAMEWORKS="$(dirname "$BIN")/Frameworks"
  SDK_FRAMEWORKS="${NIKON_SDK_FRAMEWORKS:-$PWD/vendor/nikon-z-2.1.0/TestApp-extracted/TestApp/Frameworks}"
  mkdir -p "$FRAMEWORKS"
  for name in libNkPTPDriver2.dylib Royalmile.framework; do
    if [[ ! -e "$FRAMEWORKS/$name" && -e "$SDK_FRAMEWORKS/$name" ]]; then
      cp -R "$SDK_FRAMEWORKS/$name" "$FRAMEWORKS/"
    fi
  done
  export NIKON_SDK_MODULE="${NIKON_SDK_MODULE:-$PWD/vendor/nikon-z-2.1.0/TestApp-extracted/TestApp/TestApp/TypeCommon Module.bundle/Contents/MacOS/TypeCommon Module}"
fi
exec "$BIN/afspike" "$@"
