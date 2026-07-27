# VoiceKey — session handoff (2026-07-27)

Written for a takeover across an Anthropic account switch: the next session
starts with **no conversation history and no recollection of this work**.
Everything it needs is either in this document or linked from it.

Paste the **PROMPT FOR THE NEW SESSION** block into the fresh session.
Everything below it is the reference that prompt points to.

Supersedes the state sections of `SESSION_HANDOFF_2026-07-23.md`; that
document's **§4 ground-truth reference** (OpenClaw Talk relay protocol,
OpenAI Realtime tools/MCP, audio architecture) is still accurate and is not
repeated here.

---

## PROMPT FOR THE NEW SESSION (paste this)

> You are taking over the VoiceKey project mid-flight, acting as CTO/engineer
> for Jamie. Read `docs/SESSION_HANDOFF_2026-07-27.md` in
> `/Users/zig/Code/VoiceKey` in full before doing anything — it is the
> complete state of play. Branch `main`, clean tree, pushed, 449 tests green,
> CI green. Nothing is in flight; no worktrees, no delegated work
> outstanding.
>
> **Where the work stands:** the guided setup path (first-run assistant →
> service picker → per-service connection walkthroughs) is built, merged,
> and deployed as a fresh install to Jamie's test Mac (the Air). It is 16
> commits ahead of the last release, v0.2.2. **Jamie's end-to-end
> walkthrough on that fresh install has not been reported back yet** — that
> result is the gate for cutting v0.2.3. Do not assume it passed. Ask him
> how it went, or wait for him to say.
>
> **Two hard-won operating rules for this project — both were paid for in
> shipped defects:**
> 1. Never implement against an external protocol/API/hardware contract from
>    inference or doc summaries. Ground-truth the real schema (server source,
>    real endpoint errors, live probes) FIRST, implement once, validate
>    against the REAL thing. Tests asserting your own invented frame shapes
>    against a self-authored fake prove nothing.
> 2. **UI-visible work must be run before it is merged.** A green suite
>    proves nothing about what renders. An onboarding step shipped that drew
>    no options at all — a layout constraint activated before its view joined
>    the hierarchy, which makes AppKit raise and abort the rest of the render.
>    449 tests and an independent diff review both missed it because neither
>    executes AppKit. Launch the app, walk the changed screens, look at them.
>
> **Immediate next steps, in order (details in §3):**
> 1. Get Jamie's walkthrough result. If it passed, cut v0.2.3 — but only on
>    his explicit word; he commands releases directly.
> 2. Task #15, already agreed with him: permissions UX when adding a channel
>    from Settings (§3.2).
> 3. The deferred fast-follow findings in §3.3, at your discretion.
>
> Substantive multi-file implementation goes to Codex or Opus as reviewed
> work orders (see §7); you spec, review the diff yourself, gate green, merge
> `--no-ff`, push as a standalone command. Report to Jamie in plain language:
> outcome first, then anything that matters, then a clearly-marked **Ask**.

---

## 1. What VoiceKey is

A small native macOS (Swift/AppKit) menu-bar app: map any key — or any
macropad button — to a voice function. Each **voice channel** pairs a global
hotkey with a provider (OpenAI Realtime API, OpenClaw Talk, Custom Realtime
Endpoint, ChatGPT Web) plus model/voice/instructions.

Product thesis: the neutral **mapping layer** — "tools live in the channel."
VoiceKey never runs a backend and never executes tools itself; it connects a
key to a voice service and gets out of the way. Launch target is Show HN with
a signed, notarized DMG.

- Repo: `/Users/zig/Code/VoiceKey` → `git@github.com:jamiezigelbaum/VoiceKey.git`
- Site: https://voicekey.dev (frozen by Jamie until the marketing team is
  operational — do not touch it from this session)
- Marketing/product direction:
  `/Users/zig/Code/Marketing/projects/voicekey/PRODUCT_DIRECTION_HANDOFF_2026-07-23.md`

## 2. Current state

### Released
**v0.2.2** (2026-07-24) is the latest release — notarized DMG, GitHub
Release, Homebrew tap updated. `Info.plist` still reads `0.2.2` / build `4`.

