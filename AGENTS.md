# VoiceKey — agent instructions

**Start here: [`docs/SESSION_HANDOFF_2026-07-27.md`](docs/SESSION_HANDOFF_2026-07-27.md).**
It is the current state of play — what's built, what's released, what's open,
and what the next step is. Read it before doing anything substantive.

VoiceKey is a native macOS (Swift/AppKit) menu-bar app that maps global
hotkeys to realtime voice providers. It runs no backend of its own and holds
no VoiceKey-owned credentials: work is done by the provider the owner chose,
with the owner's own key.

It MAY execute a tool locally when that is the best way to give the owner
working functionality — web search is done exactly that way, by calling the
OpenAI Responses API with the user's own key. The older rule that VoiceKey
"never executes tools itself — tools live in the channel" was retired on
2026-07-30: it had begun vetoing features the owner wanted, and he did not
recognise it as his.

## Project rules (each one paid for by a shipped defect)

- **Ground-truth external contracts before implementing.** Never build
  against an API, protocol, or hardware contract inferred from docs or
  summaries. Probe the real endpoint, read the real server source, capture
  the real error payloads — then implement once, then validate against the
  real thing. Tests that assert your own invented frame shapes against a
  self-authored fake prove nothing. Probes live in `scripts/dev/`; keep them
  when an investigation ends, so the finding can be re-verified later instead
  of re-derived.
- **Run the app before merging anything UI-visible.** A green suite proves
  nothing about what renders. An onboarding step once shipped drawing no
  options at all — a layout constraint activated before its view joined the
  hierarchy makes AppKit raise and abort the rest of the render, with no
  crash and no failing test. Launch it, walk the changed screens, look at
  them.
- **Never log secrets.** API keys and gateway tokens live in the keychain.
  The session log (`~/Library/Logs/VoiceKey/session-*.log`) is written on the
  assumption that it can be pasted into a bug report; tests enforce this.
- **Fresh-install testing is not optional for a release candidate.** The
  v0.2.2 microphone-entitlement bug shipped because nothing had ever been
  launched from a clean slate. `scripts/dev/wipe-state.zsh` makes this Mac
  fresh; `scripts/dev/fresh-air-test.zsh` does it on the test Mac.

## Working standards (owner policy)

- **Verify before push.** `swift build && swift test` green locally before
  any push. Never push red. Push is a standalone command — chained pushes are
  hook-blocked. After pushing, check `gh run list`; never leave main's CI red.
- **Substantive implementation goes to a delegated engine** via a written
  work order (problem with verified facts, required behavior, acceptance) —
  see `~/.claude/docs/codex-delegation.md` and the existing orders in
  `docs/wo/`. The session acts as reviewer: read the diff, run verify, run
  the app if it renders anything, merge `--no-ff` deliberately. Quick fixes,
  ops, and docs may be direct.
- **No AI co-author trailers** on commits, ever.
- **Every incident becomes a gate** — a check, a test, a subtraction — not a
  prose warning.
- **Secrets never enter the repo**, in any commit, on any branch.

## Worktree discipline

- **One session per checkout, no exceptions.** The base clone stays parked on
  `main` and is never branched in directly.
- **All branch work happens in a session-owned worktree:**
  `git worktree add ~/Code/VoiceKey-wt/<topic> -b <branch> main`. Remove it
  when the branch merges (`git worktree remove`).
- **Found the base clone on a non-main branch or dirty?** Another session
  owns that state. Don't touch it, don't "fix" it — take a worktree and carry
  on.

## Commands

```bash
swift build && swift test          # 449 tests, ~7s
./scripts/build-app.zsh            # → .build/VoiceKey.app
open .build/VoiceKey.app
```

Dev probes and the fresh-install test rig are indexed in
[`scripts/dev/README.md`](scripts/dev/README.md).
