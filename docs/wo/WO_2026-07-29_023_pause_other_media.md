# WO-R — Pause other media while a voice channel is active

Date: 2026-07-29. Owner: CTO session. Engine: Opus 5.
Worktree: `/Users/zig/Code/VoiceKey-wt/pause-media`, branch `pause-media`.

## Problem

Jamie, on Xanthos, with Apple Music playing and a voice session open:

> "the volume is being muted on playback. It's about half as loud as it should
> be, and I can hear it switch. I don't exactly know what's switching it."

Cause, verified in source: `RealtimeAudioEngine.start()` builds the audio graph,
which calls `configureVoiceProcessing()` and enables Apple's voice processing on
both the input and output nodes (`RealtimeAudioEngine.swift:293-317`). That puts
the system output into the communications path, which ducks other audio. It is
enabled for the **whole session**, not per turn — `start()` builds it, `stop()`
tears it down (`:161-190`) — and the hotkey is toggle-to-stop, so asking for
music and walking away leaves the session open and the music ducked
indefinitely.

## The owner's ruling (2026-07-29, decided — do not relitigate)

> "The audio should be paused when VoiceKey is active, but then, when VoiceKey
> is no longer active, the audio should come back up. We don't need to have any
> ducking. Whatever, if I'm talking to OpenAI or I'm talking to Castor, I don't
> want there to be any music in the background. Just pause any music playback
> while VoiceKey takes over the audio session, and then unpause when VoiceKey
> channels are closed. When the VoiceKey app is open but there are no active
> channels open, we want audio to play as normal."

So: **pause other media on channel activation, resume it on deactivation.** Not
ducking, not volume control — transport control.

**The voice-processing configuration is NOT changed by this work order.** It is
what cancels echo, the output node is the reference signal the canceller
subtracts, and `isEchoCancellationActive` also force-enables half-duplex speaker
mode when false (`OpenAIRealtimeSpeakerMode.swift:70-80`) — the Studio Display
echo that WO-H was written to kill. Once media is paused there is nothing left
for the ducking to duck. Do not touch `configureVoiceProcessing()`.

## Required behaviour

1. **A channel becomes active** → every script-controllable player that is
   *currently playing* is paused, and which ones were paused is remembered.
2. **The last active channel closes** → exactly those players are resumed.
3. **App open, no active channel** → nothing is touched; audio plays normally.
4. Switching directly from one channel to another must not resume in between.
   Resume happens when no channel is active, not on every deactivation.
5. Nothing here may ever block, delay, or fail a voice session. Every failure
   path is logged and swallowed.

### Safety rules, each one a way this can go wrong

- **Never launch an app.** `tell application "Music" to …` *launches* Music if
  it is not running. Guard every player with `if application "X" is running`,
  which does not launch it.
- **Only resume what we paused.** If nothing was playing when the channel
  opened, nothing is resumed when it closes.
- **Never resume something the owner stopped deliberately.** On resume, play
  only if that player is still paused. If the owner already hit play, or
  stopped it outright and moved on, leave it alone.
- **Never send a bare play/pause media key.** It is a toggle, and with nothing
  playing it would *start* music when a voice channel opened. Query state, act
  specifically.

### Players

A table, not a switch buried in logic — adding one must be a one-line change:

| App name | Bundle id | Notes |
|---|---|---|
| `Music` | `com.apple.Music` | Jamie's daily driver, and what Castor plays through |
| `Spotify` | `com.spotify.client` | same `player state` / `pause` / `play` vocabulary |

Both expose `player state` returning `playing`/`paused`/`stopped`. Anything not
in the table is out of scope for this WO — see "Not covered".

## The entitlement trap — read this before writing code

The app runs under the hardened runtime and is **not** sandboxed
(`VoiceKey.entitlements` contains only `com.apple.security.device.audio-input`).
Under the hardened runtime, sending Apple Events to another app is blocked
unless the app carries `com.apple.security.automation.apple-events`, and macOS
also requires `NSAppleEventsUsageDescription` in `Info.plist` before it will
prompt.