### On main, unreleased (16 commits since v0.2.2)
The entire guided-setup workstream. Summarized user-facing in the
`## Unreleased` section of `CHANGELOG.md`; in engineering terms:

- **WO-N** — first-run onboarding assistant, credentials UX, Tools section
  removed.
- **WO-O** — onboarding v2: the "What would you like to connect?" service
  picker (OpenAI Realtime + OpenClaw Talk only — Anthropic ships no realtime
  voice API, so there is deliberately no Claude entry), a real OpenClaw
  connection wizard (auto-discovery → token paste → pairing-approval wait
  with the live requestId and auto-retry), per-channel hotkey capture, and
  Settings "Test Connection".
- **WO-P** — the three defects Jamie's first live walkthrough found: the
  service picker rendered no cards, the wizard window became unreachable
  once it lost focus, and the window was a fixed 620×900 regardless of
  content.
- **Wizard diagnostics** — onboarding now writes to the session log.
- **Credential-source UX** — the discovered pairing is primary and named; a
  rejected entered token offers one-click recovery.
- **Honest relay errors** — an upstream provider-key rejection names OpenClaw
  and the gateway Mac instead of reading as VoiceKey's fault.
- **Wizard re-entry** — the menu item opens the picker when everything
  selected is already complete, so a second service can be added.

Verified at handoff: `swift test` → **449 tests, 0 failures**; CI green;
working tree clean; `main` == `origin/main`.

One flaky test was found and fixed on the way out, because it turned CI red
on a docs-only commit. `testAddingASecondServiceWalksOnlyThatServicesRemainingSteps`
waited a fixed 50 ms for work the wizard schedules onto the next main-queue
turn; under load that starves, and the `removeFirst()` that followed trapped
the **whole process**, so one racy test took the entire suite down. Waits now
poll the observable condition with a bound (`waitUntil` in
`Tests/VoiceKeyTests/OnboardingAsyncWait.swift`) and the fake tester fails the
test instead of trapping. Measured under identical CPU load: 2 failures in 5
full-suite runs before, 0 in 8 after. If you add a test that waits on
main-queue work, use `waitUntil` — never a fixed sleep.

### Deployed but unverified by Jamie
`scripts/dev/fresh-air-test.zsh` put a fresh install of this build on the
Air on 2026-07-25. It launched and the new diagnostics recorded
`onboarding wizard: opened fresh at step=welcome reason=first-run`.

**Jamie has not reported walking it end to end.** He was asked to, including
adding the second service from the menu. Treat the walkthrough as
outstanding, not as passed.

## 3. Open items

