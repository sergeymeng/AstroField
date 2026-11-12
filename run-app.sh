#!/bin/zsh
# Build and launch the SwiftUI app from the terminal (development).
set -euo pipefail
cd "$(dirname "$0")/.."
swift build
BIN=$(swift build --show-bin-path)
exec "$BIN/AstroField"
