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

# Reset permissions BEFORE removing the app: tccutil resolves the bundle
# id through the installed app, and fails with kLSApplicationNotFoundErr
# once it is gone (bit us live on the Air, 2026-07-24).
echo "Resetting permission grants (microphone prompt will fire again)..."
tccutil reset Microphone "$BUNDLE_ID"
tccutil reset Accessibility "$BUNDLE_ID"

if [[ "$KEEP_APP" == false ]]; then
  echo "Removing the app..."
  # --force uninstalls even if artifacts are missing; never hide brew's
  # errors — a silently failed uninstall leaves Caskroom metadata behind
  # and "brew install" then refuses with "already installed" (also bit
  # us live on the Air).
  if command -v brew >/dev/null 2>&1 && brew list --cask voicekey >/dev/null 2>&1; then
    brew uninstall --cask --zap --force voicekey
  else
    rm -rf /Applications/VoiceKey.app
  fi
fi

echo "Deleting preferences..."
defaults delete "$BUNDLE_ID" 2>/dev/null

echo "Deleting keychain items (API keys, MCP tokens, gateway token)..."
while security delete-generic-password -s "$BUNDLE_ID" >/dev/null 2>&1; do :; done

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
