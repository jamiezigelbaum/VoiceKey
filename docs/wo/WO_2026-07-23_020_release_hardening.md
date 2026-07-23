# WO 2026-07-23 — VoiceKey 0.2.0 release hardening

Three independent work orders (disjoint file surfaces), all branched from
`codex/realtime-provider-voicekey` at a172f73. Each WO is self-contained:
a fresh session with only this doc and the repo can execute it. Findings
come from a three-way adversarial review of commit a172f73; file:line
references were verified against that commit.

Standing authority for every WO: **skip-and-flag** — if a leg's
prerequisite isn't met, its risk is unclear, or a fix balloons beyond the
stated scope, SKIP the leg and FLAG why in your summary. Never land
partial or broken work. Commit locally on your branch; never push, merge,
or switch branches. Acceptance for every WO: `swift test` fully green in
your worktree (194 pre-existing tests plus your new ones), `swift build`
clean.

Project conventions: Swift/AppKit menu bar app, no third-party
dependencies, tests are XCTest under Tests/VoiceKeyTests. Match existing
code style; comments only for non-obvious constraints. No Co-Authored-By
or AI trailers in commits.

---

## WO-A: Hotkey routing and settings lifecycle

Surface: `Sources/VoiceKey/GlobalHotKey.swift`,
`Sources/VoiceKey/VoiceKeyAppDelegate.swift`,
`Sources/VoiceKey/SettingsWindowController.swift`,
`Sources/VoiceKey/VoiceProfile.swift`, plus tests.

### Verified facts (do not re-investigate)

- `GlobalHotKey.swift:18-25`: each `GlobalHotKey` installs its own Carbon
  handler for `kEventHotKeyPressed` on the same application event target,
  never reads the `EventHotKeyID` from the event, unconditionally invokes
  its own callback, and returns `noErr` (stopping the handler chain).
  With 2+ registered hotkeys, every hotkey fires only the
  most-recently-installed handler's profile.
- `VoiceKeyAppDelegate.swift:253-264`: `carbonHotKeyID(for:)` computes a
  31-bit FNV-1a id per profile that is currently never consulted at
  dispatch time.
- `VoiceKeyAppDelegate.swift:631-651` (`didRecordHotKey`): looks up the
  profile in the delegate's saved `profiles` array, so recording a hotkey
  for a profile added in Settings but not yet saved always returns false
  ("That shortcut could not be registered",
  `SettingsWindowController.swift:616-623`).
- `VoiceKeyAppDelegate.swift:612-629` (`didUpdateProfiles`): when the
  active profile is deleted, `activeProfileID` is nulled but the running
  provider is not stopped; if the replacement profile has the same
  `providerID`, `updateProviderConfiguration`
  (`VoiceKeyAppDelegate.swift:405-416`) takes the `update(configuration:)`
  branch and the live session (and microphone) keeps running with no menu
  item reflecting it.
- `SettingsWindowController.swift:593-605` (`providerChanged`): after
  `commitFormToWorkingCopy()`, model and voice are overwritten with the
  new provider's defaults, so toggling provider A → B → A discards the
  profile's custom model/voice.
- `VoiceKeyAppDelegate.swift:267-273`: the local keyDown monitor consumes
  any keystroke matching a profile hotkey even while the Settings window
  is key, so pressing an existing combo while focused in the hotkey
  recorder toggles a session instead of being recorded.
- `SettingsWindowController.swift:688-703` (`removeAPIKey`): passes the
  unsaved working copy to `didUpdateProfiles` without persisting, so
  runtime profiles and `VoiceProfiles.v1` diverge until the next Save.
- `VoiceProfile.swift:105-115`: `freshInstallProfile` ships
  `instructions: ""` (sent verbatim in `session.update`), while
  `SettingsWindowController.swift:386` uses `defaultInstructions` —
  inconsistent first-run behavior.
- Sound (leave alone): persistence round-trip, legacy single-profile
  migration, F16 special-casing, provider replacement hygiene in
  `configureProvider()`, `GlobalHotKey` registration/unregistration
  mechanics, menu rebuild.

### Required behavior

