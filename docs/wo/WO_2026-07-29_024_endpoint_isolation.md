# WO-S — A channel's endpoint must never outlive the provider that owned it

Date: 2026-07-29. Owner: CTO session. Engine: Codex gpt-5.6-sol.
Branch `endpoint-isolation`. Found by adversarial review, verified by the CTO
session against source before this order was written.

## Problem — verified, do not re-investigate

Changing an existing channel's provider keeps the previous provider's
`endpointURL`, and the new provider then attaches **its own credential** to that
retained host.

- `SettingsWindowController.swift:1665-1689`, `case let .provider(provider)`:
  sets `profile.providerID`, then `profile.model` and `profile.voice` from
  `providerSettingsCache`, and for `.custom` initializes credential scope. It
  **never touches `profile.endpointURL`**.
- `OpenAIRealtimeProvider.swift:237-241` builds its socket with
  `baseURL: OpenAIRealtimeRequestBuilder.normalizedBaseURL(for: configuration.endpointURL)`.
- `OpenAIRealtimeRequestBuilder.swift:30-46` adds
  `request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")`
  to whatever URL it was given.

**Failure scenario, concretely:** a Custom channel points at
`wss://vendor.example/realtime`. The owner changes the Provider popup to OpenAI
and presses the channel's hotkey. VoiceKey opens a WebSocket to
`vendor.example` carrying `Authorization: Bearer <the owner's OpenAI key>`.
The owner's API key is disclosed to a third-party host by a two-click UI action.

The same shape applies to any provider pair where the retained endpoint belongs
to a different trust domain than the credential now being attached.

## Required behaviour

1. **Changing a channel's provider must not carry the endpoint across.** After a
   provider change, `endpointURL` must not still address the previous
   provider's host.
2. **Per-provider endpoint memory is acceptable and preferred.**
   `providerSettingsCache` already remembers `model` and `voice` per
   `(profileID, provider)` and restores them when the owner switches back.
   Extend the same mechanism to the endpoint: remember the outgoing provider's
   endpoint, restore the incoming provider's own remembered endpoint, and
   otherwise start empty. Switching away and back must not lose the owner's
   typed endpoint.
3. **An empty endpoint must remain correct for every provider.** OpenAI already
   falls back to its default base URL; `.custom` legitimately requires one and
   its existing "Set the endpoint URL for this voice channel" activation
   failure is the right behaviour when it is empty.
4. No other behaviour changes. This is an isolation fix, not a redesign of
   provider settings.

## Tests

- Custom channel with `wss://vendor.example/realtime` → switch to OpenAI →
  assert the resulting profile's endpoint does not address `vendor.example`,
  and that the request the OpenAI builder produces for that profile does not
  target `vendor.example` while carrying an Authorization header. **This test
  must fail against the current code** — check that it does before you fix it,
  and say so in your summary.
- Round trip: Custom endpoint typed → switch to OpenAI → switch back to Custom
  → the original endpoint is restored.
- OpenClaw ↔ OpenAI and Custom ↔ OpenClaw switches do not leak an endpoint in
  either direction.
- Existing `SettingsAutoApplyTests` provider-switch tests stay green; if one
  encodes the old carry-over behaviour, change it and say which and why.

## Acceptance

1. `swift build && swift test` green.
2. The new isolation test fails before the fix and passes after.
3. No change to `OpenAIRealtimeRequestBuilder`, `OpenAIRealtimeProvider` or any
   provider's networking — the fix belongs where the profile is edited.
4. Nothing new is logged. Endpoints must not be written to any diagnostic in
   this WO (a separate WO owns endpoint sanitization).

## Standing rules

Small commits on `endpoint-isolation`. Do NOT push, merge, or switch branches.
Never log a secret or an endpoint. Tests must not use `Thread.sleep` or a fixed
`RunLoop.run`; poll with `waitUntil` from
`Tests/VoiceKeyTests/OnboardingAsyncWait.swift`. `UserDefaults` suites in tests
come from `makeTestDefaults()`; building one by hand fails a gate. Assertions
must not depend on screen size, font metrics, timing or installed apps — CI runs
on a smaller display than the dev Mac. No AI co-author trailers.

You may SKIP any leg whose prerequisite is not met, and FLAG why. Never ship
partial or broken work.
