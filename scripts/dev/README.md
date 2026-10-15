# Development scripts

Not shipped with the app. Two kinds live here: **ground-truth probes** that
talk to a real endpoint to establish what it actually does, and **test-rig
scripts** for fresh-install verification on real hardware.

The probes exist because of a standing project rule: never implement against
an external protocol from inference or doc summaries. Ground-truth the real
schema first, implement once, then validate against the real thing. Each
probe below is the artifact of one such investigation, kept so the finding
can be re-verified after an upstream upgrade instead of re-derived.

## Ground-truth probes

| Script | Question it answers |
| --- | --- |
| `probe-openclaw-connect.js` | Replays VoiceKey's exact OpenClaw gateway connect handshake (device-signed). Prints the rejection contract or the redacted hello. `--no-device-token` reproduces the native repair for a stale device token. |
| `probe-mcp-continuation.js` | Does the OpenAI Realtime API auto-continue after a server-side MCP call? (No — the client must send `response.create`, and must loop, because the follow-up can chain another call.) |
| `probe-echo-fields.js` | Which echo/barge-in session fields does the real Realtime endpoint accept, and what does `session.updated` echo back? |
| `probe-truncate.js` | The exact accepted shapes for client-side interruption (`response.cancel` + `conversation.item.truncate`). |
| `probe-media-scripting.swift` | Does `NSAppleScript` work off the main thread, do VoiceKey's pause/play/state sources compile against the real Music and Spotify terminology, and does compiling a `tell` launch the app? (Yes, yes, no.) Compiles the player scripts but never executes them, so it cannot change anyone's playback. |

The OpenAI probes read `OPENAI_API_KEY` from the environment. The OpenClaw
ones read that Mac's own `~/.openclaw` identity and secrets — run them **on
the machine running the gateway**. All of them redact token-like values
before printing; none of them write a secret anywhere.

## Repair

| Script | What it does |
| --- | --- |
| `repair-openclaw-device-auth.js` | Rewrites `~/.openclaw/identity/device-auth.json` after a gateway upgrade invalidates the stored operator device token, by taking the canonical one the gateway reissues in its hello. Backs the file up first. |

This repairs the **OpenClaw CLI's** stored credentials. VoiceKey performs the
same no-device-token retry in memory and never writes to those files.
Diagnose with `probe-openclaw-connect.js` before running it.

## Test rig

| Script | What it does |
| --- | --- |
| `wipe-state.zsh` | Wipes every trace of VoiceKey from this Mac — preferences, keychain, TCC permissions, saved state — so the next launch is a true fresh install. `--keep-app` retests the wizard without reinstalling. |
| `fresh-air-test.zsh` | Builds nothing; takes the current `.build/VoiceKey.app`, wipes the target Mac's VoiceKey state, removes any brew copy, pushes the signed app and launches it. Default host `air`. |

Fresh-install testing is not optional for release candidates: the v0.2.2
microphone-entitlement bug shipped precisely because nothing had ever been
launched from a clean slate.

## Cleaning up after a GUI run

A stray second VoiceKey is not just litter: both instances register the same
global hotkeys, one wins the Carbon registration and the other silently falls
back to an event monitor, so which app answers a keypress becomes a coin flip.
A leftover debug build (injected turns, altered timeouts) also makes the owner's
observations meaningless. This happened twice in one day after worktree builds
were killed by a path pattern that missed, then the worktree was removed.

- Launch the build as a process you own and keep its PID
  (`.build/VoiceKey.app/Contents/MacOS/VoiceKey & vk_pid=$!`), then end it with
  `kill "$vk_pid"`. For an `open`-launched build, read the PID from
  `pgrep -lf VoiceKey.app/Contents/MacOS/VoiceKey` and kill only the entry whose
  path is yours.
- Do not `pkill` by binary name: it also kills the owner's installed copy.
- Before finishing, the same `pgrep -lf` must list nothing, or exactly one
  entry whose path is `/Applications/VoiceKey.app`. Relaunch that installed app
  so the owner is left on the build they use.

