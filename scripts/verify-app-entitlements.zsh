#!/bin/zsh
# Inspect a BUILT app bundle and fail unless it actually carries the
# entitlements and usage descriptions VoiceKey needs to function.
#
# Why this exists, and why it inspects the artifact rather than the sources:
# v0.2.0 and v0.2.1 both shipped with a dead microphone. The hardened runtime
# blocks capture unless `com.apple.security.device.audio-input` is present, and
# without it TCC reports the app as denied WITHOUT prompting — it never even
# appears in the Microphone pane. The gate written afterwards read
# `VoiceKey.entitlements` from the repository, which is a different file from
# the one that ships: dropping `--entitlements` from the signing command in
# scripts/package-release.zsh left every source check green and still produced a
# release nobody could speak to. A gate that cannot fail on the bug it was
# written for is decoration (adversarial review, 2026-07-29).
#
# Usage: scripts/verify-app-entitlements.zsh [path/to/VoiceKey.app]

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/.build/VoiceKey.app}"

if [[ ! -d "$APP" ]]; then
  print -u2 "verify-app-entitlements: no app bundle at $APP"
  exit 1
fi

# Every key here is load-bearing at runtime. An entitlement missing from the
# signature is silent; a usage description missing from Info.plist means macOS
# refuses to prompt at all.
typeset -a REQUIRED_ENTITLEMENTS REQUIRED_INFO_KEYS
REQUIRED_ENTITLEMENTS=(
  com.apple.security.device.audio-input      # microphone; v0.2.0/v0.2.1 incident
  com.apple.security.automation.apple-events # pausing other players
)
REQUIRED_INFO_KEYS=(
  NSMicrophoneUsageDescription
  NSAppleEventsUsageDescription
)

failures=0

fail() {
  print -u2 "  MISSING: $1"
  (( failures += 1 ))
}

print "verify-app-entitlements: $APP"

# --- embedded entitlements, read back out of the signature -------------------
if ! entitlements="$(codesign -d --entitlements :- "$APP" 2>/dev/null)"; then
  print -u2 "  the bundle is not signed, so it carries no entitlements at all"
  print -u2 "  (build-app.zsh ad-hoc signs when no Developer ID is available)"
  exit 1
fi

for key in $REQUIRED_ENTITLEMENTS; do
  if print -r -- "$entitlements" | grep -q "$key"; then
    print "  ok: entitlement $key"
  else
    fail "entitlement $key"
  fi
done

# --- the Info.plist that actually shipped inside the bundle ------------------
INFO="$APP/Contents/Info.plist"
if [[ ! -f "$INFO" ]]; then
  print -u2 "  MISSING: Contents/Info.plist"
  exit 1
fi

for key in $REQUIRED_INFO_KEYS; do
  if value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$INFO" 2>/dev/null)" \
    && [[ -n "$value" ]]; then
    print "  ok: Info.plist $key"
  else
    fail "Info.plist $key"
  fi
done

if (( failures > 0 )); then
  print -u2 "verify-app-entitlements: $failures missing — this build would ship broken"
  exit 1
fi

print "verify-app-entitlements: all required keys present in the artifact"
