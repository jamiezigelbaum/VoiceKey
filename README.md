# VoiceKey

VoiceKey is a tiny macOS menu bar app for hotkey-driven access to realtime AI
voice providers.

Each voice profile pairs a global hotkey with a provider and its settings, so a
single key press — or a button on a USB macropad — starts a voice session with
the provider, model, voice, and instructions you assigned to it. The default
profile talks to the OpenAI Realtime API on `F16`; additional profiles can use
OpenClaw Talk to reach an OpenClaw gateway's assistant, ChatGPT Web sign-in,
a Custom Realtime Endpoint for a self-hosted assistant, or any other provider
adapter as it lands.

## Install

Download `VoiceKey-0.2.0-macOS.dmg` from the latest GitHub Release, open it,
and drag `VoiceKey.app` into `/Applications`.

On first launch VoiceKey opens Settings automatically:

1. A default profile (OpenAI Realtime API, hotkey `F16`) is already there.
   Enter your API key — it is stored in the macOS Keychain. ChatGPT Web
   profiles use provider sign-in instead of a key.
2. Grant microphone permission if macOS asks. If you deny it, VoiceKey shows
   an alert with a button that opens the VoiceKey pane in System Settings >
   Privacy & Security > Microphone.
3. Press `F16` to start and stop a voice session with the default profile.

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
- App-owned voice profiles, provider selection, and voice session lifecycle.
- App-owned global hotkeys, one per voice profile.
- App-owned microphone permission.
- Browser-free day-to-day workflow for API providers after first setup.

## Current Status

This is an early native Swift/AppKit app with:

- menu bar controls
- bundled app icon
- animated menu bar icon that reflects the session state: a spinning arc while
  connecting, distinct listening, thinking, and speaking motion during a live
  session, and a red badge when attention is needed
- multiple voice profiles, each with its own global hotkey, provider, model,
  voice, instructions, and optional endpoint URL
- a rebuilt settings window that edits all profiles side by side: per-profile
  configuration is kept when you switch providers, instructions are a
  multi-line field, and conflicting hotkey recordings are detected
- a decluttered menu with a Troubleshooting submenu
- a Custom Realtime Endpoint provider for OpenAI-Realtime-compatible servers
- an OpenClaw Talk provider that turns VoiceKey into an interactive voice
  client of an OpenClaw gateway's Talk realtime channel, with zero-config
  gateway discovery on machines running OpenClaw
- OpenAI Realtime API provider over WebSocket as the default path, with live
  WebSocket/session-update smoke coverage and mic-to-model-to-audio validation
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

OpenAI Realtime mic-to-model-to-audio was validated in the built menu bar app on
June 14, 2026. The next milestone is provider adapter hardening for Gemini Live
and Deepgram Voice Agent, plus release polish around first-run microphone
permission and speaker feedback guidance.

## Build From Source

```zsh
swift build
```

To build an app bundle:

```zsh
./scripts/build-app.zsh
open .build/VoiceKey.app
```

To regenerate the production app icon (drawn fully procedurally; also refreshes
the `design/voicekey-app-icon-master.png` reference render):

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

VoiceKey runs from the menu bar. Open `Settings...` to manage voice profiles.
Each profile is a complete voice preset:

- a global hotkey (recorded in Settings; profile 1 defaults to `F16`)
- a provider (OpenAI Realtime API, OpenClaw Talk, ChatGPT Web, or a Custom
  Realtime Endpoint)
- model, voice, and instructions for that provider
- an optional endpoint URL

Multiple profiles mean multiple hotkeys: press one key for your fast general
assistant, another for a slow, careful one, a third for a self-hosted model.
This maps naturally onto a USB macropad — for example a 3-button DOYO pad —
whose buttons send otherwise-unused function keys. Assign each button's key to
a profile in Settings and the pad becomes a row of dedicated voice buttons.

The Custom Realtime Endpoint provider connects to any server that speaks the
OpenAI Realtime WebSocket protocol. Enter its `wss://` (or `https://`) URL in
the profile's endpoint field; an API key is optional and, when set, is stored
in the Keychain like any other provider key. This is the intended path for
self-hosted assistants.

### Tools via MCP

OpenAI Realtime API and Custom Realtime Endpoint profiles can declare remote
MCP servers in Settings. The realtime channel owns and executes those tools;
VoiceKey only sends the server declarations and reports their lifecycle in the
session log. VoiceKey never executes a tool locally. Optional MCP authorization
tokens are stored in the macOS Keychain, not in the saved profile.

For example, an “Assistant” profile could declare a server labeled `calendar`
at `https://mcp.example.com` and limit it to `search_events, create_event`.
During a voice session the channel can use those tools, while VoiceKey shows
the MCP call as thinking and records the server and tool names in diagnostics.

