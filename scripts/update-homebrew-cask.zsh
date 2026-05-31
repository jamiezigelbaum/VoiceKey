#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INFO_PLIST="$ROOT/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
DMG="$ROOT/dist/VoiceKey-$VERSION/VoiceKey-$VERSION-macOS.dmg"
CASK="$ROOT/packaging/homebrew/Casks/voicekey.rb"
REPO="${VOICEKEY_GITHUB_REPO:-jamiezigelbaum/VoiceKey}"

if [[ ! -f "$DMG" ]]; then
  echo "Missing DMG: $DMG" >&2
  echo "Run ./scripts/package-release.zsh first." >&2
  exit 1
fi

SHA256="$(shasum -a 256 "$DMG" | awk '{print $1}')"

mkdir -p "$(dirname "$CASK")"
cat > "$CASK" <<EOF
cask "voicekey" do
  version "$VERSION"
  sha256 "$SHA256"

  url "https://github.com/$REPO/releases/download/v#{version}/VoiceKey-#{version}-macOS.dmg"
  name "VoiceKey"
  desc "Menu bar hotkey for ChatGPT Voice"
  homepage "https://github.com/$REPO"

  auto_updates false
  depends_on macos: ">= :ventura"

  app "VoiceKey.app"

  zap trash: [
    "~/Library/Preferences/com.zigelbaum.VoiceKey.plist",
    "~/Library/WebKit/com.zigelbaum.VoiceKey",
  ]
end
EOF

echo "$CASK"
