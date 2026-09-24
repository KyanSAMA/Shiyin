#!/bin/bash
# Build and package build/LocalMusic.app (ad-hoc signed). Usage: Scripts/bundle.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."

CFG=${1:-debug}
swift build -c "$CFG" --product LocalMusic 2>&1 | { grep -Ev "search path '.*' not found" || true; } >&2
BIN=$(swift build -c "$CFG" --show-bin-path)
[ -x "$BIN/LocalMusic" ] || { echo "build failed" >&2; exit 1; }

APP=build/LocalMusic.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/LocalMusic" "$APP/Contents/MacOS/"
ICON=.build/AppIcon.icns
[ "$ICON" -nt Scripts/make-icon.swift ] || swift Scripts/make-icon.swift "$ICON"
cp "$ICON" "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>io.github.kyansama.localmusic</string>
  <key>CFBundleExecutable</key><string>LocalMusic</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleName</key><string>本地音乐</string>
  <key>CFBundleDisplayName</key><string>本地音乐</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.$(git rev-list --count HEAD)</string>
  <key>CFBundleVersion</key><string>$(git rev-list --count HEAD)</string>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>CFBundleLocalizations</key><array><string>zh-Hans</string></array>
  <key>LSMinimumSystemVersion</key><string>27.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
EOF

plutil -lint -s "$APP/Contents/Info.plist"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP"
echo "$APP"
