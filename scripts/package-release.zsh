#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="VoiceKey"
APP="$ROOT/.build/$APP_NAME.app"
INFO_PLIST="$ROOT/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
DIST="$ROOT/dist"
RELEASE_DIR="$DIST/$APP_NAME-$VERSION"
STAGE_DIR="$RELEASE_DIR/stage"
DMG_STAGE="$RELEASE_DIR/dmg-stage"
ZIP="$RELEASE_DIR/$APP_NAME-$VERSION-macOS.zip"
DMG="$RELEASE_DIR/$APP_NAME-$VERSION-macOS.dmg"

SIGN_IDENTITY="${VOICEKEY_SIGN_IDENTITY:-}"
NOTARY_PROFILE="${VOICEKEY_NOTARY_KEYCHAIN_PROFILE:-}"
NOTARY_APPLE_ID="${VOICEKEY_NOTARY_APPLE_ID:-}"
NOTARY_PASSWORD="${VOICEKEY_NOTARY_PASSWORD:-}"
NOTARY_TEAM_ID="${VOICEKEY_NOTARY_TEAM_ID:-}"

echo "Packaging $APP_NAME $VERSION ($BUILD)"

"$ROOT/scripts/build-app.zsh" >/dev/null

rm -rf "$RELEASE_DIR"
mkdir -p "$STAGE_DIR" "$DMG_STAGE"
cp -R "$APP" "$STAGE_DIR/$APP_NAME.app"

if command -v xattr >/dev/null 2>&1; then
  xattr -cr "$STAGE_DIR/$APP_NAME.app" || true
fi

if [[ -n "$SIGN_IDENTITY" ]]; then
  echo "Signing app with: $SIGN_IDENTITY"
  codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$STAGE_DIR/$APP_NAME.app"
  codesign --verify --strict --verbose=2 "$STAGE_DIR/$APP_NAME.app"
else
  echo "Skipping code signing. Set VOICEKEY_SIGN_IDENTITY to sign a public build."
fi

if [[ -n "$NOTARY_PROFILE" || ( -n "$NOTARY_APPLE_ID" && -n "$NOTARY_PASSWORD" && -n "$NOTARY_TEAM_ID" ) ]]; then
  if [[ -z "$SIGN_IDENTITY" ]]; then
    echo "Notarization requires a signed app. Set VOICEKEY_SIGN_IDENTITY." >&2
    exit 1
  fi

  NOTARY_ZIP="$RELEASE_DIR/$APP_NAME-$VERSION-notary.zip"
  ditto -c -k --keepParent --sequesterRsrc "$STAGE_DIR/$APP_NAME.app" "$NOTARY_ZIP"

  echo "Submitting app for notarization"
  if [[ -n "$NOTARY_PROFILE" ]]; then
    xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  else
    xcrun notarytool submit "$NOTARY_ZIP" \
      --apple-id "$NOTARY_APPLE_ID" \
      --password "$NOTARY_PASSWORD" \
      --team-id "$NOTARY_TEAM_ID" \
      --wait
  fi

  xcrun stapler staple "$STAGE_DIR/$APP_NAME.app"
  rm -f "$NOTARY_ZIP"
else
  echo "Skipping notarization. Set VOICEKEY_NOTARY_KEYCHAIN_PROFILE or Apple ID notary env vars."
fi

ditto -c -k --keepParent --sequesterRsrc "$STAGE_DIR/$APP_NAME.app" "$ZIP"

cp -R "$STAGE_DIR/$APP_NAME.app" "$DMG_STAGE/$APP_NAME.app"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$DMG_STAGE" \
  -ov \
  -format UDZO \
  "$DMG" >/dev/null

if [[ -n "$SIGN_IDENTITY" ]]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
fi

(
  cd "$RELEASE_DIR"
  shasum -a 256 "$(basename "$ZIP")" "$(basename "$DMG")" > SHA256SUMS.txt
)

cat <<EOF

Release artifacts:
  App: $STAGE_DIR/$APP_NAME.app
  ZIP: $ZIP
  DMG: $DMG
  Checksums: $RELEASE_DIR/SHA256SUMS.txt
EOF
