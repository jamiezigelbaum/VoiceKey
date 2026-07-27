# Changelog

## Unreleased

Setting VoiceKey up is now a guided walkthrough instead of a settings hunt.

- **First-run setup assistant.** A new Mac is taken through the whole
  path — what to connect, credentials, microphone access, and a hotkey —
  instead of opening an empty Settings window. It reopens from the menu
  ("Setup Assistant…") whenever you want to add another service.
- **"What would you like to connect?"** The assistant starts by offering the
  services VoiceKey can actually connect today: the OpenAI Realtime API and
  OpenClaw Talk. Pick either or both; each one is then set up in turn.
- **A real OpenClaw connection walkthrough.** Connecting to an OpenClaw
  gateway used to mean pasting a token into Settings and reading raw protocol
  errors. VoiceKey now finds this Mac's existing OpenClaw pairing on its own,
  and when the gateway needs the device approved it says so plainly, shows the
  request waiting for approval, and keeps retrying until you approve it —
  rather than failing once with "pairing required" and stopping.
- **The credential in use is visible and recoverable.** When VoiceKey is using
  this Mac's own OpenClaw pairing it says so, and no longer offers an empty
  paste field that invites overwriting a working connection with a stale
  token. Every connection test names which credential it used, and a token the
  gateway rejects offers one-click recovery back to the Mac's own pairing.
- **Errors name the right machine.** When the gateway's own AI provider key is
  the thing being rejected, VoiceKey says so and points at the Mac running
  OpenClaw, instead of surfacing a raw upstream error that reads as though
  your VoiceKey key were wrong. Key fragments are stripped from the log.
- **Settings: Test Connection** for OpenClaw channels, reporting the gateway
  version and what it authorized.
- The setup assistant records its walkthrough in the session log
  (`~/Library/Logs/VoiceKey/session-*.log`) — steps, outcomes, and failures,
  with no keys or tokens.

## 0.2.2 - 2026-07-24

Critical fix: the microphone works on fresh installs.

- v0.2.0 and v0.2.1 were signed with a hardened runtime but no
  entitlements, which silently blocks all microphone access on any Mac
  that hadn't previously granted it: macOS reported VoiceKey as denied
  without ever showing the permission prompt, and the app never appeared
  in System Settings > Privacy & Security > Microphone. All signed
  builds now carry the audio-input entitlement, so the standard
  permission prompt appears on first use. If you installed an earlier
  version, update and start a voice session; macOS will ask for
  microphone access normally.

## 0.2.1 - 2026-07-24

Auto-apply settings, voice-channel UX overhaul, and reliability sweep.

- Settings now auto-apply: every change (fields, toggles, add/duplicate/
  delete channel, API keys, MCP servers) commits immediately — the Save
  button is gone, and closing the window can no longer discard edits.
  Deleting a channel takes effect at its confirmation dialog and releases
  its hotkey instantly.
- "Profiles" are now "voice channels" throughout, ordered by hotkey in the
  menu and picker, with add/duplicate/delete controls and plain-language
  provider descriptions ("OpenAI Realtime API" vs "ChatGPT (web)").
- Fixes 19 reliability issues found in an adversarial review, including:
  typed API keys being silently discarded on channel switch; a live
  session's menu state being clobbered by another channel's failed start
  (which could then stop the wrong session); custom-endpoint channels
  sharing one API-key slot (now per-channel, with migration); phantom
  hotkey registrations from unsaved channels; stuck "stopping" states
  (now watchdogged); menu shortcut glyphs showing the wrong key; "Clear
  Session Log" not clearing the on-disk transcript; and honest reporting
  when a shortcut cannot work globally without Accessibility access.
- Failed session starts now open Settings focused on the misconfigured
  channel instead of failing silently; fresh installs are guided to record
  a hotkey rather than defaulting to F16 (absent on laptop keyboards).
- OpenAI Realtime channels default to gpt-realtime-2.1, and the OpenAI
  web-search tool loads faster; the model speaks tool results reliably
  after server-side calls.
- Speaker mode (open-speaker echo protection with energy-gated barge-in,
  introduced for OpenAI channels in 0.2.0) now also protects OpenClaw
  Talk channels; consult timeouts are idle-based with live per-tool
  progress, so long agent tasks are never cut off while visibly working.
- The ChatGPT (web) channel drives chatgpt.com more precisely (per-host
  browser identity, native clicks), though GPT-Live voice remains
  unsupported inside embedded windows (documented in
  docs/CHATGPT_WEB_CHANNEL_STATUS.md); dev builds are Developer-ID signed
  so permission grants persist across rebuilds.
- New sessions carry no default assistant instructions (the app no longer
  tells assistants they are "VoiceKey").

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
