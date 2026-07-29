# WO-V — Two ways the media hold loses the owner's music

Date: 2026-07-29. Owner: CTO session. Engine: Codex gpt-5.6-sol.
Branch `media-recovery`. Both found by adversarial review against code merged
earlier the same day; both verified by the CTO session.

## Problem — verified, do not re-investigate

### 1. Ordinary Quit can outrun the resume

`MediaPlaybackController.resumeBeforeTermination(timeout: 2)` queues the resume
on the same serial executor as the Apple Events, then waits **2 seconds**.
`AppleScriptMediaPlayerScripting.appleEventTimeoutSeconds` is **30**. So a pause
pass still blocked on a slow or unresponsive player holds the queue, the
termination resume never reaches the front, the 2-second wait expires, and
VoiceKey exits with the owner's music paused.

This is a normal Quit. The crash / Force Quit case is separately known and the
owner has explicitly accepted it — do not build persistence for that.

### 2. A transient failure permanently forgets a paused player

`MediaPlaybackController.resumeWhatWePaused()` takes `candidates` and clears
`pausedPlayers` **before** attempting anything. If the state read or the play
command then fails — including the ten-minute rest a timeout now triggers — the
player is gone from the record. Nothing ever retries, and the music stays paused
until the owner presses play by hand.

## Required behaviour

1. **Termination cannot leave paused music behind because of queue ordering.**
   The resume must not sit behind a pause pass that can take an order of
   magnitude longer than the shutdown budget. Any of these is acceptable —
   choose and justify: make in-flight media work cancellable so termination
   pre-empts it; give the termination path its own short-timeout scripting call
   that does not queue behind the pending one; or make the shutdown budget
   actually cover the worst case. What is not acceptable is a budget that is
   quietly smaller than the operation it waits for.
2. **A player is not forgotten until it is genuinely resolved.** Keep ownership
   of a paused player until either it has been resumed, or its observed state
   proves the owner has taken it over (playing, stopped, or no longer running).
   A failed attempt leaves the obligation intact so a later reconciliation can
   retry it.
3. **The owner-wins rule is unchanged and must not regress.** On any retry,
   `play` is sent only if the player is still `paused`. If the owner pressed
   play, or stopped it and moved on, VoiceKey leaves it alone and drops the
   obligation.
4. The ten-minute rest for a failing player stays. It exists because a standing
   automation refusal otherwise makes every channel start pay a 30-second
   stall. Retrying must not defeat it.

## Tests

- Termination: Music paused and recorded; a second player blocks the executor;
  termination begins → assert the resume still happens (or is provably
  attempted) within the shutdown budget. **This must fail against the current
  code.**
- Transient failure then recovery: pause Music, fail the resume once, let the
  rest elapse, reconcile again → Music is resumed. The existing test clock
  injection (`now:`) supports this without waiting.
- Owner-wins survives retry: after a failed resume, if the player is found
  `playing` or `stopped`, no `play` is sent and the obligation is dropped.
- No regression in: the switch case (no play between channels), the app-open
  no-channel case (nothing contacted), and the existing rest behaviour.

## Acceptance

1. `swift build && swift test` green.
2. The two new tests fail before the fix and pass after.
3. No Apple Event is sent from any test.
4. `resumeBeforeTermination` still cannot deadlock when called on the main
   thread — the existing `Thread.isMainThread` path must keep working.

## Standing rules

Small commits on `media-recovery`. Do NOT push, merge, or switch branches. Never
log anything but app names — no track titles. Tests must not use `Thread.sleep`
or a fixed `RunLoop.run`; poll with `waitUntil`. Assertions must not depend on
timing, screen size or installed apps. No AI co-author trailers. You may SKIP a
leg whose prerequisite is not met, and FLAG why.
