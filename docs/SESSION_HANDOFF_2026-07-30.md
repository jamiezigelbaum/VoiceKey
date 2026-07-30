# VoiceKey — session handoff, 2026-07-30

**You have been given only this path. Everything you need is here.** Read it
top to bottom before doing anything. It replaces
`docs/SESSION_HANDOFF_2026-07-27.md`, which is now history.

---

## 0. Paste-in prompt for a fresh session

> You are taking over the VoiceKey project as CTO-style owner: you write work
> orders, review and merge, verify honestly, and report to Jamie. Read
> `/Users/zig/Code/VoiceKey/docs/SESSION_HANDOFF_2026-07-30.md` in full, then
> `/Users/zig/Code/VoiceKey/AGENTS.md`. Do the five-minute state check in §2 of
> the handoff before touching anything. The first thing waiting on you is in §3.

---

## 1. What VoiceKey is

A native macOS (Swift/AppKit) menu-bar app that maps global hotkeys to realtime
voice providers. Press a key → a voice channel opens → you talk to a realtime
model. Providers: **OpenAI Realtime** (Jamie's F17), **OpenClaw Talk** —
"Castor" — (F18), a custom realtime endpoint, and a parked ChatGPT-web channel.

Single developer, single user (Jamie). Distributed as a notarized
Developer-ID-signed app plus a Homebrew tap. ~19k lines of Swift, 597 tests,
`swift test` runs in ~12s.

It runs no backend of its own and holds no VoiceKey-owned credentials: the
provider the owner chose does the work, with the owner's own key. **It MAY
execute a tool locally** — see §7, this changed today and matters.

---

## 2. State, and the five-minute check

- `main` = `993cc2f`, clean, pushed, CI green.
- `minimal-instructions` = `a9061b3`, **5 commits ahead, unmerged, pushed**,
  597 tests green. Worktree at `/Users/zig/Code/VoiceKey-wt/minimal-instructions`.
- `/Applications/VoiceKey.app` is currently a build of **that unmerged branch**,
  running. Previous copies are in the Trash if a rollback is wanted.

Run this first:

```bash
cd /Users/zig/Code/VoiceKey && git status --short --branch && git log --oneline -3
swift build && swift test            # expect 597 passing
gh run list --limit 3                # expect green
pgrep -lf "VoiceKey.app/Contents/MacOS/VoiceKey"   # expect EXACTLY ONE
```

---

## 3. The one thing waiting on Jamie

**`minimal-instructions` is finished and green but unmerged**, blocked only on
someone looking at the Settings window. Ask him, or look yourself if you can
drive the UI:

1. Open Settings. The **Instructions** field must be gone from the main form.
2. Near the bottom there is an **Advanced** disclosure. Clicking the *word*
   "Advanced" (not only the triangle) must expand it and reveal Instructions.
3. Confirm nothing below Advanced is missing — a truncated form is the AppKit
   failure this project has shipped before (§8).

If it looks right: merge `--no-ff`, push, check CI, then rebuild and reinstall
`/Applications/VoiceKey.app` from main.

Jamie's other open checks, all on the currently-installed build:

- Is she **more concise** now? (Brevity moved into the hidden prompt today.)
- Does **web search** work when asked something current? (Never verified with a
  real voice — see §7.)
- Does the **menu-bar icon animate for the whole time she speaks**?
- **The Air walkthrough** — still the only gate on cutting **v0.2.3**.

---

## 4. What shipped today (2026-07-30)

All merged to main, CI green, in order:

| Commit | What |
|---|---|
| `f6aa00e` | Webview grants the mic on an exact origin, not a substring match |
| `c9bb70f` | Session log is publishable: endpoints sanitised, **transcripts removed** |
| `d5b9695` | **Credential leak fixed** — endpoint no longer outlives its provider |
| `baa766a` | Media hold recovers from failure and from quit |
| `c733de8` | CI gate now inspects the **signed artifact**, not the sources |
| `44b18fe` | Voice processing released on teardown (stops ducking other audio) |
| `1f78241` | **Menu-bar indicator** when a channel opens/closes |
| `048fc8c` | **Built-in web search** using the user's own OpenAI key |
| `e8f840f` | **Echo-cancellation hotfix** (regression from `44b18fe`) |
| `993cc2f` | **Speaking state** held until playback actually drains |

### The worst bug found, for context on why review paid off

Changing a channel's provider **kept the previous provider's `endpointURL`**,
and the new provider then attached *its own credential* to that host. A Custom
channel pointing at `wss://vendor.example`, switched to OpenAI and started, sent
`Authorization: Bearer <the owner's OpenAI key>` to that vendor. Two clicks, key
disclosed to a third party. Found by adversarial review, fixed in `d5b9695`.

---

## 5. The adversarial review, and what is still open from it

Four independent Codex `gpt-5.6-sol` reviews ran today — correctness/concurrency,
security/privacy, architecture/design, tests/CI. **Full reports:**
`~/Code/Claude/reviews/voicekey-2026-07-29/` (01–04 are the reviews, `fix-*` are
the implementation summaries). Every finding required a concrete failure
scenario; each load-bearing claim was verified against source before acting.

**Still open, roughly in the order I would take them:**

1. **No test constructs the real audio engine.** Delete the line handing
   microphone audio to the provider and all 597 tests stay green while the model
   hears silence. The core path of the product is untested. Needs a seam around
   AVFoundation.
2. **Plaintext `ws://` is accepted for any host**, and the production handshake
   accepts any `ok:true` rather than requiring a real `hello-ok`. On a hostile
   network that is a full credential relay. (`OpenClawTalkProvider`.)
3. **Settings can silently delete channels added elsewhere** while its window is
   open: it ignores authoritative updates but later persists its whole stale
   array. Repro: open Settings, add a channel via the Setup Assistant, rename
   the first channel in the still-open window → the new channel disappears.
4. **Onboarding can write a verified OpenAI key into another provider's keychain
   slot** — it saves against `profileProvider().first` rather than the profile
   the screen is about.
5. `webSearchEnabled` is now real, but instructions remain editable on
   `.openClaw`, `.geminiLive`, `.deepgramVoiceAgent` where the field is silently
   discarded.
6. The defaults-leak gate test needs a writable `~/Library/Preferences`, so it
   fails inside Codex's sandbox. Not a product bug; it means **every Codex
   "green suite" claim must be re-run locally.**

---

## 6. How to work here

Read `AGENTS.md` for the project rules. The ones that bite:

- **Ground-truth external contracts.** Never implement against an inferred API
  shape. Probes live in `scripts/dev/` — and they need `ws`, which is not
  declared anywhere: `mkdir /tmp/p && cd /tmp/p && npm init -y && npm i ws`.
- **Run the app before merging anything UI-visible.** A green suite proves
  nothing about what renders.
- **Never log secrets.** The session log is written to be pasteable publicly.
  It carries **no transcripts** as of today (Jamie's ruling).
- **Verify before push**, never leave main's CI red, push as a standalone
  command (hook-enforced).
- **One session per checkout.** Base clone stays on `main`; branch work happens
  in `git worktree add ~/Code/VoiceKey-wt/<topic> -b <branch> main`.
- **Substantive implementation is delegated** via a written work order in
  `docs/wo/`; see today's `WO_2026-07-29_024..027` and `WO_2026-07-30_028` for
  the shape. Read `~/.claude/docs/codex-delegation.md` first.

### Reporting to Jamie

Short, plain, and in a fixed order: **outcome first**, then only findings that
change a decision, then a clearly-marked **Ask** (or "nothing needed"). No
audit trail. Open items live only in `~/Code/Claude/STATUS.md` — update the
VoiceKey thread every working session.

---

## 7. Verified facts — probed live today, do not re-derive

**Web search (the OpenAI channel).**

- The Realtime API accepts **only** `function` and `mcp` tool types. All three
  hosted-search spellings were rejected: `Invalid value: 'web_search'.
  Supported values are: 'function' and 'mcp'.`
- The **same OpenAI key** can search via `POST /v1/responses` with
  `tools:[{"type":"web_search"}]` — returns `web_search_call` items and a real
  answer. This is what VoiceKey now uses, so a new user needs no second signup.
- Model latency, one sample each: `gpt-4.1-mini` 2.8s (chosen) · `gpt-5.1` 3.0s
  · `gpt-5-mini` 9.7s · `gpt-5.1-mini` does not exist.
- The client-side function round trip works: the model emits
  `response.function_call_arguments.done` with `call_id`; replying with
  `conversation.item.create` `{type:"function_call_output", call_id, output}`
  then `response.create` makes it speak the result.
- **Exa's anonymous MCP endpoint is exhausted** (`429 You've hit Exa's free MCP
  rate limit`). It was hardcoded and shared by every VoiceKey user on earth,
  because OpenAI executes MCP servers server-side. Removed.
- **Unverified:** speaking to a live channel and getting a searched answer. The
  whole path was proven by injecting a *text* turn; nobody has done it by voice.

**Audio.**

- `response.output_audio.done` means the server stopped *sending*, not that the
  assistant stopped talking. Measured: audio stopped arriving at `10:55:48`,
  playback drained at `10:56:03` — 15s. Speaking is now held until the engine
  reports playback inactive.
- Voice processing puts the system output into the communications path and ducks
  all other audio. It must be released on teardown **and re-armed on start** —
  `buildEngine()` runs only at init and on a route-change rebuild.
- Teardown must **not** clear `isEchoCancellationActive`: the provider reads it
  to choose speaker mode *before* starting the engine, so clearing it makes the
  next session begin in forced mic-gating.

**The retired rule.** "VoiceKey never executes tools itself — tools live in the
channel" was **retired today** (commit `5d43062`). It was blocking the obvious
way to give users search, and Jamie did not recognise it as his rule. It had been
recorded as his 2026-07-23 position, so treat that attribution as uncertain
rather than as a reversal. What survives: no VoiceKey backend, no VoiceKey-owned
credentials.

**Environment.**

- `ws://127.0.0.1:18790` on Xanthos is an **SSH tunnel to sparta**, not a local
  gateway (`com.castor.sparta-gateway-tunnel` LaunchAgent). Sparta restart
  discipline applies to anything on the Castor channel.
- Keychain: service `com.zigelbaum.VoiceKey`, account `openai-realtime`.
- **osascript lost its accessibility grant** partway through today, so UI
  automation (`tell process "VoiceKey"`) fails with `-1719` while reading
  processes still works. Ask Jamie to re-grant under System Settings → Privacy &
  Security → Accessibility if you need to drive the UI.

---

## 8. Traps that have cost real time

- **Stray app instances.** Twice today Jamie found two VoiceKeys running, both
  mine: I launched a build from a worktree, removed the worktree, and the
  process outlived it. **Kill by binary name, not by the path you launched
  from**, and check `pgrep -lf "VoiceKey.app/Contents/MacOS/VoiceKey"` before
  ending any app run. A second instance also double-registers the global
  hotkeys, so keypresses go to a coin flip.
- **CI runs on a smaller display with different font metrics.** Three tests
  passed locally and failed on CI because they asserted against the window's
  *realized* geometry. Assert what the code decides, never what the environment
  granted. One accessory-fit assertion also failed by exactly 1pt because a
  button bezel legitimately draws outside its alignment rect.
- **A green suite is not a working feature.** The menu-bar indicator's first
  version was invisible: it ordered the panel front at alpha 0 and faded up via
  an animator that never ran in the app. Every test passed.
- **`strings` cannot see short Swift literals.** I briefly concluded a feature
  was missing from a binary because `search_web` did not appear; the longer
  description string was there all along.
- **Screenshots race the UI.** For anything transient, ask the window server
  (`CGWindowListCopyWindowInfo`, filter by `kCGWindowOwnerName == "VoiceKey"`)
  and screenshot when it reports the window — do not spray captures and hope.
- **Codex left a work order untracked** in its worktree once, so it did not
  travel with the merge. Check `git status` in the worktree before removing it.
- **One Codex job hung for 8 hours doing nothing.** Same model, same flags as
  three jobs that finished in ten minutes. If output stops growing, kill it,
  re-fork from current main, and relaunch rather than waiting.

---

## 9. Durable paths

| Path | What |
|---|---|
| `/Users/zig/Code/VoiceKey` | base clone, parked on `main` |
| `/Users/zig/Code/VoiceKey-wt/minimal-instructions` | the unmerged branch's worktree |
| `~/Code/Claude/STATUS.md` | Jamie's only list of open items, all projects |
| `~/Code/Claude/reviews/voicekey-2026-07-29/` | the four adversarial reviews + fix summaries |
| `~/Library/Logs/VoiceKey/session-*.log` | session log; **no transcripts** as of today |
| `docs/wo/` | work orders, one per delegated change |
| `scripts/dev/` | probes; `README.md` indexes them |
| `scripts/verify-app-entitlements.zsh` | the release gate that inspects the signed artifact |
| `~/.claude/projects/-Users-zig-Code-VoiceKey/memory/` | project memory, `MEMORY.md` is the index |

---

## 10. If you do only one thing

Merge `minimal-instructions` once Jamie confirms the Settings window, then get
him through the **Air walkthrough** — that is the last gate on v0.2.3, and it has
been the last gate for five days.
