#!/bin/bash
# Builds Keylog.app into build/ and installs it in ~/Applications.
#   CONFIG=debug ./scripts/build.sh   debug build
#   INSTALL=0 ./scripts/build.sh      build only, don't install
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
swift build -c "$CONFIG" --product Keylog
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Keylog"

APP="build/Keylog.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Keylog"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Signing every build with the same certificate lets macOS keep the Input Monitoring
# permission across rebuilds. Without one (run scripts/make-cert.sh), sign ad-hoc.
IDENTITY="${KEYLOG_SIGN_ID:-Keylog Dev}"
IDENTITIES="$(security find-identity -p codesigning 2>/dev/null || true)"
if grep -qF "\"$IDENTITY\"" <<<"$IDENTITIES"; then
  SIGN="$IDENTITY"
else
  SIGN="-"
  echo "No \"$IDENTITY\" certificate: signing ad-hoc, so macOS will ask for permission again after each rebuild."
fi
# Drop debug symbols: smaller, and no build-machine paths inside the app.
strip -S -x "$APP/Contents/MacOS/Keylog"
codesign --force --options runtime --timestamp=none --sign "$SIGN" "$APP"
echo "Built $APP (signed: $SIGN)"

if [ "${INSTALL:-1}" = 1 ]; then
  DEST="$HOME/Applications/Keylog.app"
  # Quit the running copy first; it saves its counts on the way out.
  if pgrep -x Keylog >/dev/null; then
    pkill -x Keylog || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Keylog >/dev/null || break; sleep 0.3; done
  fi
  mkdir -p "$HOME/Applications"
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  touch "$DEST"
  # Let Finder and Spotlight pick up a changed icon.
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" >/dev/null 2>&1 || true
  echo "Installed $DEST"
fi