1. Install ONE Carbon event handler (installed once, e.g. a shared
   dispatcher), read `EventHotKeyID` via
   `GetEventParameter(kEventParamDirectObject, typeEventHotKeyID, ...)`,
   and dispatch to the matching registration. Multiple profiles with
   hotkeys must each route to their own callback. Keep the existing
   public `GlobalHotKey` surface as close to unchanged as practical.
2. `didRecordHotKey` must validate/register hotkeys for unsaved
   working-copy profiles (recording in Settings before first Save must
   work).
3. Deleting the active profile must stop the running provider/session
   before reconfiguration — the microphone must never survive its
   profile.
4. Switching provider in Settings must not clobber the profile's saved
   model/voice: restore them when switching back (per-provider stash or
   equivalent), matching how instructions/endpoint already survive.
5. While the Settings window is key, profile hotkey combos must not be
   swallowed by the local keyDown monitor (the recorder must receive
   them; global hotkeys may still fire when Settings is not key).
6. `removeAPIKey` must not hand unsaved working-copy profiles to the
   delegate (persist first or scope the call to saved state).
7. Unify first-run instructions defaulting between `freshInstallProfile`
   and `makeDefaultProfile`.

### Acceptance

- New unit tests: hotkey-id → registration dispatch mapping (the routing
  logic must be testable without live Carbon dispatch — extract the
  id-matching into a testable component); recording for unsaved profiles;
  active-profile deletion stops the provider (use a fake provider).
- `swift test` and `swift build` green.

---

## WO-B: OpenAI realtime provider hardening

Surface: `Sources/VoiceKey/OpenAIRealtimeProvider.swift`,
`Sources/VoiceKey/OpenAIRealtimeRequestBuilder.swift`, `Info.plist`,
plus tests. (`VoiceProvider.swift` only if a shared type is unavoidable.)

### Verified facts (do not re-investigate)

- `OpenAIRealtimeProvider.swift:215-235` (`receiveLoop`): neither the
  success nor the failure branch checks task identity or a session
  generation. The failure branch's guard (`webSocketTask != nil &&
  !isStopping`) passes when a *stale* cancelled socket's error arrives
  after a new session has begun (profile switch does `stopVoice()` then
  `toggleVoice()` immediately, `VoiceKeyAppDelegate.swift:338-342`),
  wiping the new session's state, stopping its audio, emitting
  `needsAttention`, and leaking the new socket (its `didOpen` is then
  rejected by the identity guard at :319). `didCloseWith` (:334) does the
  identity check correctly — mirror it.
- `OpenAIRealtimeProvider.swift:32,36-42,174-182`: session flags are
  mutated from main thread (`stopVoice`/`toggleVoice`), the URLSession
  delegate queue (`didOpen`/`didClose`/`receiveLoop`/
  `startAudioStreaming`), and the AVCaptureDevice permission callback
  thread, with no synchronization. The :174 double-check is racy; the
  worst interleaving leaves the input engine running and tap installed
  (hot mic) while status shows Ready.
- `OpenAIRealtimeProvider.swift:91-96,266-277`: `stopVoice` enqueues
  `response.cancel` / `input_audio_buffer.clear` then cancels the socket;
  the send completion errors emit `needsAttention` on main *after* the
  `.ready` status — normal stop while assistant is speaking reliably ends
  in a spurious error.
- `Info.plist` has no `NSAppTransportSecurity` key: cleartext `ws://` to
  non-loopback hosts (LAN custom endpoints) is refused by ATS.
- `OpenAIRealtimeRequestBuilder.swift:6-25`: scheme-less input like
  `assistant.local:8443` parses `assistant.local` as the URL scheme, so
  normalization silently produces a broken request.
- `OpenAIRealtimeRequestBuilder.swift:32-36`: if the endpoint already has
  `?model=...`, a second `model` query item is appended.
- `OpenAIRealtimeProvider.swift:62-71`: `update(configuration:)` on a
  connected session sends `session.update` including `model`; the
  server rejects live model changes → stuck `needsAttention` with socket
  and mic still live.
- Sound (leave alone): `VoiceToggleDecision` semantics, the generation
  guard around the mic-permission prompt, the GA-protocol
  `sessionUpdateEvent` shape (validated live), mic teardown on all other
  terminal paths, auth-header omission for empty keys.

### Required behavior

