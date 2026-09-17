#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INFO_PLIST="$ROOT/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
TAG="v$VERSION"
RELEASE_DIR="$ROOT/dist/VoiceKey-$VERSION"
DMG="$RELEASE_DIR/VoiceKey-$VERSION-macOS.dmg"
ZIP="$RELEASE_DIR/VoiceKey-$VERSION-macOS.zip"
CHECKSUMS="$RELEASE_DIR/SHA256SUMS.txt"

if ! command -v gh >/dev/null 2>&1; then
  echo "GitHub CLI is required for this script: https://cli.github.com/" >&2
  exit 1
fi

for artifact in "$DMG" "$ZIP" "$CHECKSUMS"; do
  if [[ ! -f "$artifact" ]]; then
    echo "Missing release artifact: $artifact" >&2
    echo "Run ./scripts/package-release.zsh first." >&2
    exit 1
  fi
done

if ! git rev-parse "$TAG" >/dev/null 2>&1; then
  git tag -a "$TAG" -m "VoiceKey $VERSION"
fi

git push origin "$TAG"

gh release create "$TAG" \
  "$DMG" \
  "$ZIP" \
  "$CHECKSUMS" \
  --title "VoiceKey $VERSION" \
  --notes-file "$ROOT/CHANGELOG.md" \
  --draft
