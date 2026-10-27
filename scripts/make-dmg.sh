#!/bin/bash
# Builds Keylog.app and packs it into build/Keylog.dmg, the file people download: a disk image
# named Keylog holding the app and a shortcut to Applications to drag it onto.
#   ./scripts/make-dmg.sh                                   build, then pack
#   APP=some/Keylog.app DMG=out.dmg ./scripts/make-dmg.sh   pack an app that is already built
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -z "${APP:-}" ]; then
  INSTALL=0 ./scripts/build.sh
  APP=build/Keylog.app
fi
DMG="${DMG:-build/Keylog.dmg}"
[ -f "$APP/Contents/Info.plist" ] || { echo "No app at $APP" >&2; exit 1; }
codesign --verify --strict "$APP"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir "$STAGE/Keylog"
ditto "$APP" "$STAGE/Keylog/Keylog.app"
ln -s /Applications "$STAGE/Keylog/Applications"

mkdir -p "$(dirname "$DMG")"
rm -f "$DMG"
hdiutil create -volname Keylog -srcfolder "$STAGE/Keylog" -fs HFS+ -format UDZO -imagekey zlib-level=9 -quiet "$DMG"
hdiutil verify -quiet "$DMG"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
echo "Made $DMG: Keylog $VERSION, $(du -h "$DMG" | cut -f1 | tr -d ' ')"