### 3.1 Release train — v0.2.3 (task #9, gated on Jamie)
Gate: Jamie's fresh-hardware walkthrough passes. Then, and only on his
explicit word (he commands releases directly — "cut v0.2.1", "publish
v0.2.2"): bump `Info.plist` version + build, promote the `## Unreleased`
CHANGELOG section to `0.2.3`, package + sign + notarize, tag, GitHub
Release, update the Homebrew cask in `packaging/homebrew/Casks/voicekey.rb`.
Process is written up in `docs/RELEASE.md`.

### 3.2 Permissions UX when adding a channel from Settings (task #15)
Jamie's explicit request, agreed and not started. Adding a voice channel
through Settings does not surface what that channel will need (microphone,
accessibility for hotkeys) or offer to fix it inline — the wizard primes
those permissions, Settings does not. He hit this after adding OpenClaw
manually: "the permissions need more improvement too when you are adding a
new channel through the settings."

### 3.3 Deferred fast-follow findings (from the WO-O review, accepted as non-blocking)
Recorded in full at the end of
`docs/wo/WO_2026-07-24_021_service_picker_openclaw_wizard.md`:
- Hotkey ground truth requires every selected-provider channel to have a
  hotkey, so an intentionally hotkey-less second channel retitles the menu to
  "Finish Setup…" on every launch.
- Upgraded installs show "Finish Setup…" until one OpenClaw test succeeds;
  token presence could seed the connection fact instead.
- Tester lifecycle nits: cancelled runs linger in the `runs` dictionary
  (bounded memory, no socket leak); the per-endpoint watchdog isn't
  generation-guarded (worst case, a spurious "unreachable").
- `OnboardingChannelEnsurer` may rewrite an existing OpenClaw channel's
  `endpointURL` with the wizard-tested endpoint (arguably intended; deserves
  a guard or a comment either way).

### 3.4 On Jamie's side, not ours
- **The Air's OpenClaw cannot reach OpenAI**: `env.OPENAI_API_KEY` in that
  Mac's `~/.openclaw/openclaw.json` is expired, so a VoiceKey OpenClaw
  session connects, creates the talk session, and then fails upstream with
  "Incorrect API key provided". This is why the animation ran but nothing
  spoke. Not a VoiceKey bug. Key values are his to handle — do not go
  looking for or writing key material.
- STATUS.md item K(3): the product update that would also retire the stale
  `codex/realtime-provider-voicekey` remote branch and the stale README.
  That branch is fully merged into `main` (zero unique commits); the local
  copy has been deleted, the remote is left for him.

### 3.5 Parked (do not work unless asked)
- **ChatGPT web / GPT-Live channel** — diagnosed exhaustively and parked by
  Jamie's call. Full record and revisit triggers in
  `docs/CHATGPT_WEB_CHANNEL_STATUS.md`.
- **TOOLS.md trim** — handed to the OpenClaw session; proposal lives at
  `~/Code/Claude/TOOLS_MD_TRIM_PROPOSAL_2026-07-23.md`.

## 4. Ground truth learned since the 07-23 handoff

### OpenClaw gateway connect/pairing (live-verified 2026-07-24, gateway v2026.7.1-2)
The full contract — exact payloads, the connect signature format, token
discovery order — is in the **"Verified facts — do not re-investigate"**
section of `docs/wo/WO_2026-07-24_021_service_picker_openclaw_wizard.md`.
Re-verify with `scripts/dev/probe-openclaw-connect.js` rather than
re-deriving. The load-bearing parts:

- **Pending device approvals expire from gateway memory** while
  `devices/pending.json` goes stale on disk. A displayed requestId can
  already be dead, and each fresh connect mints a new one — so the only
  correct client design is a poll-retry loop that surfaces the *latest*
  requestId. This is what made the original "pairing required" error a dead
  end for Jamie.
- **Gateway token discovery** must include `~/.openclaw/secrets.json` →
  `gateway.auth.token`. `openclaw.json` holds only a secret *reference*
  object (`{source:"file",provider:"filemain",id:"/gateway/auth/token"}`) —
  never treat that as a token. VoiceKey reported "no gateway token found" on
  a Mac that had one because this source was missing.
- **A stale device token heals natively**: on `AUTH_DEVICE_TOKEN_MISMATCH`,
  reconnect *omitting* the device token but keeping the device signature and
  gateway token; the gateway reissues the canonical one in
  `hello-ok.auth.deviceToken`. VoiceKey does this in memory, once per
  session, and never writes to OpenClaw's files.
- Every rejection closes the socket (1008), so each retry needs a **fresh
  socket and a fresh challenge nonce**.

### The AppKit constraint-ordering hazard
Activating a constraint between two views that share no ancestor raises, and
the exception aborts the rest of the enclosing render method — leaving a
half-drawn screen with no crash and no test failure. This shipped the empty
service picker. The fix made the wrong order unexpressible: an
`addFullWidth(_:)` helper in `OnboardingWizardController.swift` adds the view
to the stack and only then pins it. Use it; don't hand-roll the pair again.

### Menu-bar apps and window focus
`LSUIElement` apps have no Dock tile and no ⌘-Tab entry, so a window that
loses focus becomes unreachable. `OnboardingActivationPolicySwitch` borrows
`.regular` activation policy while the wizard is open and restores it on
every close path (including `willTerminateNotification`).

### Remote UI verification is impossible over SSH
Screenshotting the Air over ssh cannot work: `screencapture` fails ("could
not create image from display") because an ssh session is outside the Aqua
session, `launchctl asuser` needs root, and Screen Recording cannot be
granted to a CLI binary at all — the TCC list only accepts `.app` bundles,
which is why adding `sshd-keygen-wrapper` silently refuses to stick. Hours
went into this route; it is closed. **The app's own session log is the
remote-observability answer** — that is why the onboarding diagnostics exist.

## 5. Environment & commands

```bash
swift build && swift test          # 449 tests, ~7s
./scripts/build-app.zsh            # → .build/VoiceKey.app
open .build/VoiceKey.app
./scripts/dev/wipe-state.zsh       # true fresh-install state on THIS Mac
./scripts/dev/fresh-air-test.zsh   # fresh install onto the test Mac (default host: air)
```

- Bundle id `com.zigelbaum.VoiceKey`. Channels persist in UserDefaults key
  `VoiceProfiles.v1` **as `Data`** — writing it with `defaults write -string`
  silently breaks loading.
- Client-side ground-truth log: `~/Library/Logs/VoiceKey/session-YYYY-MM-DD.log`
  (UTC, 14-day retention, no secrets). Onboarding events land here too.
- **The Air** (`ssh air`) is Jamie's test Mac. It runs its own local OpenClaw
  ("zigelbot") that has **nothing to do with sparta** — never conflate them,
  and never restart sparta's gateway from this session (that is the Olympus
  session's job; cue it). It was unreachable at handoff time (hostname
  `zigelbots-macbook-air.local` not resolving — asleep or off-network); that
  is normal, not a fault.
- Hardware: DOIO 3-button macropad — left = Wispr Flow, middle = F16
  (OpenAI), right = F17 (Castor).
- Dev scripts are indexed in `scripts/dev/README.md`.

## 6. Working with Jamie

- Replies: short, plain language. Fixed order — **outcome/status first**, key
  findings only if they change his understanding, then a clearly-marked
  **Ask** (exactly what's needed from him, or "nothing needed"). No
  audit-trail detail; he trusts the work.
- Open items live **only** in `~/Code/Claude/STATUS.md`. Update it every
  working session.
- Anything he will open must live at a durable path — the session scratchpad
  and `/tmp` are wiped mid-session and the link dies.
- He tests on real hardware and finds what the test suite cannot. Take live
  reports at face value and diagnose from the logs rather than defending the
  build.
- Never add Co-Authored-By / AI trailers to commits.
- He declined `operator.admin` scope for the VoiceKey device deliberately:
  "we do not want to give that much power in case somebody else is able to
  rewrite the gateway config." Do not design anything that needs it.

## 7. Delegation & the review gate

Read `~/.claude/docs/codex-delegation.md` before writing a work order. In
short: serious implementation goes to Opus 5 by default, Codex
`gpt-5.6-sol` when a genuinely independent second engine helps or when
Anthropic-side budget is the constraint. One worktree per work order; the WO
doc carries a "Verified facts — do not re-investigate" section and
skip-and-flag authority.

Review gate before merge: read the summary, review invariant/security-critical
diffs yourself, run `swift test` in the worktree, **run the app if anything
visual changed**, merge `--no-ff`, verify green, then `git push` as a
standalone command (a hook blocks chained pushes). After pushing, check
`gh run list` — never leave main's CI red.

## 8. Where the durable state lives

| What | Where |
| --- | --- |
| This handoff | `docs/SESSION_HANDOFF_2026-07-27.md` |
| Protocol/architecture reference (still current) | `docs/SESSION_HANDOFF_2026-07-23.md` §4 |
| OpenClaw connect contract, verbatim payloads | `docs/wo/WO_2026-07-24_021_service_picker_openclaw_wizard.md` |
| User-facing change log incl. unreleased | `CHANGELOG.md` |
| Release process | `docs/RELEASE.md` |
| Parked ChatGPT-web investigation | `docs/CHATGPT_WEB_CHANNEL_STATUS.md` |
| Dev probes & test rig | `scripts/dev/README.md` |
| Jamie's estate-wide open items | `~/Code/Claude/STATUS.md` (VoiceKey thread) |
| Project memories | `~/.claude/projects/-Users-zig-Code-VoiceKey/memory/` |
| Delegation playbook | `~/.claude/docs/codex-delegation.md` |
| OpenClaw change protocol (live systems) | `~/Code/Olympus/docs/ops/OPENCLAW_CHANGE_PROTOCOL.md` |
