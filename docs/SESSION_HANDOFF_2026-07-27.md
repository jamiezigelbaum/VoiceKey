# VoiceKey — session handoff (2026-07-27)

**You are reading this because Jamie handed you the link, and it is the only
thing he gave you. This document is your entire briefing.** It was written
for a takeover across an Anthropic account switch: you have no conversation
history and no recollection of this work, and nothing is coming to fill that
in. Read it start to finish before doing anything.

Your role: **CTO/engineer on VoiceKey for Jamie** — you spec, delegate or
build, review, merge, deploy, verify, and report honestly.

> **This repository is PUBLIC** (github.com/jamiezigelbaum/VoiceKey), and it
> is heading for a Show HN launch. Everything you commit here is world-
> readable, including this document. Never commit secrets, customer-ish
> detail, or anything about Jamie's other systems beyond what is already
> here.

---

## 0. Start here (first five minutes)

```bash
cd /Users/zig/Code/VoiceKey
git status && git log --oneline -3
swift build && swift test          # expect 449 tests, 0 failures, ~10s
```

Expected: branch `main`, clean tree, `main` == `origin/main`, CI green,
**no worktrees and nothing in flight** — no delegated work outstanding, no
half-finished branch, no background jobs.

If that is not what you find, someone else has been in here since; read
§7 (worktree discipline) before touching anything.

Two more things load automatically for Claude Code sessions on this Mac and
are worth knowing you have: Jamie's global working agreement at
`~/.claude/CLAUDE.md`, and project memories at
`~/.claude/projects/-Users-zig-Code-VoiceKey/memory/`. The repo's own entry
point is `AGENTS.md` at the root, which points back here. **The task list
from the previous session does not carry over** — §3 is the real backlog.

### The one thing to do first
Ask Jamie how the walkthrough went (§2, "Deployed but unverified"). His
answer decides whether the next move is a release or more fixing. Do not
assume it passed.

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

- Repo: `/Users/zig/Code/VoiceKey` → `git@github.com:jamiezigelbaum/VoiceKey.git` (**public**)
- Homebrew tap: `jamiezigelbaum/homebrew-voicekey` (**public**, separate repo — see §4)
- Site: https://voicekey.dev — frozen by Jamie until the marketing team is
  operational. Do not touch it from this session.
- Marketing/product direction:
  `/Users/zig/Code/Marketing/projects/voicekey/PRODUCT_DIRECTION_HANDOFF_2026-07-23.md`

## 2. Current state

### Released
**v0.2.2** (2026-07-24) — notarized DMG, GitHub Release, Homebrew tap
updated. `Info.plist` still reads version `0.2.2`, build `4`.

### On main, unreleased (16 commits since v0.2.2)
The entire guided-setup workstream. User-facing summary is the
`## Unreleased` section of `CHANGELOG.md` (already written — reuse it
verbatim when cutting the release). In engineering terms:

- **WO-N** — first-run onboarding assistant, credentials UX, Tools section
  removed.
- **WO-O** — onboarding v2: the "What would you like to connect?" service
  picker (OpenAI Realtime + OpenClaw Talk only — Anthropic ships no realtime
  voice API, so there is deliberately no Claude entry), a real OpenClaw
  connection wizard (auto-discovery → token paste → pairing-approval wait
  with the live requestId and auto-retry), per-channel hotkey capture, and
  Settings "Test Connection".
- **WO-P** — the three defects Jamie's first live walkthrough found: the
  service picker rendered no cards at all, the wizard window became
  unreachable once it lost focus, and the window was a fixed 620×900
  regardless of content.
- **Wizard diagnostics** — onboarding now writes to the session log.
- **Credential-source UX** — the discovered pairing is primary and named; a
  rejected entered token offers one-click recovery.
- **Honest relay errors** — an upstream provider-key rejection names OpenClaw
  and the gateway Mac instead of reading as VoiceKey's fault.
- **Wizard re-entry** — the menu item opens the picker when everything
  selected is already complete, so a second service can be added.

Verified at handoff: `swift test` → **449 tests, 0 failures**; CI green;
clean tree; `main` == `origin/main`.

**A flaky test was found and fixed on the way out — read this before you add
a test.** A docs-only commit turned CI red, which is the tell for a race
rather than a regression:
`testAddingASecondServiceWalksOnlyThatServicesRemainingSteps` waited a fixed
50 ms for work the wizard schedules onto the next main-queue turn. Under load
that starves, and the `removeFirst()` that followed **trapped the process**,
so one racy test took the entire suite down. Waits now poll the observable
condition with a bound — `waitUntil` in
`Tests/VoiceKeyTests/OnboardingAsyncWait.swift` — and the fake tester
`XCTFail`s instead of trapping. Measured under identical CPU load: 2 failures
in 5 full-suite runs before, 0 in 8 after. **If you write a test that waits on
main-queue work, use `waitUntil`. Never a fixed sleep.**

