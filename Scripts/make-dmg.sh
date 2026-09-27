#!/bin/bash
# Release build packed as build/Shiyin-<version>.dmg (拾音.app beside an Applications link). Usage: Scripts/make-dmg.sh
set -euo pipefail
cd "$(dirname "$0")/.."

Scripts/bundle.sh release >/dev/null
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" build/LocalMusic.app/Contents/Info.plist)
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto build/LocalMusic.app "$STAGE/拾音.app"
ln -s /Applications "$STAGE/Applications"
DMG=build/Shiyin-$VERSION.dmg
rm -f "$DMG"
hdiutil create -quiet -volname "拾音" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
hdiutil verify -quiet "$DMG"
echo "$DMG"
