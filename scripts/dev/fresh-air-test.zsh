#!/bin/zsh
# Deploy the CURRENT local build to a test Mac as a true fresh install:
# wipe all VoiceKey state there, remove any brew-installed copy, push the
# freshly built signed app, and launch it — so the first-run wizard and
# permission prompts run for real on hardware that has never seen this
# build. Usage: ./scripts/dev/fresh-air-test.zsh [ssh-host]   (default: air)
set -eu

HOST="${1:-air}"
BUNDLE_ID="com.zigelbaum.VoiceKey"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="$ROOT/.build/VoiceKey.app"

echo "==> Building signed app locally..."
"$ROOT/scripts/build-app.zsh" >/dev/null
codesign -dv "$APP" 2>&1 | grep -q TeamIdentifier || {
  echo "!! local build is not Developer-ID signed; aborting (TCC needs a stable identity)"; exit 1; }

echo "==> Wiping VoiceKey state on $HOST..."
ssh "$HOST" "
  # TCC resets FIRST, while a bundle still exists to resolve the id.
  tccutil reset Microphone $BUNDLE_ID 2>/dev/null || true
  tccutil reset Accessibility $BUNDLE_ID 2>/dev/null || true
  pkill -f 'VoiceKey.app/Contents/MacOS/VoiceKey' 2>/dev/null || true
  sleep 1
  BREW=/opt/homebrew/bin/brew
  if [[ -x \$BREW ]] && \$BREW list --cask voicekey >/dev/null 2>&1; then
    \$BREW uninstall --cask --zap --force voicekey
  fi
  rm -rf /Applications/VoiceKey.app
  defaults delete $BUNDLE_ID 2>/dev/null || true
  KEYCHAIN_CLEARED=true
  while security delete-generic-password -s $BUNDLE_ID >/dev/null 2>&1; do :; done
  security find-generic-password -s $BUNDLE_ID >/dev/null 2>&1 && KEYCHAIN_CLEARED=false
  \$KEYCHAIN_CLEARED || echo 'WARNING: keychain items could not be fully cleared (keychain locked over ssh?)'
  rm -rf ~/Library/Logs/VoiceKey \
         ~/Library/WebKit/$BUNDLE_ID \
         ~/Library/Caches/$BUNDLE_ID \
         ~/Library/HTTPStorages/$BUNDLE_ID \
         ~/Library/Saved\\ Application\\ State/$BUNDLE_ID.savedState
  echo 'wipe complete'
"

echo "==> Pushing the built app (rsync preserves the code signature; scp/rsync sets no quarantine, so no translocation)..."
rsync -a --delete "$APP/" "$HOST:/Applications/VoiceKey.app/"

echo "==> Verifying signature on $HOST..."
ssh "$HOST" "codesign -v --deep /Applications/VoiceKey.app && codesign -d --entitlements - /Applications/VoiceKey.app 2>&1 | grep -q audio-input && echo 'signature + mic entitlement OK'"

echo "==> Launching..."
ssh "$HOST" "open /Applications/VoiceKey.app"
echo "Fresh install running on $HOST — the first-run wizard should be on screen."