### Deployed but unverified by Jamie
`scripts/dev/fresh-air-test.zsh` put a fresh install of this build on the Air
(his test Mac) on 2026-07-25. It launched, and the new diagnostics recorded
`onboarding wizard: opened fresh at step=welcome reason=first-run`.

**He has not reported walking it end to end.** He was asked to, including
adding the second service from the menu. Treat the walkthrough as
outstanding, not as passed — his result gates the release.

## 3. Open items

### 3.1 Release train — v0.2.3 (gated on Jamie)
Gate: his fresh-hardware walkthrough passes, **and** he says to cut it. He
commands releases directly ("cut v0.2.1", "publish v0.2.2") — do not start
one on your own initiative. Verified procedure in §4.

### 3.2 Permissions UX when adding a channel from Settings
His explicit request, agreed and not started. Adding a voice channel through
Settings does not surface what that channel will need (microphone,
accessibility for hotkeys) or offer to fix it inline — the wizard primes
those permissions, Settings does not. He hit this after adding OpenClaw
manually: *"the permissions need more improvement too when you are adding a
new channel through the settings."*

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

### 3.4 Smaller known staleness
- The Homebrew cask's `desc` still reads "Menu bar hotkey for ChatGPT Voice"
  — wrong since the app went multi-provider, and it is what `brew info`
  shows. Worth fixing with the next cask bump.
- The README is stale relative to the product (Jamie owns the rewrite as part
  of his product-update item).

### 3.5 On Jamie's side, not ours
- **The Air's OpenClaw cannot reach OpenAI**: `env.OPENAI_API_KEY` in that
  Mac's `~/.openclaw/openclaw.json` is expired, so a VoiceKey OpenClaw
  session connects, creates the talk session, and then fails upstream with
  "Incorrect API key provided". That is why the animation ran but nothing
  spoke. **Not a VoiceKey bug.** Key values are his to handle — do not go
  looking for, reading, or writing key material.
- The stale `codex/realtime-provider-voicekey` remote branch is fully merged
  into `main` (zero unique commits). The local copy was deleted; the remote
  is left for him as part of his product-update item.

### 3.6 Parked — do not work these unless asked
- **ChatGPT web / GPT-Live channel** — diagnosed exhaustively and parked by
  Jamie's call. Full record and revisit triggers in
  `docs/CHATGPT_WEB_CHANNEL_STATUS.md`.
- **TOOLS.md trim** — handed to the OpenClaw session; proposal at
  `~/Code/Claude/TOOLS_MD_TRIM_PROPOSAL_2026-07-23.md`.

## 4. Cutting a release (verified against how v0.2.2 actually shipped)

`docs/RELEASE.md` describes the scripts but predates the current flow and its
examples still say `0.1.0`. The scripts read the version from `Info.plist`,
so they are version-agnostic; this is the real sequence:

1. Bump `Info.plist`: `CFBundleShortVersionString` → `0.2.3`,
   `CFBundleVersion` → `5`.
2. Promote `## Unreleased` in `CHANGELOG.md` to `## 0.2.3 - <date>`.
3. Commit, `swift test` green, push, confirm CI green (`gh run list`).
4. Package, sign, notarize:
   ```bash
   export VOICEKEY_SIGN_IDENTITY="Developer ID Application: … (TEAMID)"
   export VOICEKEY_NOTARY_KEYCHAIN_PROFILE="voicekey-notary"
   ./scripts/package-release.zsh
   ```
   Produces `dist/VoiceKey-0.2.3/` with the DMG, ZIP and `SHA256SUMS.txt`.
   The exact identity string and the notary profile are already set up on this
   Mac (see `docs/RELEASE.md` for how they were created).
5. `./scripts/github-release.zsh` — tags `v0.2.3`, pushes the tag, creates a
   **draft** GitHub Release with the artifacts attached. Review the draft,
   then publish it.
6. `./scripts/update-homebrew-cask.zsh` — rewrites
   `packaging/homebrew/Casks/voicekey.rb` with the new version, URL and
   SHA-256. Commit that in this repo.
7. **The tap is a separate repo and this is the step that is easy to miss.**
   `brew` reads `jamiezigelbaum/homebrew-voicekey`, not this repo. Copy the
   updated cask into the tap clone and push it:
   ```bash
   cp packaging/homebrew/Casks/voicekey.rb \
      /opt/homebrew/Library/Taps/jamiezigelbaum/homebrew-voicekey/Casks/voicekey.rb
   # then commit in that clone with the message shape "voicekey 0.2.3" and push
   ```