1. `receiveLoop` callbacks (success and failure) must be ignored unless
   they belong to the current socket/session (task identity or session
   generation, mirroring `didCloseWith`). Stop/start in quick succession
   (the profile-switch path) must reliably yield a working new session.
2. Serialize all provider session state onto one serial context (serial
   `DispatchQueue` or equivalent) so main-thread controls, delegate
   callbacks, and the permission callback cannot interleave; the
   audio-engine start/stop ordering must close the hot-mic window.
3. Send-completion errors during an intentional stop/teardown must not
   emit `needsAttention` (track teardown intent; drop late errors).
4. Add `NSAppTransportSecurity` with `NSAllowsLocalNetworking` = true to
   `Info.plist`. Do NOT add `NSAllowsArbitraryLoads`.
5. Request builder: reject scheme-less endpoint input with a clear
   diagnostic (or normalize `host:port` explicitly to `wss://`); never
   emit a duplicate `model` query item.
6. `update(configuration:)` while connected must not send a `model`
   change on the live session (apply model changes on next session).

### Acceptance

- New unit tests: builder scheme-less input and duplicate-model cases;
  stale-callback rejection (abstract the socket/session identity so the
  guard is testable, following the pattern of the existing
  OpenAIRealtimeSessionStopTests fakes); no-error-after-intentional-stop.
- `swift test` and `swift build` green.

---

## WO-C: OpenClaw Talk provider hardening

Surface: `Sources/VoiceKey/OpenClawTalkProvider.swift` and
`Tests/VoiceKeyTests/OpenClawTalk*.swift` only.

### Verified facts (do not re-investigate)

- State (`pendingAudio`, `sessionID`, `webSocketTask`, `isSpeaking`,
  `hasCancelledOutput`, `nextRequestIDValue`, the `is*` flags;
  declarations around :592-614) is mutated from main
  (`stopVoice`/`toggleVoice`/`update`), the URLSession delegate queue
  (`receiveLoop`/`didOpen`/`didClose`/`handleEventText`, :792-830,
  :871-902), and the audio-engine queue (`queueMicrophoneAudio`/
  `handleInputActivity`, :997-1016) with no synchronization. Concrete
  crash: `teardownConnection()` reassigns `pendingAudio` on main while
  the audio queue is mid-append on the same `Data`.
- :736-761, :1047-1060: `timeoutInterval = 3` covers only the HTTP
  upgrade. If candidate 1 (`ws://127.0.0.1:18790`, the SSH-tunnel port)
  accepts the socket but the remote gateway never sends
  `connect.challenge`, the provider sits in `.starting` forever and
  never falls back to 18789. (Live repro risk is real: on this machine
  both ports accept connections.)
- :663-673 with :1027-1038: `stopVoice` enqueues `talk.session.close`
  then immediately cancels the socket; the send completion error emits
  `needsAttention` after the `.ready` status of a normal stop.
- :883-884 with :817-829: every incoming audio chunk resets
  `hasCancelledOutput = false`, so one barge-in re-sends
  `talk.session.cancelOutput` once per chunk until the gateway's `clear`
  arrives.
- :552-563 with :895-898: a *user transcript delta* maps to
  `.status(.listening)`, and any `.listening` event clears `isSpeaking`,
  which can suppress the local barge-in cancelOutput (:818) entirely.
- :449 vs :481: `sessionCreated` prefers `payload.sessionId` but relay
  envelopes match against `envelope.relaySessionId`; if the gateway ever
  returns distinct values, every envelope is dropped and the session
  hangs in `.starting`.
- :82: the token-only connect requests `["operator.admin",
  "operator.talk", "operator.write", "operator.read"]` — a voice client
  must not request `operator.admin`. (The paired-device path already
  requests only approved scopes.)
- :916-924: when device credentials exist but the challenge lacks a
  nonce, the code silently downgrades to token-only connect and the user
  is told to pair an already-paired Mac.
- :590: the URLSession retains its delegate and is never invalidated —
  every provider instance leaks along with its `RealtimeAudioEngine`.
- Sound (leave alone): audio math (9,600 bytes = 200 ms of 24 kHz PCM16),
  endpoint candidate ordering/dedup, `webSocketTask === task` guards,
  mic-permission generation counter, scope-retry reconnect mechanics,
  secret hygiene (no token ever logged; keep it that way), PEM/DER
  parsing and Ed25519 signing.