Neither is present today. **Both must be added**, or this ships doing nothing on
a notarized build — silently, with no prompt and no error, exactly the way the
microphone entitlement shipped a dead mic in v0.2.0 and v0.2.1. The comment
already in `VoiceKey.entitlements` records that incident; this is the same trap.

Usage string should say plainly why: VoiceKey pauses your music while a voice
channel is listening, and resumes it afterwards.

First pause will raise the macOS "VoiceKey wants to control Music" prompt. If
the owner denies it, log the denial once per session and carry on — a denied
automation permission must never stop a voice session from starting.

## Suggested shape

A small dedicated type, pure where it can be:

- `MediaPlaybackController` (or similar) owning the "who did we pause" set and
  the activate/deactivate entry points. Not a singleton; injected into
  `VoiceKeyAppDelegate` so tests can substitute the scripting layer.
- A protocol for the scripting layer — something like
  `MediaPlayerScripting` with `isRunning(_:) -> Bool`,
  `state(of:) -> MediaPlayerState`, `pause(_:)`, `play(_:)` — with the real
  `NSAppleScript`/`osascript` implementation behind it and a fake in tests. The
  decision logic (who to pause, who to resume, what to do when a second channel
  opens) must be testable **without sending a single Apple Event**.
- Wire into `VoiceKeyAppDelegate` at the existing seam: `activeProfileID` is set
  at `:453` and cleared at `:997`, and reconciled at `:968`. Prefer one place
  that observes "is any channel active" changing, over sprinkling calls.

Log to the session log via the existing provider-event path: which players were
paused and resumed, and any permission denial. **Names of apps only** — never a
track title, never anything the owner is listening to. The session log is
written to be pasteable into a bug report.

## Test plan

House conventions: one XCTest target, plain `swift test`, injected fakes,
`waitUntil` from `Tests/VoiceKeyTests/OnboardingAsyncWait.swift` for anything
asynchronous, never `Thread.sleep`. `UserDefaults` suites, if needed, come from
`makeTestDefaults()` — building one by hand now fails a gate.

Cover at least:

- A player that is playing is paused on activation, and resumed on close.
- A player that is **paused** when the channel opens is *not* resumed on close.
- A player that is **not running** is never contacted, and never launched.
- Switching channel A → channel B does not resume in between; closing B resumes.
- Two channels open, one closes: nothing resumes until the last one closes.
- The owner pressing play mid-session means resume leaves it alone.
- A scripting failure or permission denial does not prevent the channel from
  activating (the decisive test — assert the session still starts).
- Nothing in the log carries anything but app names.

## Acceptance

1. `swift test` green; new tests fail against the pre-change behaviour.
2. `VoiceKey.entitlements` gains `com.apple.security.automation.apple-events`
   and `Info.plist` gains `NSAppleEventsUsageDescription`.
3. `configureVoiceProcessing()` and `OpenAIRealtimeSpeakerMode.swift` are
   unmodified — `git diff --stat` empty for both.
4. No code path can launch a media player that was not already running.
5. No Apple Event is sent from any test.
6. A denied automation permission cannot fail a voice session.

## Skip-and-flag authority

- If `NSAppleScript` proves unusable off the main thread, say so and use
  whatever works, but keep the scripting layer behind the protocol.
- If Spotify's vocabulary differs enough to be awkward, ship Music alone and
  flag it — Music is the case that matters today.
- Do not add a Settings toggle for this. If you think one is needed, flag it;
  the owner did not ask for one.

## Not covered — state these in the summary, do not attempt

Audio from apps with no scripting interface (a browser tab, a video call) keeps
playing, and will still be ducked by voice processing. Covering that needs a
different mechanism and a separate decision.

## Commit shape

Small commits on `pause-media`. No AI co-author trailers. Do not push; the CTO
session reviews, runs the app, merges `--no-ff`.