8. Verify: `brew update && brew info --cask voicekey` shows the new version,
   and a Gatekeeper check on the downloaded DMG passes.

## 5. Hard rules — each one is paid for by a shipped defect

1. **Ground-truth external contracts before implementing.** Never build
   against an API, protocol, or hardware contract inferred from docs or
   summaries. Probe the real endpoint, read the real server source, capture
   the real error payloads — then implement once, then validate against the
   real thing. Tests asserting your own invented frame shapes against a
   self-authored fake prove nothing. Probes live in `scripts/dev/` (indexed
   in `scripts/dev/README.md`); keep new ones when an investigation ends.
2. **Run the app before merging anything UI-visible.** A green suite proves
   nothing about what renders. An onboarding step shipped drawing no options
   at all — a layout constraint activated before its view joined the
   hierarchy makes AppKit raise and abort the rest of the render, with no
   crash and no failing test. 449 tests *and* an independent diff review both
   missed it, because neither executes AppKit. Launch it, walk the changed
   screens, look at them.
3. **Never log secrets.** Keys and gateway tokens live in the keychain. The
   session log is written on the assumption it can be pasted into a bug
   report; tests enforce this.
4. **Fresh-install testing is not optional for a release candidate.** The
   v0.2.2 microphone-entitlement bug shipped because nothing had ever been
   launched from a clean slate.
5. **Verify green before push; push as a standalone command.** A hook blocks
   chained pushes (see §7). After pushing, check `gh run list` — never leave
   main's CI red.

## 6. Ground truth worth not re-deriving

### OpenClaw gateway connect/pairing (live-verified 2026-07-24, gateway v2026.7.1-2)
Full contract — exact payloads, connect signature format, token discovery
order — is under **"Verified facts — do not re-investigate"** in
`docs/wo/WO_2026-07-24_021_service_picker_openclaw_wizard.md`. Re-verify with
`scripts/dev/probe-openclaw-connect.js` (run it *on* the gateway Mac) rather
than re-deriving. The load-bearing parts:

- **Pending device approvals expire from gateway memory** while
  `devices/pending.json` goes stale on disk. A displayed requestId can
  already be dead, and each fresh connect mints a new one — so the only
  correct client design is a poll-retry loop surfacing the *latest*
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

`docs/SESSION_HANDOFF_2026-07-23.md` **§4** remains the canonical reference
for the OpenClaw Talk *relay* protocol (tool-call round trip, session keys),
the OpenAI Realtime tools/MCP contract, and the audio architecture. It is not
repeated here; the rest of that document is historical.

### The AppKit constraint-ordering hazard
Activating a constraint between two views that share no ancestor raises, and
the exception aborts the rest of the enclosing render method — a half-drawn
screen with no crash and no test failure. This shipped the empty service
picker. The fix made the wrong order unexpressible: `addFullWidth(_:)` in
`OnboardingWizardController.swift` adds the view to the stack and only then
pins it. Use it; don't hand-roll the pair again.

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
went into this; the route is closed. **The app's own session log is the
remote-observability answer** — that is why the onboarding diagnostics exist.

## 7. Environment, gates, and safety

```bash
swift build && swift test          # 449 tests, ~10s
./scripts/build-app.zsh            # → .build/VoiceKey.app
open .build/VoiceKey.app
./scripts/dev/wipe-state.zsh       # true fresh-install state on THIS Mac
./scripts/dev/fresh-air-test.zsh   # fresh install onto the test Mac (host: air)
```

- Bundle id `com.zigelbaum.VoiceKey`. Channels persist in UserDefaults key
  `VoiceProfiles.v1` **as `Data`** — writing it with `defaults write -string`
  silently breaks loading.
- Session log: `~/Library/Logs/VoiceKey/session-YYYY-MM-DD.log` (UTC, 14-day
  retention, no secrets). Onboarding events land here too.
- Hardware: DOIO 3-button macropad — left = Wispr Flow, middle = F16
  (OpenAI), right = F17 (Castor).

### Automated gates that will bite you
A bash-guard hook (`~/.claude/hooks/bash-guard.py`) blocks, mechanically:
`git push` chained with any other command (push alone); a heredoc **inside** a
quoted ssh command (use `ssh host 'python3 -' <<'EOF'` — heredoc outside the
quotes); `openclaw config get` for secrets; piping into crontab; and creating
a branch in a worktree-disciplined base clone.

