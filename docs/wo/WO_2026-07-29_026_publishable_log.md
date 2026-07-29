# WO-U — Make the session log actually publishable

Date: 2026-07-29. Owner: CTO session. Engine: Codex gpt-5.6-sol.
Branch `publishable-log`. Two findings from adversarial review plus an explicit
owner ruling. Both verified by the CTO session against source.

## Problem

The project's stated rule is that `~/Library/Logs/VoiceKey/session-*.log` is
written so it can be pasted into a public bug report. Two things break that.

### 1. Raw endpoints reach the log and Copy Diagnostics

`OpenClawTalkProvider.swift:1590` emits
`"Connecting to OpenClaw gateway at \(endpoint)."` with the endpoint verbatim,
and `VoiceKeyDiagnosticsSnapshot.swift:25` puts the raw endpoint into the
copied diagnostics. Endpoints are typed by the owner and may carry a token in
the query string. A sanitizer already exists —
`OnboardingLogEvent.sanitizedEndpoint` in `OnboardingDiagnostics.swift`, which
keeps scheme/host/port and drops user info, query and fragment — but it is used
only by onboarding, never by the runtime provider or the snapshot.

### 2. Raw transcripts are written to disk — the owner has ruled these out

`VoiceSessionLogFile.swift` / `VoiceSessionLog.swift` record transcript text
verbatim, so anything spoken aloud lands on disk for 14 days and is included by
"Copy Session Log".

**Owner's ruling, 2026-07-29: "Let's not have the log carry any transcripts."**
This is decided. Do not preserve them behind a flag or an opt-in.

## Required behaviour

1. **One mandatory endpoint formatter for every persisted or pasteable
   diagnostic sink.** Move/extract the existing sanitizer so it is shared, and
   route the OpenClaw runtime diagnostics and `VoiceKeyDiagnosticsSnapshot`
   through it. Onboarding must keep producing byte-identical output to today.
   Prefer making a raw endpoint hard to pass by accident — a distinct type or a
   single choke point — over relying on every future call site remembering.
2. **No transcript text in the session log or in Copy Session Log.** Structural
   facts only: role (user/assistant), that a turn occurred, and cheap
   non-revealing measures such as delta or turn counts if they are useful for
   debugging. Nothing that reconstructs what was said.
3. The in-app live log view (`VoiceSessionLog`) is what the owner watches while
   debugging. If transcripts are useful there, they may remain **in memory
   only** — but then "Copy Session Log" must not include them, and nothing may
   reach disk. State clearly in your summary which you chose and why.
4. Tool names stay as they are: `safeToolName` already covers them.
5. Remote error prose is out of scope for this WO; a separate order will handle
   redaction at the sink.

## Tests

- Sentinel test: drive `wss://gateway.example/ws?token=tok_SENTINEL` through the
  **real** provider diagnostic path into the real `VoiceSessionLogFile`, and
  through `VoiceKeyDiagnosticsSnapshot`; assert `tok_SENTINEL` appears in
  neither, and that the host is still present so the line stays useful.
- Transcript test: feed a transcript event containing
  `"the recovery code is 482917"` and assert neither `482917` nor the sentence
  reaches the file or the copied text.
- `VoiceSessionLogTests.swift:14` currently asserts that transcript text DOES
  appear in the log. It encodes the behaviour the owner has now ruled out —
  update it to assert the new contract and say so in your summary.
- Onboarding diagnostics output is unchanged: the existing
  `OnboardingDiagnosticsTests` must stay green with no edits.

## Acceptance

1. `swift build && swift test` green.
2. Both sentinel tests fail against the current code and pass after.
3. `OnboardingDiagnosticsTests` unmodified and green.
4. No endpoint string reaches a log or snapshot except through the shared
   formatter — demonstrate this by construction, not by inspection.

## Standing rules

Small commits on `publishable-log`. Do NOT push, merge, or switch branches.
Tests must not use `Thread.sleep` or a fixed `RunLoop.run`; poll with
`waitUntil`. `UserDefaults` suites come from `makeTestDefaults()`. Assertions
must not depend on screen size, font metrics or timing. No AI co-author
trailers. You may SKIP a leg whose prerequisite is not met, and FLAG why.
