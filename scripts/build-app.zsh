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
# Identity comes from VOICEKEY_SIGN_IDENTITY, else the first "Developer ID
# Application" identity in the keychain.
SIGN_IDENTITY="${VOICEKEY_SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
fi
if [[ -n "$SIGN_IDENTITY" ]]; then
  codesign --force --deep --options runtime --entitlements "$ROOT/VoiceKey.entitlements" \
    --sign "$SIGN_IDENTITY" "$APP" 2>/dev/null \
    || codesign --force --deep --entitlements "$ROOT/VoiceKey.entitlements" \
    --sign "$SIGN_IDENTITY" "$APP"
  echo "signed: $(codesign -dv "$APP" 2>&1 | grep '^Authority' | head -1)"
else
  # No Developer ID here (CI, or a fresh clone). Ad-hoc sign anyway, WITH the
  # entitlements: an unsigned bundle carries none, so there would be nothing
  # for verify-app-entitlements.zsh to inspect and the release gate would only
  # ever run on the one machine that already works.
  codesign --force --options runtime --entitlements "$ROOT/VoiceKey.entitlements" \
    --sign - "$APP"
  echo "signed: ad-hoc (no Developer ID identity available)"
fi

"$ROOT/scripts/verify-app-entitlements.zsh" "$APP"
