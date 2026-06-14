# VoiceKey

VoiceKey is a tiny macOS menu bar app for one-key access to realtime AI voice
providers.

The default provider is OpenAI Realtime API access. ChatGPT Web sign-in remains
available as an OAuth-style compatibility option, and the app is being shaped
around a provider-neutral voice session layer so users can choose the realtime
voice API they want to use as additional adapters land.

## Install

Download `VoiceKey-0.1.0-macOS.dmg` from the latest GitHub Release, open it,
and drag `VoiceKey.app` into `/Applications`.

On first launch:

1. Open `Settings...` from the menu bar item.
2. Choose a provider. API providers store their keys in Keychain; ChatGPT Web
   uses provider sign-in.
3. Grant microphone permission if macOS asks.
4. Press `F16` to toggle VoiceKey voice.

Homebrew Cask is available for the unsigned prerelease:

```zsh
brew tap jamiezigelbaum/voicekey
brew install --cask voicekey
```

This build is not Apple Developer ID signed or notarized yet. macOS may require
right-clicking `VoiceKey.app` and choosing Open, or approving it in System
Settings > Privacy & Security.

## Goals

- Self-contained native macOS menu bar app.
- No Hammerspoon, browser extension, Electron, or third-party package manager.
- App-owned provider selection and voice session lifecycle.
- App-owned global hotkey.
- App-owned microphone permission.
- Browser-free day-to-day workflow for API providers after first setup.

## Current Status

This is an early native Swift/AppKit app with:

- menu bar controls
- bundled app icon
- dynamic menu bar icon that reflects the configured hotkey and provider state
- configurable global hotkey, defaulting to F16
- settings window for recording a new hotkey and configuring the selected voice provider
- provider-neutral realtime voice session contract
- OpenAI Realtime API provider over WebSocket as the default path, with live
  WebSocket/session-update smoke coverage
- ChatGPT Web provider as a sign-in/OAuth fallback path
- menu action for checking an API provider connection without starting the microphone
- Keychain-backed provider API key storage
- native microphone capture and streamed audio playback
- persistent `WKWebView` session for `chatgpt.com`
- WebKit microphone permission hook
- DOM-to-native-click bridge for ChatGPT Voice controls
- visible provider status for loading, sign-in required, ready, starting, active,
  stopping, and needs-attention states
- secret-safe `Copy Diagnostics` menu output for provider readiness and live
  session debugging
- fixture-tested DOM probes that distinguish ChatGPT Voice Mode from text
  dictation controls

The next milestone is human mic/speaker end-to-end testing of the OpenAI
Realtime API path, followed by additional provider adapters for Gemini Live and
Deepgram Voice Agent.

## Build From Source

```zsh
swift build
```

To build an app bundle:

```zsh
./scripts/build-app.zsh
open .build/VoiceKey.app
```

To regenerate the production app icon from the design master:

```zsh
python3 -m venv /tmp/voicekey-icon-venv
/tmp/voicekey-icon-venv/bin/python -m pip install pillow
/tmp/voicekey-icon-venv/bin/python ./scripts/generate_app_icon.py
```

To package a local release:

```zsh
./scripts/package-release.zsh
```

See [docs/RELEASE.md](docs/RELEASE.md) for signing, notarization, GitHub
Release, and Homebrew cask steps.

## Usage

VoiceKey runs from the menu bar. Open `Settings...` to choose a realtime
provider, model, voice, instructions, and credentials. API keys are stored in
the macOS Keychain and can be replaced or removed from Settings. ChatGPT Web
uses its normal sign-in flow in VoiceKey's provider window instead of an API key.

Choose `Check API Connection` to verify an API provider key, model, WebSocket
connection, and session-update contract before starting a microphone session.

The menu shows the currently assigned voice hotkey in the native shortcut column.
The menu bar icon shows a compact version of the same hotkey, plus a simple
shape state: ready, loading, attention, or voice active. Choose `Settings...` to
record a different global hotkey.

Choose `Show Session Log` to inspect timestamped provider status changes,
diagnostics, and streamed transcript text during live testing. Choose `Copy
Session Log` to share the same live-test evidence without taking screenshots.

If the voice provider appears to hear phrases you did not say, change macOS audio output to
headphones or another output path that the microphone cannot hear. VoiceKey
sends one start click per F16 press; repeated phantom turns are usually speaker
audio feeding back into the microphone.

## Privacy

VoiceKey stores provider API keys in the macOS Keychain. Realtime audio is sent
to the provider selected in Settings. The ChatGPT Web option keeps authentication
inside the provider web session rather than storing an API key.

## Architecture

VoiceKey is intentionally small:

- `VoiceKeyAppDelegate`: menu bar and hotkey lifecycle.
- `GlobalHotKey`: Carbon `RegisterEventHotKey` wrapper.
- `VoiceProvider`: provider-neutral realtime voice session contract and settings.
- `VoiceProviderFactory`: selected-provider adapter construction.
- `OpenAIRealtimeProvider`: OpenAI Realtime WebSocket session and event mapping.
- `ChatGPTWebProvider`: adapter that keeps the web sign-in/OAuth path behind the
  same provider contract.
- `GeminiLiveProvider` and `DeepgramVoiceAgentProvider`: planned realtime
  provider adapter slots with provider-specific capabilities.
- `VoiceSessionLog` and `SessionLogWindowController`: live provider diagnostics
  and transcript inspection.
- `RealtimeAudioEngine`: native microphone capture, audio conversion, and playback.
- `APIKeyStore`: Keychain-backed provider credential storage.
- `WebWindowController`: persistent `WKWebView`, mic permission, native click bridge.
- `ChatGPTProvider`: provider-specific status, retry, and start/stop behavior.
- `ChatGPTDOMProbe`: ChatGPT DOM selectors shared by the app and fixture tests.

Realtime provider support should stay behind a simple shape:

```text
prepare()
update(configuration:)
toggleVoice()
stopVoice()
showProviderInterface()
reloadProviderInterface()
events: status, transcript, diagnostic
```

## Notes

OpenAI Realtime is the default product path. ChatGPT Web remains selectable for
users who prefer provider sign-in or do not want to configure API access.
