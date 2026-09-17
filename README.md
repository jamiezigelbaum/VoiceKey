# VoiceKey

VoiceKey is a small macOS menu bar app that turns a hotkey into a live voice
conversation with an AI assistant.

Each voice channel pairs a global hotkey with a provider and its settings, so
one key press — or one button on a USB macropad — opens a realtime voice
session with the model, voice, and instructions you chose. Press again to hang
up. Speak over the assistant to interrupt it.

Providers today:

- **OpenAI Realtime API** — your own API key, `gpt-realtime-2.1` by default,
  with built-in web search and optional remote MCP servers.
- **OpenClaw Talk** — a voice client for an [OpenClaw](https://openclaw.ai)
  gateway's Talk channel, so your OpenClaw agent answers with its own tools
  and memory. Zero configuration on a Mac that already runs OpenClaw.
- **Custom Realtime Endpoint** — any server that speaks the OpenAI Realtime
  WebSocket protocol, for self-hosted assistants.
- **ChatGPT (web)** — your ChatGPT subscription in an embedded window, for
  people who would rather sign in than configure an API key.

See [docs/ROADMAP.md](docs/ROADMAP.md) for what is planned next, including
GPT-Live and a pluggable backend for any agent harness.

## Install

Requires macOS 13 Ventura or later. Builds are Developer ID signed and
notarized.

With Homebrew:

```zsh
brew tap jamiezigelbaum/voicekey
brew install --cask voicekey
```

Or download `VoiceKey-<version>-macOS.dmg` from the
[latest release](https://github.com/jamiezigelbaum/VoiceKey/releases/latest),
open it, and drag `VoiceKey.app` into `/Applications`.

On first launch a setup assistant walks you through it:

1. Pick what to connect: the OpenAI Realtime API, OpenClaw Talk, or both.
2. Enter your OpenAI API key if you chose it. Keys are stored in the macOS
   Keychain. OpenClaw needs nothing typed on a Mac that is already paired.
3. Grant microphone access when macOS asks.
4. Record a hotkey. Any otherwise-unused key works; `F16`–`F19` are good
   choices on an extended keyboard or macropad.

Press the hotkey to start talking. The menu bar icon shows the session state:
a spinning arc while connecting, distinct listening, thinking, and speaking
motion during a session, and a red badge when something needs attention.

## Usage

VoiceKey lives in the menu bar. `Settings…` manages voice channels. Each
channel is a complete preset:

- a global hotkey
- a provider
- model and voice, where the provider lets you choose
- an optional endpoint URL
- optional instructions under "Advanced" — empty by default; VoiceKey adds no
  personality of its own

Multiple channels mean multiple hotkeys: one key for a fast general
assistant, another for a careful one, a third for a self-hosted model. This
maps naturally onto a USB macropad whose buttons send function keys; assign
each button's key to a channel and the pad becomes a row of voice buttons.

Settings apply as you change them. There is no Save button.

### Built-in web search

OpenAI Realtime channels include web search by default. VoiceKey declares a
`search_web` function to the realtime model and runs the search through the
OpenAI Responses API with the same key. Nothing else to configure; it can be
turned off per channel.

### Advanced tools via MCP

OpenAI Realtime and Custom Realtime Endpoint channels can declare remote MCP
servers under Advanced. OpenAI executes those servers inside the realtime
session; VoiceKey sends the declarations and records tool names in the
session log. Optional MCP authorization tokens go in the Keychain, not in the
saved channel.

### OpenClaw Talk

The gateway owns the realtime session and consults your OpenClaw agent as the
brain, so the agent's tools, memory, and persona all apply. On a Mac with
OpenClaw installed VoiceKey discovers the gateway token from
`~/.openclaw/secrets/*gateway-token*` and, when the Mac has been paired
through the OpenClaw app or CLI, authenticates with the paired-device
identity in `~/.openclaw/identity`. It tries `ws://127.0.0.1:18790` first
(the conventional SSH tunnel to a remote gateway, for example
`ssh -N -L 18790:127.0.0.1:18789 <host>`), then `ws://127.0.0.1:18789` for a
local gateway. Both the endpoint and the token can be overridden per channel.
Model and voice come from the gateway's configuration, not the channel.

### Custom Realtime Endpoint

Enter the server's `wss://` (or `https://`) URL in the channel's endpoint
field. An API key is optional and stored in the Keychain when set.

### Troubleshooting

The menu's `Troubleshooting` submenu has `Check API Connection`, which
verifies a key, model, and session contract without opening the microphone;
`Show Session Log`, a timestamped record of provider status, diagnostics, and
transcript; and `Copy Session Log` for sharing that record. The log never
contains keys or tokens, so it is safe to paste into a bug report.

If the assistant hears phrases you did not say, your speakers are feeding the
microphone. VoiceKey runs system echo cancellation and an energy-gated
barge-in, but headphones are the reliable fix.

## Privacy

VoiceKey runs no service of its own and holds no credentials of its own.
Audio goes to the provider of the channel whose hotkey you pressed and nowhere
else. API keys and tokens live in the macOS Keychain. Auto-discovered OpenClaw
credentials are read from `~/.openclaw` at connection time and never logged.
Web search uses your own OpenAI key through the OpenAI Responses API.

## Build From Source

```zsh
swift build && swift test
./scripts/build-app.zsh
open .build/VoiceKey.app
```

`build-app.zsh` signs with `VOICEKEY_SIGN_IDENTITY` if set, otherwise with
the first Developer ID identity in your keychain, otherwise ad hoc. A stable
signature matters during development because macOS ties microphone and
accessibility grants to it.

To regenerate the app icon (drawn procedurally, also refreshes
`design/voicekey-app-icon-master.png`):

```zsh
python3 -m venv .venv && .venv/bin/pip install pillow
.venv/bin/python scripts/generate_app_icon.py
```

Release packaging, notarization, and the Homebrew cask are covered in
[docs/RELEASE.md](docs/RELEASE.md). Ground-truth probes against the real
OpenAI and OpenClaw endpoints are indexed in
[scripts/dev/README.md](scripts/dev/README.md).

## Architecture

VoiceKey is intentionally small. The pieces that matter:

- `VoiceKeyAppDelegate`: menu bar, channel, and hotkey lifecycle.
- `VoiceProfile` / `VoiceProfileStore`: a channel and its `UserDefaults`
  persistence.
- `GlobalHotKey`: Carbon `RegisterEventHotKey` wrapper, one registration per
  channel.
- `VoiceProvider`: the provider-neutral session contract.
- `VoiceProviderFactory`: builds the adapter for a channel.
- `OpenAIRealtimeProvider`: OpenAI Realtime WebSocket session and event
  mapping; also backs Custom Realtime Endpoint channels.
- `OpenClawTalkProvider`: the OpenClaw gateway protocol — connect handshake,
  `talk.session.create`, streamed `appendAudio` frames, `talk.event` relay
  envelopes back, and close; base64 PCM16 at 24 kHz both ways.
- `ChatGPTWebProvider`, `WebWindowController`, `ChatGPTDOMProbe`: the
  embedded web path.
- `RealtimeAudioEngine`: single-engine capture and playback with Apple voice
  processing for echo cancellation, surviving device changes mid-session.
- `MediaPlaybackController`: pauses Music or Spotify while a channel listens
  and resumes it after.
- `OnboardingWizardController`: the first-run setup assistant.
- `MenuBarIconRenderer` / `MenuBarIconAnimator`: the animated icon.
- `VoiceSessionLog`: the secret-safe session log.
- `APIKeyStore`: Keychain-backed credentials.

A provider adapter implements a simple shape:

```text
prepare()
update(configuration:)
toggleVoice()
stopVoice()
events: status, transcript, diagnostic
```

`GeminiLiveProvider` and `DeepgramVoiceAgentProvider` are placeholder slots
for adapters that have not been built yet.

## License

MIT. See [LICENSE](LICENSE).
