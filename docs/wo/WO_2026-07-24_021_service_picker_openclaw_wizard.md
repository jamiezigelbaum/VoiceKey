# WO-O — Onboarding v2: service picker + OpenClaw connection wizard

Date: 2026-07-24. Owner: CTO session. Engine: Codex gpt-5.6-sol.

## Problem

The WO-N wizard assumes OpenAI is the only service: welcome → API key →
microphone → hotkey. Real first-run needs on a fresh Mac (observed live on
zigelbot's MacBook Air, 2026-07-24):

1. There is no "what do you want to connect?" moment. The OpenClaw channel can
   only be configured by finding it in Settings, and its failure modes are
   surfaced as one-shot raw errors.
2. The owner pasted a valid gateway token into the OpenClaw channel and got
   `Pairing required: device identity changed and must be re-approved` — a
   dead end. The gateway had a pending device-repair approval; VoiceKey showed
   the error once and gave up. Pending approvals **expire from gateway
   memory**, so the shown requestId can already be dead; the only correct
   client design is a retry loop that surfaces the *latest* requestId.
3. VoiceKey's gateway-token auto-discovery misses the current OpenClaw secrets
   system: on the Air the token lives in `~/.openclaw/secrets.json` under
   `gateway.auth.token`, while `openclaw.json` holds only a secret reference.
   VoiceKey reported "no gateway token found" on a Mac that had one.
4. After an OpenClaw upgrade the stored device token in
   `~/.openclaw/identity/device-auth.json` can go stale
   (`AUTH_DEVICE_TOKEN_MISMATCH`). The gateway reissues the canonical token in
   every successful hello (`auth.deviceToken`); the native repair is to retry
   the connect *omitting* the device token.

Scope ruling from the owner: the wizard offers **only services we can
actually connect today** — OpenAI Realtime and OpenClaw Talk. Anthropic has
no realtime voice API, so no Claude entry.

## Verified facts — do not re-investigate

All of the below was verified live on 2026-07-24 against gateway
v2026.7.1-2 by replaying VoiceKey's exact connect frames (probe on the Air).

- **Connect handshake** (`Sources/VoiceKey/OpenClawTalkProvider.swift`):
  gateway sends event `connect.challenge` with `payload.nonce` on socket
  open (parsed at :534-:538); client signs
  `v2|deviceId|openclaw-macos|backend|operator|<scopes,comma>|<signedAtMs>|<token>|<nonce>`
  with the Ed25519 key from `~/.openclaw/identity/device.json`
  (`OpenClawConnectSigner`, :341). Connect frames are built by
  `OpenClawTalkRequestBuilder.connectFrame` (:95 token-only, :127 device
  path). `caps: ["tool-events"]` is a TOP-LEVEL connect param (`client` is
  additionalProperties:false).
- **Rejections close the socket** (code 1008). Every retry needs a fresh
  socket and a fresh challenge nonce (existing comment :1887-:1889 and
  `retryConnectWithApprovedScopes` :1890).
- **Rejection contract** (exact live payloads):
  - Pairing:
    `{"code":"NOT_PAIRED","message":"pairing required: …","details":{"code":"PAIRING_REQUIRED","reason":"metadata-upgrade","requestId":"267ca1ba-…","remediationHint":"Review the refreshed device details, then approve the pending request.","deviceId":"…","requestedRole":"operator","requestedScopes":[…],"approvedRoles":["operator"],"approvedScopes":[…]}}`
    `reason` ∈ `not-paired | role-upgrade | scope-upgrade | metadata-upgrade`.
    Remediation: approve on the gateway (`openclaw devices approve
    <requestId>`), then retry. Each fresh connect can mint a NEW requestId.
  - Stale device token:
    `{"code":"INVALID_REQUEST","message":"unauthorized: device token mismatch (rotate/reissue device token)","details":{"code":"AUTH_DEVICE_TOKEN_MISMATCH","authReason":"device_token_mismatch","canRetryWithDeviceToken":false,"recommendedNextStep":"update_auth_credentials"}}`
  - Missing gateway token:
    `{"code":"INVALID_REQUEST","message":"unauthorized: gateway token missing (provide gateway auth token)","details":{"code":"AUTH_TOKEN_MISSING","authReason":"token_missing","canRetryWithDeviceToken":false,"recommendedNextStep":"update_auth_configuration"}}`
    (`AUTH_TOKEN_MISMATCH` exists analogously for a wrong token.)
- **Success hello** (`type:"res", id:"1"`, `ok` absent means OK; result has):
  `{"type":"hello-ok","protocol":4,"server":{"version":"2026.7.1-2","connId":"…"},"features":{…},"auth":{"role":"operator","scopes":[…],"deviceToken":"<43ch>","issuedAtMs":…},"policy":…}`
  — the gateway **reissues the canonical device token in
  `result.auth.deviceToken` on every successful connect**. Connecting with
  device signature + valid gateway token and NO deviceToken succeeds and
  returns it.
- **Token sources on a real Mac**: keychain (user-pasted) and
  `~/.openclaw/secrets/*gateway-token*` files are the two current resolver
  sources (`OpenClawTokenResolver`,
  `Sources/VoiceKey/OpenClawTalkProvider.swift:283-:310`). NEW third source,
  verified on the Air: `~/.openclaw/secrets.json` →
  `{"gateway":{"auth":{"token":"<48ch string>"}}}` (openclaw.json's
  `gateway.auth.token` is a reference object `{source:"file",…}`, NOT a
  string — never treat it as a token).
- `talk.session.create` with sessionKey `agent:voice:voicekey` succeeds even
  on a gateway with no "voice" agent (`ok:true`, transport gateway-relay) —
  no per-gateway session-key work needed in this WO.
- Wizard structure: `Sources/VoiceKey/OnboardingState.swift` —
  `OnboardingStep` enum `{location, welcome, apiKey, microphone, hotKey,
  done}`, `OnboardingFlowPolicy` matrices; controller in
  `Sources/VoiceKey/OnboardingWizardController.swift` (~1230 lines), API-key
  verification via `APIKeyVerifying` / `OpenAIAPIKeyVerifier` injected at
  :158. Fresh-install detection: `VoiceProfileStore.isFreshInstall`.
- Profiles: stored as Data under `VoiceProfiles.v1`
  (`Sources/VoiceKey/VoiceProfile.swift`), canonical hotkey sort at load AND
  save; fresh install seeds one OpenAI profile with `hotKey: nil`. Settings
  auto-applies via `commitProfiles` in `SettingsWindowController.swift` —
  there is no Save button anywhere; everything auto-saves.
- Credentials: API keys/tokens live in the keychain, shared per provider;
  credential captions are presence-based (`VoiceProviderCredentialViewState`,
  `Sources/VoiceKey/VoiceProvider.swift:265`).
- Owner UX rulings in force: no assistant instructions by default; window
  620×900; "Paste key here" placeholder + keychain caption; wizard copy
  avoids internal permission/security jargon; never log secrets.

## Required behavior

### Leg A — provider plumbing (do first; wizard depends on it)

1. **Token discovery order** in `OpenClawTokenResolver`: keychain →
   `~/.openclaw/secrets/*gateway-token*` file → `~/.openclaw/secrets.json`
   `gateway.auth.token` (string, trimmed; tolerate missing/malformed file
   silently). `VoiceProviderCredentialViewState` treats the new source as a
   discovered token (same "Using this Mac's OpenClaw pairing" caption path).
2. **Typed connection tester**: a small service (e.g.
   `OpenClawConnectionTester`) that runs one real connect attempt against the
   channel's endpoint candidates and returns a typed outcome:
   `ok(serverVersion, scopes)`, `pairingRequired(reason, requestId,
   remediationHint)`, `gatewayTokenMissing`, `gatewayTokenMismatch`,
   `deviceTokenMismatch`, `unreachable(endpointsTried)`,
   `failed(code, message)`. It must reuse the existing
   `OpenClawTalkRequestBuilder` / `OpenClawConnectSigner` /
   `OpenClawDeviceIdentityStore` / `OpenClawTokenResolver` — no parallel
   protocol stack. Fresh socket + fresh nonce per attempt. Close the socket
   after the hello (this is a test, not a session).
3. **Device-token-mismatch fallback in the real session connect path**: on
   `AUTH_DEVICE_TOKEN_MISMATCH`, retry once with the device signature and
   gateway token but NO `auth.deviceToken`; on success adopt
   `hello.auth.deviceToken` in memory for that session. Never write to
   `~/.openclaw/identity/*` (that store belongs to OpenClaw). Mirror the
   existing one-shot retry pattern of `retryConnectWithApprovedScopes`.
4. **Pairing errors surfaced to the session UI** must carry the requestId and
   remediation hint, not just the message string.

### Leg B — wizard restructure

5. **Services step** after `welcome`: "What would you like to connect?" —
   multi-select cards for **OpenAI** and **OpenClaw** (short human
   descriptions, no jargon). At least one must be selected to continue, with
   the existing "Set up later" escape. Selection persists (UserDefaults) so
   re-entry resumes correctly.
6. **Conditional service steps**: `apiKey` runs only when OpenAI is selected.
   New `openClawConnect` step when OpenClaw is selected, a state machine:
   - `searching`: probe endpoint candidates + token discovery automatically.
   - `testing`: run the connection tester, spinner.
   - `needsToken`: no token found → paste field ("Paste token here", stored
     in keychain via the existing credential store) + one-line hint that the
     token can be found on the gateway Mac. Re-test on entry.
   - `needsEndpoint`: nothing reachable locally → URL field for a remote
     gateway (normalize http/https → ws/wss as the provider already does).
   - `pairingWait`: show "OpenClaw needs your approval", the current
     requestId, a copyable `openclaw devices approve <requestId>` command,
     and auto-retry every ~4s while the screen is visible — always displaying
     the **latest** requestId (retries mint new ones; stale ones die on the
     gateway). Stop retrying when the step is left.
   - `success`: show the gateway version; continue.
   - `failed`: honest message + Retry; skippable (skip is session-local, per
     existing wizard skip semantics).
7. **Channel ensuring**: after service steps complete, ensure one channel per
   selected service exists (the fresh-install default OpenAI profile counts;
   create an OpenClaw channel with provider defaults when selected and
   missing). Persist via `VoiceProfileStore` (canonical sort). Never delete
   channels for unselected services.
8. **Hotkey step covers each ensured channel** for the selected services:
   sequential capture screens (channel name shown), per-channel skip,
   existing recorder + conflict detection + honest registration failure
   reporting reused.
9. **Re-entry ground truth** ("Finish Setup…" menu logic) extends to the
   service selection: incomplete = any selected service without its
   credential/connection fact, plus the existing location/mic/hotkey facts.
10. **Settings parity (lowest priority; skip-and-flag allowed)**: OpenClaw
    channel credentials section gains a "Test Connection" row driven by the
    same tester + state copy (compact, inline — not a new window).

## Constraints

- No network in tests. Unit-test the outcome mapping with the exact fixture
  payloads from Verified facts; test the wizard state machine and retry loop
  with injected clock/tester fakes. The tester's protocol-level behavior is
  already proven live — do not "prove" it with fakes, just pin the mapping.
- Swift/AppKit only, existing patterns (no SwiftUI, no new deps).
- Never log token values; keychain writes via the existing credential store.
- `swift build --disable-sandbox` + full `swift test` green per leg before
  proceeding to the next; all existing tests must stay green.
- Do not bump Info.plist version (release train is separate).
- Commit locally on the WO branch; never push/merge/switch branches.

## Acceptance

- Full suite green (was 361 tests; new coverage added for: resolver source
  order incl. secrets.json; tester outcome mapping for all fixture payloads;
  mismatch fallback adoption; wizard flow matrices incl. services selection,
  conditional steps, re-entry; pairing auto-retry latest-requestId behavior;
  channel ensuring idempotence).
- A fresh-install run with both services selected walks: welcome → services →
  API key → OpenClaw connect → microphone → hotkey (×2 channels) → done.
- Your final message is the work-order summary (commits, behavior per leg,
  verification, anything skipped-and-flagged).
