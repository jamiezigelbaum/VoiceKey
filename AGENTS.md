# VoiceKey — agent instructions

VoiceKey is a native macOS (Swift/AppKit) menu bar app that maps global
hotkeys to realtime voice providers. It runs no backend of its own and holds
no VoiceKey-owned credentials: work is done by the provider the user chose,
with the user's own key. It may execute a tool locally when that is the best
way to deliver a feature — web search works that way, through the OpenAI
Responses API with the user's key.

Planned work lives in GitHub issues and [`docs/ROADMAP.md`](docs/ROADMAP.md).

## Project rules (each one paid for by a shipped defect)

- **Ground-truth external contracts before implementing.** Never build
  against an API, protocol, or hardware contract inferred from docs or
  summaries. Probe the real endpoint, read the real server source, capture
  the real error payloads, then implement once and validate against the real
  thing. Tests that assert your own invented frame shapes against a
  self-authored fake prove nothing. Probes live in `scripts/dev/`; keep them
  when an investigation ends so the finding can be re-verified later.
- **Run the app before merging anything UI-visible.** A green suite proves
  nothing about what renders. An onboarding step once shipped drawing no
  options at all: a layout constraint activated before its view joined the
  hierarchy made AppKit abort the rest of the render with no crash and no
  failing test. Launch it, walk the changed screens, look at them.
- **Never log secrets.** API keys and gateway tokens live in the keychain.
  The session log (`~/Library/Logs/VoiceKey/session-*.log`) is written on
  the assumption that it can be pasted into a bug report; tests enforce this.
- **Fresh-install testing is not optional for a release candidate.** The
  v0.2.2 microphone-entitlement bug shipped because nothing had ever been
  launched from a clean slate. `scripts/dev/wipe-state.zsh` makes this Mac
  fresh; `scripts/dev/fresh-air-test.zsh` does it on a second Mac over SSH.

## Working standards

- A direct owner request authorizes its scoped implementation and routine
  delivery; planning and review remain read-only.
- `swift build && swift test` green locally before any push. Never push red.
  After pushing, check CI; never leave `main` red.
- Run and inspect user-visible changes in the real application.
- Keep secrets out of Git, on every branch. No AI co-author trailers.
- Every incident becomes a gate (a check, a test, a subtraction), not a prose
  warning.

## Worktree discipline

- One session owns each working checkout. Keep the base clone parked on
  `main` and do branch work in a session-owned worktree:
  `git worktree add ~/Code/VoiceKey-wt/<topic> -b <branch> main`. Remove it
  when the branch merges.
- If the base clone is dirty or on another branch, another session owns that
  state. Preserve it and take your own worktree.

## Commands

```bash
swift build && swift test          # ~600 tests, under 10 s
./scripts/build-app.zsh            # → .build/VoiceKey.app, signed if possible
open .build/VoiceKey.app
```

Dev probes and the fresh-install test rig are indexed in
[`scripts/dev/README.md`](scripts/dev/README.md). Releases follow
[`docs/RELEASE.md`](docs/RELEASE.md).
