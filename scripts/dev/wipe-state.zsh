#!/bin/zsh
# Wipe every trace of VoiceKey from this Mac so the next launch is a true
# fresh install (first-run wizard, microphone prompt, empty keychain).
# Used for fresh-hardware release testing — the v0.2.2 microphone
# entitlement bug shipped precisely because nothing was ever tested from
# a clean slate (2026-07-24).
#
# Usage: ./scripts/dev/wipe-state.zsh [--keep-app]
#   --keep-app  wipe preferences/keychain/permissions/state but leave the
#               installed app in place (retest the wizard without
#               reinstalling)
set -u

BUNDLE_ID="com.zigelbaum.VoiceKey"
KEEP_APP=false
[[ "${1:-}" == "--keep-app" ]] && KEEP_APP=true

echo "Quitting VoiceKey..."
pkill -f "VoiceKey.app/Contents/MacOS/VoiceKey" 2>/dev/null
sleep 1

if [[ "$KEEP_APP" == false ]]; then
  echo "Removing the app..."
  brew uninstall --cask --zap voicekey 2>/dev/null \
    || rm -rf /Applications/VoiceKey.app
fi

echo "Deleting preferences..."
defaults delete "$BUNDLE_ID" 2>/dev/null

echo "Deleting keychain items (API keys, MCP tokens, gateway token)..."
while security delete-generic-password -s "$BUNDLE_ID" >/dev/null 2>&1; do :; done

echo "Resetting permission grants (microphone prompt will fire again)..."
tccutil reset Microphone "$BUNDLE_ID"
tccutil reset Accessibility "$BUNDLE_ID"

echo "Deleting logs, web sessions, caches, saved state..."
rm -rf ~/Library/Logs/VoiceKey \
       ~/Library/WebKit/"$BUNDLE_ID" \
       ~/Library/Caches/"$BUNDLE_ID" \
       ~/Library/HTTPStorages/"$BUNDLE_ID" \
       ~/Library/Saved\ Application\ State/"$BUNDLE_ID".savedState

echo "VoiceKey state wiped."
if [[ "$KEEP_APP" == false ]]; then
  echo "Reinstall with: brew install --cask voicekey"
fi
