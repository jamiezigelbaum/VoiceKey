#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/.build/VoiceKey.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

cd "$ROOT"
if [[ -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

swift build -c release

rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"
cp "$ROOT/.build/release/VoiceKey" "$MACOS/VoiceKey"
cp "$ROOT/Info.plist" "$CONTENTS/Info.plist"
if [[ -d "$ROOT/Resources" ]]; then
  cp -R "$ROOT/Resources/." "$RESOURCES/"
fi

echo "$APP"

# Sign dev builds with a stable identity when available: macOS TCC keys
# accessibility/microphone grants to the code signature, and ad-hoc
# rebuilds invalidate them silently on every build (2026-07-24: an
# accessibility grant vanished after a rebuild, breaking native clicks).
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application: JAMIE B ZIGELBAUM"; then
  codesign --force --deep --options runtime --entitlements /dev/null \
    --sign "Developer ID Application: JAMIE B ZIGELBAUM (5L9687WCZQ)" "$APP" 2>/dev/null \
    || codesign --force --deep --sign "Developer ID Application: JAMIE B ZIGELBAUM (5L9687WCZQ)" "$APP"
  echo "signed: $(codesign -dv "$APP" 2>&1 | grep '^Authority' | head -1)"
fi
