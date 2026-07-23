# VoiceKey — session handoff (2026-07-23)

This document lets a new session take over from exactly where the previous
one stopped. Paste the **PROMPT FOR THE NEW SESSION** block into a fresh
session; everything below it is the reference the prompt points to.

---

## PROMPT FOR THE NEW SESSION (paste this)

> You are taking over the VoiceKey project mid-flight, acting as CTO/engineer
> for Jamie. Read `docs/SESSION_HANDOFF_2026-07-23.md` in
> `/Users/zig/Code/VoiceKey` in full before doing anything — it is the
> complete state of play. Branch is `codex/realtime-provider-voicekey`
> (54 commits ahead of `main`; everything committed and pushed; HEAD
> `baa078c`). The built app is running from `.build/VoiceKey.app`.
>
> **Hard-won operating rule for this project (do not repeat the prior
> failure mode):** never implement against an external protocol/API/hardware
> contract from inference or doc summaries. Ground-truth the real schema
> (server source, real endpoint error responses, live probes) FIRST, then
> implement once, then validate against the REAL thing before handing
> anything to Jamie. Tests that assert your own invented frame shapes
> against a self-authored fake prove nothing. Verify actual outcomes (the
> spoken transcript, the wire response) — not inferred signals (a missing
> log line). This discipline is what finally broke a long thrash cycle.
>
> **Immediate next steps, in order (details in the handoff doc §"Open
> items"):**
> 1. Confirm with Jamie whether the OpenAI web-search retest now works (the
>    toggle was off; it's now on + app relaunched). If it still fails, read
>    `~/Library/Logs/VoiceKey/session-<today>.log` for the OpenAI MCP events
>    and diagnose from there — Exa (`https://mcp.exa.ai/mcp`) is validated
>    live and the wiring is committed.
> 2. Castor latency: it's already on the fast model (`gpt-5.6-luna`); slow
>    because `force-agent-consult` runs the full agent on every utterance.
>    Offer Jamie the routing change (see §Castor). Any sparta gateway
>    restart MUST be cued through the Olympus session — never restart
>    directly.
> 3. Echo/speaker stability: offer client-side barge-in threshold tuning
>    (be honest that open-speaker AEC may not reach headphone-level).
> 4. When Jamie is satisfied, cut the release: PR to `main` → CI green →
>    tag `v0.2.0` → signed+notarized DMG → GitHub Release → Homebrew cask.
>
> Substantive multi-file implementation goes to Codex as reviewed work
> orders (see §Delegation); you spec, review the diff yourself, gate green,
> merge `--no-ff`, push as a standalone command. Report to Jamie in plain
> language.

---

## 1. What VoiceKey is / the goal

VoiceKey is a small native macOS (Swift/AppKit) menu-bar app: map any key —
or any macropad button — to a voice function. Each **voice profile** pairs a
global hotkey with a provider (OpenAI Realtime API, OpenClaw Talk, Custom
Realtime Endpoint, ChatGPT Web) plus model/voice/instructions. Product
thesis (from marketing): the neutral **mapping layer** — "tools live in the
channel," VoiceKey never runs a backend or executes tools itself. Launch
target is Show HN with a signed/notarized DMG.

Marketing/product direction doc:
`/Users/zig/Code/Marketing/projects/voicekey/PRODUCT_DIRECTION_HANDOFF_2026-07-23.md`
(repositioning to "Voice Command Center"; dictation channels via Wispr Flow
etc. are a planned P0 leg not yet built; interaction grammar hold/double-tap
is a planned leg).

## 2. Current state — what works vs. what's open

### Works (verified against reality this session)
- Menu bar app, animated icon states, Settings window with profiles.
- **Hotkeys**: F16 → "OpenAI" profile, F17 → "Castor" profile; both Carbon-
  registered and routing to the correct profile (multi-profile routing was
  broken and is fixed).
- **OpenAI Realtime** conversation: model `gpt-realtime-2`, voice `marin`.
  Full mic→model→audio works.
- **MCP tools** load and execute server-side (proven live: DeepWiki returned
  `mcp_list_tools.completed`).
- **Castor (OpenClaw Talk)**: WORKS end-to-end — real answers with real tool
  data and real memory (verified transcripts: London/Lisbon weather with
  specific numbers; a reference to "the Apple Music upgrade blocked by
  Xanthos permissions" = Castor's actual memory). It is **slow** (see open
  items).
- **Audio**: single-engine architecture with Apple voice-processing echo
  cancellation; survives audio device changes (AirPods, Studio Display)
  without crashing; ObjC exceptions shielded on all AVFoundation calls.
- **Persistent session logs**: `~/Library/Logs/VoiceKey/session-YYYY-MM-DD.log`
  (UTC), 14-day retention, no secrets. This is the client-side ground-truth
  log — use it.
- **Apple Developer** signing is fully set up (see §Release).
- Test suite: **237 tests green**; `swift build` clean.

### Open items (what the new session must drive)
1. **OpenAI web search — FIXED, needs Jamie's retest.** Root cause: the
   profile's `webSearchEnabled` flag was `false` (cleared during an earlier
   hotfix, never re-enabled after wiring Exa). Now set to `true`, the stray
   DeepWiki test server removed, app relaunched. If it still fails, diagnose
   from the OpenAI MCP events in the persistent log. Exa is validated (§Exa).
2. **Castor latency (post-launch-tunable).** Already on `gpt-5.6-luna` (fast).
   Slow because `talk.realtime.consultRouting = force-agent-consult` runs the
   FULL agent (all skills/memory/tools) on every utterance, and a full agent
   turn with a tool call takes seconds. `consultFastMode=true` +
   `consultThinkingLevel=low` already set. Lever: change routing so the fast
   realtime model answers chitchat directly and only invokes the agent when
   needed. This is a LIVE sparta change → cue via Olympus. Task #12.
3. **Echo cancellation / open-speaker instability.** Headphones work
   perfectly; Studio Display speaker→mic path has residual echo that makes
   the model interrupt itself. Lever: client-side barge-in threshold / VAD
   eagerness tuning. Be honest with Jamie: full open-speaker AEC stability is
   genuinely hard and may not reach headphone parity this release. Task #7.
4. **Release** once Jamie is satisfied: PR `codex/realtime-provider-voicekey`
   → `main`, CI green, tag `v0.2.0`, signed+notarized DMG, GitHub Release,
   update Homebrew cask. Task #4.

## 3. Repository state

- Path: `/Users/zig/Code/VoiceKey`  Branch: `codex/realtime-provider-voicekey`
- HEAD `baa078c`, clean tree, all pushed. 54 ahead of `origin/main`, 0 behind.
- Remote: `git@github.com:jamiezigelbaum/VoiceKey.git` (private, public repo).
- Key commits this session (newest first): `baa078c` Castor frame fix •
  `e5db218` merge WO-F (audio/hotkey blockers) • `7386080` web-search→Exa •
  `2ebc55c` merge WO-E (consult round-trip) • `32d82f2` remove invalid
  web_search • `baeadcf` persistent logs • `23bc6b4` merge WO-D (per-profile
  MCP) • earlier: WO-A/B/C hardening merges, audio single-engine rewrite,
  hotkey recorder suspend, session-time stamp.
- Work-order doc (WO-A..WO-F, each with verified-facts + acceptance):
  `docs/wo/WO_2026-07-23_020_release_hardening.md`.
- No open worktrees or WO branches (all merged and cleaned).

## 4. Ground-truth reference (hard-won; do not re-derive)

### OpenClaw Talk gateway protocol (sparta, running `2026.7.1-2` / commit `0790d9f`)
- Client uses `transport: "gateway-relay"`, `brain: "agent-consult"`.
- On a `talk.event` `toolCall`, the client MUST drive the round-trip:
  `talk.client.toolCall` → receive `{runId}` → wait for chat lifecycle
  `final` → `talk.session.submitToolResult`. The gateway's `talk.event`
  `toolResult` is OBSERVABILITY only — do NOT act on it.
- **`talk.client.toolCall` params schema (additionalProperties:false):**
  `{ sessionKey, callId, name, args?, relaySessionId? }` — ONLY these keys.
  Sending an extra `voiceSessionId` was the bug (rejected INVALID_REQUEST).
- **`talk.session.submitToolResult` params:** `{ sessionId (=relaySessionId),
  callId, result, options? }`.
- `name` must be exactly `openclaw_agent_consult`.
- **`sessionKey` must resolve** to a real chat session; format
  `agent:<agent>:<session>`. VoiceKey now uses `agent:main:main` (the live
  main-agent session WITH memory). The old `agent:main:voicekey` didn't
  exist anywhere → consult would target nothing. Constant is
  `OpenClawTalkRequestBuilder.sessionKey` in `OpenClawTalkProvider.swift`.
- All talk methods need only scope `operator.write`.
- Castor = agent `main`, `model.primary = openai/gpt-5.6-luna` (fallbacks
  gpt-5.5, sonnet-5, opus-4-8…). Gateway `talk`: `brain=agent-consult`,
  `consultRouting=force-agent-consult`, `consultFastMode=true`,
  `consultThinkingLevel=low`, realtime provider `openai/gpt-realtime-2`
  voice `echo`.
- Reference clients that implement this correctly (for cross-checking):
  `ui/src/pages/chat/realtime-talk-shared.ts` (`submitRealtimeTalkConsult`,
  `waitForChatResult`), `apps/ios/Sources/Voice/RealtimeTalkRelaySession.swift`,
  `scripts/dev/realtime-talk-live-smoke.ts` (hardcodes `sessionKey:"main"`).
  Gateway source: `src/gateway/server-methods/talk-client.ts`,
  `talk-session.ts`, `talk-realtime-relay.ts`, `talk-agent-consult.ts`,
  `packages/gateway-protocol/src/schema/channels.ts`.
- **Access:** VoiceKey reaches the gateway via SSH tunnel
  `ws://127.0.0.1:18790` → `sparta:18789` (18789→18789 also tunneled). It
  authenticates with the paired-device identity in `~/.openclaw/identity`
  (`device.json` + `device-auth.json`) + gateway token in
  `~/.openclaw/secrets/*gateway-token*`.
- **Gateway journal (ground truth for the wire):**
  `ssh sparta "journalctl --user --since '<time>' -o short-iso --no-pager"`.
  Look for `✓/✗ talk.client.toolCall`, `submitToolResult`, `✓ agent … runId=`.
  Live watch during a test: `Monitor` on
  `ssh sparta "journalctl --user -f -n 0 -o short-iso" | grep --line-buffered …`.
- **sparta gateway RESTARTS must be cued through the Olympus session**
  (find it via `list_sessions`; it owns sparta restart orchestration).
  `openclaw config set|unset` + `openclaw config validate` are safe to run
  directly over `ssh sparta`; the RESTART is the gated step. Boot proof is
  the `[gateway] http server listening` journal line, nothing weaker.
  NEVER `openclaw config get` for secrets (redaction/lockout gate);
  NEVER a heredoc inside a quoted ssh command (use `ssh host 'python3 -'
  <<'EOF'`). Canonical protocol:
  `/Users/zig/Code/Olympus/docs/ops/OPENCLAW_CHANGE_PROTOCOL.md`.

### OpenAI Realtime API tools
- `session.tools` accepts ONLY `type: "function"` and `type: "mcp"`. There is
  NO hosted `web_search` in the Realtime API (that's the Responses API) — the
  API rejects it as INVALID_REQUEST. Web search MUST be a remote MCP server.
- MCP entry shape (executed server-side by OpenAI):
  `{ type:"mcp", server_label, server_url, require_approval:"never",
  allowed_tools?, authorization? }`. `require_approval:"never"` is required
  (a voice session can't surface an approval prompt).
- Client observes `mcp_list_tools.*` / `response.mcp_call.*` lifecycle events
  (mapped to diagnostics + "thinking" status in
  `OpenAIRealtimeEventMapper.swift`).
- **MCP calls are ASYNC relative to the response (probed live 2026-07-23,
  twice):** the initiating response hits `response.done` (status=completed)
  while the call's `output` is still null; `response.mcp_call.completed`
  lands later; the server NEVER auto-continues (25s observed silence). The
  client MUST send `response.create` after a terminal `response.mcp_call.*`
  to make the model speak the result — and must loop, because the follow-up
  response may chain another call (observed: `web_search_exa` →
  `web_fetch_exa`). Probe: `scripts/dev/probe-mcp-continuation.js`. Fix: WO-G.

### Exa web-search MCP (the wired web-search provider)
- `https://mcp.exa.ai/mcp` — hosted streamable-HTTP MCP, **anonymous access
  works**, exposes tools `web_search_exa` and `web_fetch_exa`. Validated live
  this session (initialize + tools/list returned 200/tools). Optional Exa API
  key can be added as `authorization` bearer if rate-limited.
- Wired in `OpenAIRealtimeRequestBuilder.swift`
  (`exaWebSearchServerURL`, `exaWebSearchTool`), injected when a profile's
  `webSearchEnabled` is true. `VoiceProfile.webSearchEnabled` + a Settings
  "Tools" checkbox (OpenAI profiles only).

### Audio engine (RealtimeAudioEngine.swift) — hardware-verified invariants
- ONE `AVAudioEngine` for capture + playback (echo cancellation needs the
  playback signal as its AEC reference; a two-engine split silences the mic).
- Ordering is load-bearing: **wire player graph → enable voice processing on
  both nodes → install input tap → start**. Enabling VP before wiring fails
  `kAUInitialize (-10875)`; starting before the tap yields silence.
- Voice processing exposes a multichannel input (9ch observed); the converter
  sets `channelMap = [0]` for mono or the tap reads pure silence.
- Every AVFoundation call that can raise an ObjC NSException (attach, connect,
  node acquisition, format read, installTap, start, setVoiceProcessing,
  scheduleBuffer, removeTap, stop) runs behind `VKCatchObjCException`
  (target `VoiceKeyObjCShield`) so a mid-route-change raise becomes a Swift
  error, not a SIGABRT. Config changes debounce + rebuild with backoff;
  terminal failure calls `onFatalFailure` → provider surfaces `needsAttention`.

### Apple Developer / release signing (fully set up)
- Individual membership active (valid through 2027-07-23). Apple ID
  `jamiezigelbaum@me.com`. **Team ID `5L9687WCZQ`.**
- Cert in login keychain: `Developer ID Application: JAMIE B ZIGELBAUM
  (5L9687WCZQ)` (`security find-identity -v -p codesigning` to confirm).
- notarytool profile stored in keychain: `voicekey-notary`.
- Package a SIGNED build:
  `VOICEKEY_SIGN_IDENTITY="Developer ID Application: JAMIE B ZIGELBAUM (5L9687WCZQ)"`
  `VOICEKEY_NOTARY_KEYCHAIN_PROFILE="voicekey-notary"` `./scripts/package-release.zsh`
  (signs, notarizes, staples → Gatekeeper-clean DMG). Info.plist is at
  version 0.2.0 / build 2.

## 5. Critical process lessons (why the prior thrash happened)
- **Ground-truth integration protocols.** Every repeated failure this session
  (invalid `web_search` type; dual-engine voice processing silencing the mic;
  the `voiceSessionId` gateway rejection) came from implementing an external
  contract by inference and shipping it live. Read the real source / probe the
  real endpoint / read the real error FIRST.
- **Self-authored fake tests prove nothing.** WO-E shipped 230 green tests and
  was still wrong on the wire because the tests asserted its own invented
  frame shape. Validate against the real endpoint.
- **Verify outcomes, not inferred signals.** "No `submitToolResult` in the log"
  looked like a stall bug — but the actual spoken transcript was a real answer.
  Checking the outcome prevented "fixing" working code.
- Saved as memory: `ground-truth-integration-protocols`,
  `voicekey-tools-via-channel`, `olympus-cues-sparta-restarts` under
  `/Users/zig/.claude/projects/-Users-zig-Code-VoiceKey/memory/`.

## 6. Delegation & workflow patterns used
- **Codex** for substantive implementation (WO-A..WO-F): write a work order
  section in `docs/wo/WO_2026-07-23_020_release_hardening.md` with a
  "Verified facts (do not re-investigate)" block + numbered required behavior
  + acceptance; run in a worktree:
  `git worktree add -b <branch> ../VoiceKey-<x> codex/realtime-provider-voicekey`
  then
  `codex exec --full-auto -C ../VoiceKey-<x> --add-dir /Users/zig/Code/VoiceKey/.git
  -o <summary.md> -m gpt-5.6-sol -c service_tier=priority
  -c model_reasoning_effort=high - <<'EOF' … EOF`.
  Codex leaves the tree dirty / may not commit if its sandbox lacks CoreAudio
  (two provider-factory tests need it). Gate: run `swift test` yourself in the
  worktree, review the diff (esp. security/invariant/protocol code), commit,
  `git merge --no-ff`, re-verify, then push as a STANDALONE command (chained
  `git push` is hook-blocked).
- **Workflow tool** (ultracode) used once for adversarial review of the
  session's hand-written commits — it found 5 real bugs (WO-F). Note: its
  structured-output research sub-agents can return placeholder junk; the
  synthesis agent caught it and re-derived. Always inspect
  `…/workflows/wf_*/journal.jsonl` if a workflow result looks degenerate.

## 7. Environment & commands
- Build/run: `swift build` • `swift test` • `./scripts/build-app.zsh` •
  `open .build/VoiceKey.app` • rebuild+relaunch after any change.
- Bundle id `com.zigelbaum.VoiceKey`. Profiles persist in UserDefaults key
  `VoiceProfiles.v1` (JSON). Decode via `defaults export … .plist` +
  `plistlib` + `json.loads`.
- Current profiles: "OpenAI" (openai-realtime, F16, `webSearchEnabled=true`,
  no MCP servers) and "Castor" (openClaw, F17).
- Hardware: DOIO 3-button macropad — left = Wispr Flow (its own key), middle
  = F16 (OpenAI), right = F17 (Castor). VIA remap app (usevia.app) was not
  working; VoiceKey's own hotkey recorder identifies keys.
- Standing prefs: reports to Jamie in plain language (problem → what I did →
  fixed or not → what's needed and from whom); never add AI/Co-Authored-By
  trailers; one session per checkout with worktree discipline; verify green
  before push; open items tracked in `~/Code/Claude/STATUS.md`.
- STATUS.md item K remaining: register VoiceKey domain (Apple Developer is
  now DONE).