### Required behavior

1. Confine all provider state to one serial `DispatchQueue`; main-thread
   entry points and delegate/audio-queue callbacks hop onto it. No state
   is touched off-queue.
2. Post-open handshake watchdog per endpoint candidate: bounded time
   from socket open to `connect.challenge`, and from connect to
   hello-ok/session-created (3 s each is fine). On expiry, tear down that
   candidate and advance to the next; exhaustion yields a clear
   `needsAttention` diagnostic.
3. No `needsAttention` from send-completion errors during intentional
   teardown.
4. Reset `hasCancelledOutput` per assistant turn (e.g. on turn/response
   boundary or `clear`), not on every audio chunk; do not let
   server-side user-transcript deltas clear `isSpeaking` (only
   done/clear/turn-end events may).
5. Match relay envelopes against `relaySessionId` when the create
   payload provides one (fall back to `sessionId`).
6. Remove `operator.admin` from the token-only connect scope request.
   Change nothing else about scopes.
7. Emit a diagnostic (no secrets) when device credentials exist but the
   challenge carries no nonce, instead of silently downgrading.
8. Invalidate the URLSession (`finishTasksAndInvalidate` or
   `invalidateAndCancel`) on teardown so provider instances can
   deallocate.
9. Test coverage: the review found zero tests drive the stateful
   lifecycle (handshake, fallback, watchdog, stop-while-connected).
   Abstract the WebSocket behind a small protocol so a scripted fake can
   drive: challenge → signed connect → hello-ok → session create →
   ready; fallback on silent candidate (watchdog); stop during a live
   session sends `talk.session.close` and tears down. If this refactor
   balloons beyond the provider file + tests, skip-and-flag with a
   written plan instead.

### Acceptance

- New lifecycle tests as above; all existing OpenClawTalk tests still
  green (update them where behavior intentionally changed, e.g. scopes).
- `swift test` and `swift build` green.

---

## WO-D: Per-profile MCP servers for OpenAI-protocol profiles

Added 2026-07-23 afternoon. Gives OpenAI Realtime API and Custom Realtime
Endpoint profiles provider-side tools with zero VoiceKey execution.

### Verified facts (do not re-investigate)

- The OpenAI Realtime API executes remote MCP tools SERVER-SIDE. The
  client only declares them in `session.update` (or `response.create`)
  under the `tools` array: `{"type": "mcp", "server_label": ...,
  "server_url": ..., "allowed_tools": [...]?, "require_approval":
  "never", "authorization": <token>?}`. Clients observe lifecycle events
  (`mcp_list_tools.completed`, `response.mcp_call.in_progress`, ...) but
  never run tools. Source: developers.openai.com/api/docs/guides/realtime-mcp.
- Product principle (owner, 2026-07-23): VoiceKey NEVER executes tools.
  Tools live in the channel. Do not add any local tool executor.
- `OpenAIRealtimeRequestBuilder.sessionUpdateEvent`
  (Sources/VoiceKey/OpenAIRealtimeRequestBuilder.swift) currently builds
  the session dict with audio/instructions/model only, and
  `instructionsWithSessionContext` stamps session-start time — keep that.
- `VoiceProfile` (Sources/VoiceKey/VoiceProfile.swift) is Codable,
  persisted as JSON in UserDefaults key `VoiceProfiles.v1`; adding a new
  field must decode legacy payloads (decodeIfPresent + default).
- `APIKeyStore` (Sources/VoiceKey/APIKeyStore.swift) is the Keychain
  pattern for per-provider credentials.
- OpenClaw Talk profiles get tools via the gateway agent — MCP config
  must NOT apply to them (nor to ChatGPT Web).

### Required behavior

1. `VoiceProfile` gains `mcpServers: [MCPServerConfiguration]` (default
   empty; legacy profiles decode). `MCPServerConfiguration`: `label`
   (used as `server_label`), `urlString`, optional `allowedTools`
   (comma-separated in UI), and a stable id used to key an optional
   authorization token in the Keychain via the APIKeyStore pattern —
   the token itself never lives in UserDefaults.