The OpenClaw Talk provider turns VoiceKey into an interactive voice client of
an OpenClaw gateway's Talk realtime channel: the gateway owns the OpenAI
Realtime session and consults your OpenClaw agent (for example Castor, agent
`main`) as the brain. On a machine with OpenClaw installed there is nothing to
configure — VoiceKey discovers the gateway token from
`~/.openclaw/secrets/*gateway-token*` and, when this Mac has been paired via
the OpenClaw app/CLI, authenticates with the paired-device identity in
`~/.openclaw/identity` (`device.json` + `device-auth.json`) for scoped access,
falling back to the bare gateway token. VoiceKey tries `ws://127.0.0.1:18790`
first (the conventional SSH tunnel endpoint for a remote workspace, e.g.
`ssh -N -L 18790:127.0.0.1:18789 <host>`), then `ws://127.0.0.1:18789` for a
gateway running on this Mac. Non-standard setups can override both in
Settings: an endpoint URL and a gateway token stored in the Keychain. Create a
profile named after your agent (for example "Castor"), choose OpenClaw Talk,
and record a hotkey: press to talk, press again to hang up, and just start
speaking to barge in. Model and voice come from the gateway's OpenAI Realtime
config in `openclaw.json`, not from the profile.

Choose `Check API Connection` to verify an API provider key, model, WebSocket
connection, and session-update contract before starting a microphone session.

The menu shows each profile's hotkey in the native shortcut column. The menu
bar icon is animated: a spinning arc while a session connects, listening,
thinking, and speaking motion while a session is live, and a red badge when
something needs attention.

Troubleshooting actions live under the menu's `Troubleshooting` submenu:
`Show Session Log` for timestamped provider status changes, diagnostics, and
streamed transcript text during live testing, and `Copy Session Log` to share
the same live-test evidence without taking screenshots.

If the voice provider appears to hear phrases you did not say, change macOS audio output to
headphones or another output path that the microphone cannot hear. VoiceKey
sends one start click per hotkey press; repeated phantom turns are usually speaker
audio feeding back into the microphone.

## Privacy

VoiceKey stores provider API keys in the macOS Keychain. Realtime audio is sent
to the provider of the profile whose hotkey you pressed — including a Custom
Realtime Endpoint you configured yourself. The ChatGPT Web option keeps
authentication inside the provider web session rather than storing an API key.
An OpenClaw Talk profile sends audio to your OpenClaw gateway; an optional
gateway-token override is stored in the Keychain like any other credential,
and auto-discovered gateway tokens and paired-device credentials are read from
`~/.openclaw/secrets` and `~/.openclaw/identity` at connection time and never
logged.

## Architecture

VoiceKey is intentionally small:

- `VoiceKeyAppDelegate`: menu bar, profile, and hotkey lifecycle.
- `VoiceProfile` and `VoiceProfileStore`: a profile (hotkey + provider +
  model/voice/instructions + endpoint URL) and its `UserDefaults` persistence.
- `GlobalHotKey`: Carbon `RegisterEventHotKey` wrapper; supports multiple
  simultaneous registrations, one per profile.
- `HotKeyConfiguration`: Codable hotkey description stored on each profile.
- `VoiceProvider`: provider-neutral realtime voice session contract and settings.
- `VoiceProviderFactory`: per-profile provider adapter construction.
- `OpenAIRealtimeProvider`: OpenAI Realtime WebSocket session and event mapping;
  also backs Custom Realtime Endpoint profiles against the configured URL.
- `OpenClawTalkProvider`: client for an OpenClaw gateway's Talk realtime
  channel. The gateway WebSocket protocol is a connect handshake, a
  `talk.session.create` request, streamed `appendAudio` frames, `talk.event`
  relay envelopes back, and a close; audio is base64 PCM16 at 24 kHz in both
  directions. The gateway token is auto-discovered from
  `~/.openclaw/secrets/*gateway-token*`; on a paired Mac the connect handshake
  is additionally signed with the device identity from `~/.openclaw/identity`
  (`device.json` + `device-auth.json`) and requests only the device's
  gateway-approved scopes, falling back to the bare token otherwise. Endpoints
  are probed in order (`ws://127.0.0.1:18790`, then `ws://127.0.0.1:18789`),
  and both can be overridden per profile.
- `ChatGPTWebProvider`: adapter that keeps the web sign-in/OAuth path behind the
  same provider contract.
- `GeminiLiveProvider` and `DeepgramVoiceAgentProvider`: planned realtime
  provider adapter slots with provider-specific capabilities.
- `MenuBarIconRenderer` and `MenuBarIconAnimator`: animated menu bar icon
  rendering (~12 fps) for connecting, live, and attention states.
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
OpenClaw Talk is the zero-config path on machines that already run an OpenClaw
gateway.
