#!/bin/zsh
# Build a standalone AstroField.app bundle in dist/.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
./scripts/build_icons.sh
if [[ "${2:-}" == "--universal" ]]; then
  # The downloadable app uses Core Image and needs only macOS frameworks.
  export ASTROFIELD_DISABLE_LIBRAW=1
  unset NIKON_SDK_HEADERS
  arches=(arm64 x86_64)
else
  arches=("$(uname -m)")
fi

executables=()
for arch in "${arches[@]}"; do
  swift build -c "$CONFIG" --arch "$arch" --product AstroField
  bin_dir=$(swift build -c "$CONFIG" --arch "$arch" --show-bin-path)
  executables+=("$bin_dir/AstroField")
done

APP="dist/AstroField.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if (( ${#executables} == 1 )); then
  cp "$executables[1]" "$APP/Contents/MacOS/AstroField"
else
  lipo -create "${executables[@]}" -output "$APP/Contents/MacOS/AstroField"
fi
cp "Sources/AstroField/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cp -R Sources/AstroFieldKit/Resources/*.lproj "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
  <key>CFBundleLocalizations</key>
  <array><string>zh-Hans</string><string>en</string></array>
  <key>CFBundleName</key><string>AstroField</string>
  <key>CFBundleDisplayName</key><string>AstroField</string>
  <key>CFBundleIdentifier</key><string>com.astrofield.app</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleExecutable</key><string>AstroField</string>
  <key>CFBundleIconFile</key><string>AppIcon.icns</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.photography</string>
  <key>NSHumanReadableCopyright</key><string>AstroField</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null
echo "built $APP"
echo "launch: open $APP"