2. `sessionUpdateEvent` declares each configured server as a `tools`
   entry with `require_approval: "never"`. Empty list → no `tools` key
   (exactly today's payload, byte-compatible).
3. Provider event mapping: surface MCP lifecycle events as session-log
   diagnostics (server label + tool name, never the authorization
   value), and map an in-progress MCP call to the existing "thinking"
   status so the menu bar animation reflects tool use.
4. Settings: for OpenAI Realtime API and Custom Realtime Endpoint
   profiles only, an "MCP Servers" section listing configured servers
   with add/edit/remove — fields: label, URL, allowed tools (optional),
   authorization token (optional, stored in Keychain, shown masked).
   Keep the UI minimal and consistent with the existing form style.
5. README: short section explaining tools-via-MCP (the channel owns the
   tools; VoiceKey never executes them), with one example profile.

### Acceptance

- Unit tests: builder tools-array shape incl. authorization inclusion
  and omission; no `tools` key when list empty; profile persistence
  round-trip incl. legacy decode; MCP lifecycle event mapping.
- `swift test` and `swift build` green.

---

## WO-E: OpenClaw Talk consult tool-call round-trip

Added 2026-07-23 evening. Release-gating: Castor voice is silent under
the gateway's `force-agent-consult` routing because VoiceKey drops the
relayed tool call.

### Verified facts (do not re-investigate)

- Live session log evidence (2026-07-23 16:15Z): connect, session
  create, ready, and user transcripts all work; after each finalized
  utterance the gateway relays a `talk.event` tool-call envelope
  (VoiceKey's mapper logs it as the diagnostic "talk.event.toolCall")
  and VoiceKey takes no further action; no audio ever returns.
- Gateway contract (docs.openclaw.ai/gateway/protocol): the client must
  (1) receive the relayed provider tool call (first supported tool:
  `openclaw_agent_consult`), (2) send a `talk.client.toolCall` request
  and receive a run id, (3) wait for the agent run's normal chat
  lifecycle events to conclude, then (4) send
  `talk.session.submitToolResult` with the `sessionId`, the result
  content, and optional flags (`willContinue`, `suppressResponse`).
  The submit request resolves only after the provider bridge's
  asynchronous completion signal.
- A `VOICE_CONFIRMATION_REQUIRED:<id>` marker can appear for actions
  needing spoken confirmation.
- Sources/VoiceKey/OpenClawTalkProvider.swift already has: a serial
  state queue, an injectable WebSocket abstraction with scripted
  lifecycle tests (Tests/VoiceKeyTests/OpenClawTalkLifecycleTests.swift),
  envelope mapping (see `talk.event` handling around the mapper), and
  request-ID plumbing. Extend these; do not restructure them.
- Surface: OpenClawTalkProvider.swift and OpenClawTalk* tests ONLY.

### Required behavior

1. Parse the relayed tool-call envelope fully (tool name, call id,
   arguments); keep a diagnostic that names the tool.
2. Drive the round-trip on the state queue: `talk.client.toolCall`
   request → hold the run id → observe the run's lifecycle events →
   `talk.session.submitToolResult` with the session id and the result
   the contract expects. Match the exact frame shapes defensively:
   unknown/missing fields produce a secret-free diagnostic, never a
   crash or a silent drop.
3. Surface consult progress as the existing "thinking" status so the
   menu bar animates while the agent works; return to listening after
   the submit resolves.
4. Timeout: if the run produces no conclusion within a bounded window
   (60 s default), submit a failure/expired tool result if the
   contract allows, emit a needsAttention-free diagnostic (the session
   itself stays alive and listening), and reset consult state.
5. `VOICE_CONFIRMATION_REQUIRED:<id>`: minimal viable handling — relay
   the marker text into the transcript/diagnostic stream so the user
   hears/sees the confirmation request; full confirmation UX may be
   skip-and-flagged with a written plan.
6. Multiple queued utterances: a second tool call arriving while one
   consult is in flight must not corrupt state (serialize or reject
   the newer one with a diagnostic — pick one, document it).

### Acceptance

- Scripted lifecycle tests: full happy-path round-trip (toolCall event
  → client.toolCall → lifecycle events → submitToolResult → session
  still live); timeout path; malformed envelope path; overlapping
  tool-call path.
- `swift test` and `swift build` green.
