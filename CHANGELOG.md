# Changelog

## 0.2.0 - 2026-07-17

Voice profiles, an OpenClaw Talk provider, and UX overhaul.

- Adds voice profiles: each profile pairs a global hotkey with a provider and
  its own model, voice, instructions, and endpoint URL, so multiple hotkeys
  (for example the buttons of a USB macropad) can trigger different voice
  providers.
- Adds a Custom Realtime Endpoint provider for OpenAI-Realtime-compatible
  servers: configure a `wss://` URL and an optional API key to drive a
  self-hosted assistant.
- Adds an OpenClaw Talk provider (Castor integration): VoiceKey becomes an
  interactive voice client of an OpenClaw gateway's Talk realtime channel.
  Press a profile hotkey to talk to your OpenClaw agent (for example Castor,
  agent `main`), press again to hang up, and barge in by simply speaking. The
  gateway owns the OpenAI Realtime session, so model and voice come from
  `openclaw.json` rather than the profile.
- Adds zero-config OpenClaw gateway discovery: the gateway token is read from
  `~/.openclaw/secrets/*gateway-token*` and local endpoints are tried in order
  (`ws://127.0.0.1:18790`, then `ws://127.0.0.1:18789` — the first is the
  conventional SSH tunnel endpoint for a remote workspace), with optional
  endpoint and gateway-token overrides in Settings (token stored in the
  Keychain).
- Adds system echo cancellation (Apple voice processing) on a rebuilt
  single-engine audio path, so speaker output no longer feeds back into the
  microphone and interrupts the assistant mid-reply.
- Survives audio output/input device changes during a live session (for
  example connecting AirPods): capture rebuilds against the new route
  instead of crashing, and audio-system failures now surface as status
  messages rather than aborting the app.
- Adds an animated menu bar icon: spinning arc while connecting, distinct
  listening, thinking, and speaking motion during a live session, and a red
  badge when attention is needed.
- Regenerates the app icon from an updated design master.
- Rebuilds the Settings window around profiles: per-profile configuration is
  no longer lost when switching providers, instructions are edited in a
  multi-line field, and conflicting hotkey recordings are detected.
- Declutters the menu, moving diagnostics and session-log actions into a
  Troubleshooting submenu.
- Opens Settings automatically on first run.
- Adds a microphone-permission-denied alert with a button that deep-links to
  the VoiceKey pane in System Settings.
- Fixes copy-log/diagnostics clobbering the provider status display.

## 0.1.0 - 2026-05-31

Initial public release candidate.

- Adds a native macOS menu bar app for toggling ChatGPT Voice.
- Adds a persistent ChatGPT web session in an embedded WebKit view.
- Adds a configurable global hotkey, defaulting to F16.
- Adds dynamic menu bar icon states for ready, loading, active voice, and attention.
- Adds a production app icon and release packaging scripts.