### Worktree discipline
One session per checkout. The base clone stays parked on `main` and is never
branched in directly. Branch work goes in a session-owned worktree:
`git worktree add ~/Code/VoiceKey-wt/<topic> -b <branch> main`, removed when
the branch merges. If you find the base clone on a non-main branch or dirty,
another session owns it — take a worktree, don't "fix" it.

### The Air (test Mac) and live systems
- `ssh air` is Jamie's fresh-hardware test Mac. It runs its **own local
  OpenClaw instance ("zigelbot") that has nothing to do with sparta** — he
  corrected this conflation explicitly. Never cue an Olympus/sparta action for
  something happening on the Air.
- It is often unreachable (asleep / off-network — the hostname simply won't
  resolve). That is normal, not a fault.
- Watch its logs with an auto-reconnect wrapper; a plain `tail -F` over ssh
  dies silently with exit 255:
  ```bash
  while true; do ssh -o ServerAliveInterval=30 air \
    'while true; do f=$(ls -t ~/Library/Logs/VoiceKey/session-*.log 2>/dev/null | head -1);
     [ -n "$f" ] && tail -F "$f"; sleep 2; done' 2>/dev/null; sleep 5; done
  ```
- **Never restart sparta's OpenClaw gateway from this session** — that is the
  Olympus session's job; cue it. `openclaw config set|unset` and
  `config validate` are safe over ssh; the restart is the gated step, and the
  only accepted boot proof is the `[gateway] http server listening` journal
  line. Canonical protocol:
  `~/Code/Olympus/docs/ops/OPENCLAW_CHANGE_PROTOCOL.md`.
- On the Air, `~/clawdbot-legacy-backup-2026-07-24` holds an archived wallet
  file. **Preserve it; never delete it.**
- Jamie declined `operator.admin` scope for the VoiceKey device deliberately:
  *"we do not want to give that much power in case somebody else is able to
  rewrite the gateway config."* Do not design anything that needs it.

## 8. Working with Jamie

- Replies: short, plain language. Fixed order — **outcome/status first**, key
  findings only if they change his understanding or a decision, then a
  clearly-marked **Ask** (exactly what's needed from him, or "nothing
  needed"). No audit-trail detail; he trusts the work.
- His open items across all projects live **only** in `~/Code/Claude/STATUS.md`.
  Update the VoiceKey thread there every working session.
- Anything he will open — a file you send, any path you link — must live at a
  durable path. The session scratchpad and `/tmp` are wiped mid-session and
  the link dies.
- He tests on real hardware and finds what the suite cannot. Take his live
  reports at face value and diagnose from the logs rather than defending the
  build.
- Never add Co-Authored-By / AI trailers to commits.

## 9. Delegation & the review gate

Read `~/.claude/docs/codex-delegation.md` before writing a work order.
Serious implementation goes to Opus 5 by default; Codex `gpt-5.6-sol` when a
genuinely independent second engine helps (adversarial second opinion, a leg
Opus already failed) or when Anthropic-side budget is the constraint. One
worktree per work order; each WO doc carries a "Verified facts — do not
re-investigate" section and explicit skip-and-flag authority. Existing orders
in `docs/wo/` are the reference shape.

Review gate before merge: read the summary, review invariant/security-critical
diffs yourself, run `swift test` in the worktree, **run the app if anything
visual changed**, merge `--no-ff` with a review note, verify green, then
`git push` as a standalone command. Then `gh run list`.

## 10. Where the durable state lives

| What | Where |
| --- | --- |
| This handoff | `docs/SESSION_HANDOFF_2026-07-27.md` |
| Repo entry point (points here) | `AGENTS.md` |
| Relay protocol / Realtime MCP / audio reference | `docs/SESSION_HANDOFF_2026-07-23.md` §4 |
| OpenClaw connect contract, verbatim payloads | `docs/wo/WO_2026-07-24_021_service_picker_openclaw_wizard.md` |
| User-facing change log incl. unreleased | `CHANGELOG.md` |
| Release scripts reference (dated; §4 above supersedes) | `docs/RELEASE.md` |
| Parked ChatGPT-web investigation | `docs/CHATGPT_WEB_CHANNEL_STATUS.md` |
| Dev probes & test rig | `scripts/dev/README.md` |
| Jamie's estate-wide open items | `~/Code/Claude/STATUS.md` (VoiceKey thread) |
| Project memories | `~/.claude/projects/-Users-zig-Code-VoiceKey/memory/` |
| Global working agreement | `~/.claude/CLAUDE.md` |
| Delegation playbook | `~/.claude/docs/codex-delegation.md` |
| OpenClaw change protocol (live systems) | `~/Code/Olympus/docs/ops/OPENCLAW_CHANGE_PROTOCOL.md` |
