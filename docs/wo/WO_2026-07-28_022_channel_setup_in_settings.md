# WO-Q — Channel-scoped Setup section in Settings

Date: 2026-07-28. Owner: CTO session. Engine: Opus 5.
Worktree: `/Users/zig/Code/VoiceKey-wt/channel-setup`, branch `channel-setup`.
Closes open item 3.2 in `docs/SESSION_HANDOFF_2026-07-27.md`.

## Problem

The owner's words, after adding an OpenClaw channel by hand:

> "the permissions need more improvement too when you are adding a new channel
> through the settings."

Settings is **not** missing a permissions UI. It has a good one — a microphone
row and an accessibility row, live status, a pure tested policy, 1 Hz polling,
injected closures — sitting as a **global** section between Credentials and
Instructions, wired to nothing the Add Channel flow does. Adding a channel
opens a provider-picker `NSAlert` that says nothing about what the channel will
need, creates the channel with `hotKey: nil`, and drops the owner into a form
whose permissions section says exactly what it said for the previous channel.

So this is a **rewiring and a move**, not a new feature. The section becomes
channel-scoped, shows only what is outstanding, moves above the fold, and gains
one honest row for the non-permission reasons a channel cannot run.

### Three premise corrections — do not re-derive these

1. **The onboarding wizard does not prime accessibility.** `OnboardingStep` has
   no accessibility case (`OnboardingState.swift:172-181`) and
   `AXIsProcessTrusted` appears nowhere in the wizard. Settings is already the
   only deliberate accessibility surface. There is no wizard parity to copy.
2. **Accessibility is not a standing requirement.** Carbon
   `RegisterEventHotKey` needs no trust (`GlobalHotKey.swift:81-106`); only the
   `NSEvent.addGlobalMonitorForEvents` fallback does
   (`VoiceKeyAppDelegate.swift:366-386`). A permanently-red "Accessibility ●
   Needs access" row would be wrong for almost every user.
3. **Every provider needs the microphone, ChatGPT Web included.**
   `WebWindowController`'s `decisionHandler(.grant)` is a WebKit per-origin
   decision layered on the process's own TCC record, not a substitute for it.

## Owner's rulings (decided 2026-07-28, do not relitigate)

- **Scope: everything the channel needs**, not permissions only. The section is
  named **Setup** and lists whatever is outstanding for the selected channel —
  missing shortcut, missing credential, microphone, accessibility. It collapses
  to one green line when the channel is ready, so the common case gets
  *shorter* than today's two permanent rows. Rationale: a channel added from
  Settings has `hotKey: nil` every single time, so a section that says
  "everything granted" about a channel that cannot run is a worse lie than
  saying nothing.
- **Accessibility: only when it actually fails.** The row appears only when this
  channel's shortcut fell back to the untrusted event monitor. Never for a
  Carbon-registered shortcut, never for a channel with no shortcut, never while
  the recorder is capturing. The accepted cost: no way to pre-grant
  accessibility from Settings before something breaks.
- **After adding a channel: scroll only, no focus grab** (CTO call). Scroll the
  Setup section into view; leave first responder on the name field.

## Required behaviour, every state

The Setup section sits immediately after the Voice Channel section (channel
popup + name field) and before Voice Provider — the only placement guaranteed
above the fold in the default 620×900 window for every provider, including
OpenClaw whose runtime block is long. It **replaces** today's Permissions
section; there is exactly one permission surface in the window.

It renders only what is outstanding, in fixed do-this-next order (activation →
microphone → accessibility), with a full-width indented reason line under each
row.

### Freshly added OpenAI channel, microphone never granted

1. Owner clicks **+** next to the channel popup.
2. The existing "Add Voice Channel" alert appears, unchanged in shape: provider
   popup over the grey description line, plus **one new grey 11pt line** that
   updates with the popup: *"Needs: a global shortcut, microphone access, and
   an OpenAI API key."* Static copy from a pure function — no live permission
   read, nothing async, nothing that can prompt while the modal owns the run
   loop.
3. Owner clicks **Add Channel**. The channel is created and selected exactly as
   today. The form then scrolls so the Setup header is in view. Keyboard focus
   does not move.
4. Setup shows:

```
Setup
─────────────────────────────────────────────────────
Shortcut                    ● Not set        [ Record… ]
      Record a global shortcut for this voice channel.
Microphone                  ● Needs access   [ Enable ]
      This channel can't start a session without microphone access.
```

   No alert fired. No system prompt fired. Nothing bounced. This is a state in
   a window the owner already opened.

5. **[Record…]** scrolls to the Shortcut section and starts recording. After
   capture the Shortcut row is replaced within one poll tick by the next unmet
   item (the API key row).
6. **[Enable]** presents the macOS microphone prompt. On grant the row and its
   reason line disappear within a second, **and the menu-bar title stops
   reading "Finish Setup…"** — which it does not do today.
7. **[Add Key]** scrolls to Credentials and focuses the secure field. On paste
   the row disappears and the section collapses to a single line:

```
Setup
─────────────────────────────────────────────────────
Everything this channel needs is ready.
```

### Accessibility actually matters

Appears **only** when this channel's shortcut is persisted but Carbon
registration failed at `registerAllHotKeys()` and the app is untrusted — the
"worked yesterday, silent today" case, currently invisible unless the owner
opens Copy Diagnostics:

```
Accessibility               ● Needs access   [ Open Settings ]
      macOS refused to register ⌃⌥V the usual way, so this channel's
      shortcut only works while VoiceKey has Accessibility access.
```

**[Open Settings]** does exactly what it does today: fires the AX trust prompt
and opens the Accessibility pane.

### ChatGPT Web channel, microphone off

Identical, except the microphone reason line reads: *"The ChatGPT window
records through VoiceKey, so it stays silent until microphone access is on."*
This is the one provider whose microphone failure surfaces nowhere else — the
WKWebView just goes quiet.

### No channel selected

One line: *"Add a voice channel to see what it needs."* All rows hidden.

### Provider changed on an existing channel

`apply(.provider(_))` already re-syncs the whole form, so Setup recomputes for
free. Switching OpenAI → ChatGPT Web makes the credential row vanish; the
microphone row stays because it is genuinely still needed.

### What the owner never sees

An alert about permissions. A system prompt they did not click. A red
Accessibility row on a channel whose shortcut works fine. A flickering row while
recording a shortcut. A menu-bar badge or launch-time check. **This is a state,
never an event.**

## File-by-file change list

### NEW `Sources/VoiceKey/ChannelSetupPolicy.swift`

Pure values only. **Must not import or vend any `NSView`.** That is what makes
cross-window constraint-ordering failures structurally impossible rather than
merely avoided.

```swift
enum ChannelHotKeyRegistration: Equatable {
    case noHotKey, carbonRegistered, eventMonitorFallback, unknown
    func diagnosticTerm(isAccessibilityTrusted: Bool) -> String
}

enum ChannelSetupRequirementID: String { case activation, microphone, accessibility }

enum ChannelSetupAction: Equatable {
    case recordHotKey, focusEndpoint, focusCredential, requestMicrophone, requestAccessibility
}

struct ChannelSetupRequirement: Equatable {
    var id: ChannelSetupRequirementID
    var title: String
    var row: PermissionRowSnapshot        // reuse the shipped shape verbatim
    var reason: String
    var action: ChannelSetupAction?
}

struct ChannelSetupSnapshot: Equatable {
    var outstanding: [ChannelSetupRequirement]
    var summary: String
    var isReady: Bool { outstanding.isEmpty }
}

enum ChannelSetupPolicy {
    static let readySummary = "Everything this channel needs is ready."
    static let noChannelSummary = "Add a voice channel to see what it needs."

    static func snapshot(
        profile: VoiceProfile,
        hasCredential: Bool,
        registration: ChannelHotKeyRegistration,
        isRecordingHotKey: Bool,
        microphone: MicrophoneAuthorizationState,
        isAccessibilityTrusted: Bool
    ) -> ChannelSetupSnapshot

    static func requirementSummary(for provider: VoiceProviderID) -> String
}
```

`diagnosticTerm(isAccessibilityTrusted:)` returns exactly today's three strings,
byte-identical: `"Carbon registered"`, `"trusted event-monitor fallback"`,
`"unavailable without Accessibility access"`.

**`snapshot` rules:**

- **Activation requirement** — call
  `ProfileActivationPolicy.failure(for: profile, hasAPIKey: hasCredential)`.
  **Do not reimplement the decision.** Map the returned failure to presentation
  only:

  | failure | title | status | action | reason |
  |---|---|---|---|---|
  | `.missingHotKey` | `"Shortcut"` | `"Not set"` | `.recordHotKey` / `"Record…"` | `failure.settingsMessage` |
  | `.missingEndpoint` | `"Endpoint"` | `"Required"` | `.focusEndpoint` / `"Set Endpoint"` | `failure.settingsMessage` |
  | `.providerNotReady` | `profile.providerID.credentialLabel` | `"Required"` | `.focusCredential` / `"Add Key"` when readiness is `.needsAPIKey`, else `nil` | `failure.settingsMessage` |

  `nil` failure → no activation requirement.

  **Hard rule:** no activation `actionTitle` may equal `"Enable"` or
  `"Open Settings"` — the shipped URL test selects `visibleButtons.first` by
  exactly those titles.

- **Microphone requirement** — always present, every provider, unconditionally.
  `row = SettingsPermissionPolicy.microphone(microphone)` **composed, never
  restated**. Title `"Microphone"`. Action `.requestMicrophone`. Reason: default
  `"This channel can't start a session without microphone access."`;
  `.chatGPTWeb` gets the ChatGPT-window wording above — a `switch` with a
  `default`, not a per-provider table.

- **Accessibility requirement** — present **only** when
  `registration == .eventMonitorFallback && isRecordingHotKey == false`.
  `row = SettingsPermissionPolicy.accessibility(isTrusted:)`. Title
  `"Accessibility"`. Action `.requestAccessibility`. Reason interpolates
  `profile.hotKey?.displayName` only.

- `outstanding` = requirements where `row.isReady == false`, in order
  activation → microphone → accessibility. `summary = readySummary` when empty.

- **Secret rule (load-bearing):** takes `hasCredential: Bool`, never the key.
  **No returned string may interpolate `profile.endpointURL`, an API key, or a
  token** — OpenClaw endpoints can carry a gateway token in the query string.
  Only the hotkey display name and provider display/credential labels may be
  interpolated.

`requirementSummary(for:)` — static per-provider copy for the add-channel
alert. Reads no live state. `switch` over `VoiceProviderID` with **no
`default`**, so a seventh provider fails the build until someone states its
requirements.

### `Sources/VoiceKey/SettingsWindowController.swift`

**Do not modify** `PermissionRowSnapshot`, `SettingsPermissionsSnapshot`,
`SettingsPermissionPolicy`, or the `permissionsSnapshot` property. They are
pinned contracts and they now feed the new policy.

**Protocol** (`SettingsWindowControllerDelegate`, :373-386) — add two methods,
**both with defaults in the existing extension** at :388-397 so no conformance
breaks:

```swift
func settingsController(_ controller: SettingsWindowController,
                        hotKeyRegistrationFor profileID: UUID) -> ChannelHotKeyRegistration   // default .unknown
func settingsControllerDidChangeSetup(_ controller: SettingsWindowController)                 // default {}
```

A delegate method, not an injected init closure: `presentSettings` assigns
`controller.delegate = self` immediately after construction, `delegate` is
already `weak`, and the 16-parameter initializer does not grow.

**New outlets**, declared beside the existing permission outlets:
- `setupActivationTitleLabel`, `setupActivationStatusLabel`, `setupActivationButton`
- `setupActivationReasonLabel`, `microphoneSetupReasonLabel`,
  `accessibilitySetupReasonLabel`, `setupSummaryLabel` — all
  `NSTextField(wrappingLabelWithString: "")`, 11pt `.secondaryLabelColor`,
  `maximumNumberOfLines = 3`, styled exactly like `credentialSharingLabel`
  (:1305-1307)
- stored `NSStackView?` refs for all three rows and all three reason rows, plus
  `setupSectionHeader: NSTextField?`

**Layout helper** — generalize `makePermissionRow(title:statusLabel:actionButton:)`
(:1361-1387) into `makeRequirementRow(titleLabel:statusLabel:actionButton:)`
with its body unchanged. Keep `makePermissionRow(title:)` as a thin wrapper —
the two existing rows must be pixel-identical. Make `addSection(_:)`
(:1400-1405) `@discardableResult -> NSTextField` and store the Setup header.

**Build** — delete the Permissions block at :1085-1098. Insert immediately after
`endSection(after: nameRow)` (:843), before the Voice Provider section:

```
setupSectionHeader = addSection("Setup")
addArranged(activationRow);    addArranged(indentedRow(setupActivationReasonLabel))
addArranged(microphoneRow);    addArranged(indentedRow(microphoneSetupReasonLabel))
addArranged(accessibilityRow); addArranged(indentedRow(accessibilitySetupReasonLabel))
addArranged(setupSummaryLabel)
endSection(after: setupSummaryLabel)
```

**HARD REQUIREMENT: pre-build every row at `buildContent()` time. No `NSView`
may be created, added, or removed after `buildContent()` returns.** Render only
assigns `stringValue` / `title` / `textColor` / `isHidden`. Use only
`makeRequirementRow` / `indentedRow` / `addArranged`; activate **zero** new
inter-view constraints (`addArranged` already does add-then-constrain;
`indentedRow` uses `edgeInsets`). Rebuilding on a 1 Hz timer would re-activate
constraints on a scrolled form forever, and a rebuild landing between mouse-down
and mouse-up swallows the click.

Set `button.identifier = NSUserInterfaceItemIdentifier(requirementID.rawValue)`
on all three action buttons so tests target identity, not prose.

**Snapshot** — add `var channelSetupSnapshot: ChannelSetupSnapshot` beside
`permissionsSnapshot` (:487-499), live-derived: no selected profile →
`ChannelSetupSnapshot(outstanding: [], summary: ChannelSetupPolicy.noChannelSummary)`;
otherwise assembled from the working profile, `credentialStore.hasAPIKey(for:)`,
`microphoneAuthorizationProvider()`, `isAccessibilityTrusted()`,
`isRecordingHotKey`, and
`delegate?.settingsController(self, hotKeyRegistrationFor: profile.id) ?? .unknown`.

**Render** — rename `syncPermissionsPanel` → `syncChannelSetup`,
`startPermissionsPolling` → `startSetupPolling`, `permissionsTimer` →
`setupTimer`. Keep every freshness trigger and invalidation site unchanged.

```swift
private func syncChannelSetup() {
    let snapshot = channelSetupSnapshot
    let hadPrevious = renderedChannelSetup != nil
    guard snapshot != renderedChannelSetup else { return }   // REQUIRED — runs at 1 Hz
    renderedChannelSetup = snapshot
    … render every row and reason line, satisfied or not …
    … reset custom spacing after the last non-hidden view in the section …
    if hadPrevious { delegate?.settingsControllerDidChangeSetup(self) }
}
```

**MANDATORY rendering rule:** on every render, assign `isHidden` on **both** the
row and its action button for **all three** requirements, present or not. The
test walker filters on the *button's own* `isHidden`, so hiding only the
containing row leaves a stale button findable.

Store `private var renderedActivationAction: ChannelSetupAction?` at render
time. One `@objc private func handleSetupRequirementAction(_ sender: NSButton)`
dispatches on `ChannelSetupRequirementID(rawValue: sender.identifier?.rawValue)`:
- `.activation` → switch on `renderedActivationAction`: `.recordHotKey` → scroll
  to the Shortcut section and call the existing `beginHotKeyRecording()` (:791);
  `.focusEndpoint` → scroll and focus `endpointField`; `.focusCredential` →
  scroll to Credentials and focus `apiKeyField`
- `.microphone` → **the body of `handleMicrophonePermissionAction` verbatim**
  (:2699-2714), including the exact pane URL string
- `.accessibility` → **the body of `handleAccessibilityPermissionAction`
  verbatim** (:2716-2727), including the exact pane URL string

`requestMicrophoneAccess` and `requestAccessibilityAccess` must be reachable
from **this one function and nowhere else in the file**. That is the mechanical
guarantee that adding a channel never fires an OS prompt.

**Recording flag** — in `init`, extend the existing
`recorderView.onRecordingStateChanged` closure (:734-737) to also set
`self.isRecordingHotKey = isRecording` and call `syncChannelSetup()`. Do **not**
change `setHotKeyRecording` in the app delegate — suspending registrations
during capture is deliberate and commented.

**Wiring — this is the entire connection to the add flow, two lines.** Call
`syncChannelSetup()` from `syncFormFromSelectedProfile` (:1602-1662, beside
`syncOpenClawRuntimePanel`) and from `syncEmptyForm` (:1664-1693).
`selectProfile` already routes through the former, so add, duplicate, delete,
provider change and channel switching are all covered.

**Reveal after add** — add `private func revealChannelSetup()`:
`formStackView.layoutSubtreeIfNeeded()` then
`setupSectionHeader?.scrollToVisible(...)` (`NSView.scrollToVisible` finds its
own `enclosingScrollView`). Call at the end of `addProfile()` (after
`selectProfile`, :1938) and `duplicateProfile()`. **Do not move first
responder.**

**Picker** — `VoiceChannelProviderPickerView` (:2894-2951) gains a third
wrapping 11pt `.secondaryLabelColor` label under `descriptionLabel`, text from
`ChannelSetupPolicy.requirementSummary(for:)`, refreshed inside the existing
`selectionChanged()`.

> **Geometry hazard, verified:** the view has a hard-coded
> `NSRect(x: 0, y: 0, width: 440, height: 72)` and its stack is pinned
> leading/trailing/top with **no bottom pin**. A wrapping third line will clip.
> Fix by pinning `stack.bottomAnchor` to `bottomAnchor`, setting
> `preferredMaxLayoutWidth = 440` on **both** wrapping labels, and setting
> `frame = NSRect(origin: .zero, size: stack.fittingSize)` at the end of
> `selectionChanged()`. **Do not** hard-code a taller fixed height. Verify by
> running the app; no test can see clipping.

`handleRecordedHotKey` (:2352-2386): **unchanged.**

### `Sources/VoiceKey/VoiceKeyAppDelegate.swift`

```swift
func hotKeyRegistration(for profileID: UUID) -> ChannelHotKeyRegistration {
    guard profiles.first(where: { $0.id == profileID })?.hotKey != nil else { return .noHotKey }
    return carbonRegisteredProfileIDs.contains(profileID) ? .carbonRegistered : .eventMonitorFallback
}
```

**Hard constraint:** pure `Set` lookup, zero side effects. It must **never**
reach `HotKeyFallbackPolicy.diagnostic`, which calls `requestAccessibilityTrust()`
as a side effect of building a log string (`AppFlowPolicies.swift:231-244`). A
1 Hz accessibility prompt would be a serious regression.

**Subtraction:** rewrite `hotKeyDiagnosticLine(for:)` (:918-928) to call
`hotKeyRegistration(for:)` plus
`registration.diagnosticTerm(isAccessibilityTrusted: isAccessibilityTrusted())`
instead of its inline nested ternary. Output must be byte-identical. This is the
one genuine dedup in the change — an existing model absorbed, not paralleled.

Implement both new delegate methods in the existing extension (:941-1049):

```swift
func settingsController(_ c: SettingsWindowController, hotKeyRegistrationFor id: UUID) -> ChannelHotKeyRegistration {
    hotKeyRegistration(for: id)
}
func settingsControllerDidChangeSetup(_ c: SettingsWindowController) { updateMenuContent() }
```

The second fixes a live bug: `updateMenuContent()` has eleven call sites and not
one is permission-driven, so granting the microphone from Settings today leaves
the menu on "Finish Setup…" until something unrelated fires.

### Explicitly unchanged

`VoiceProvider.swift`, `OnboardingState.swift`, `OnboardingWizardController.swift`,
`OnboardingDiagnostics.swift`, `AppFlowPolicies.swift`. A non-empty
`git diff --stat` on any of these fails review.

**Not in this WO** (both are real, both were considered and deliberately
deferred — do not start them): extracting a shared `PermissionPriming` module
and refactoring the wizard onto it; adding a diagnostics sink to Settings.

## Hazards — all verified in source

1. **1 Hz churn.** `syncChannelSetup` runs on a repeating timer over a scrolled
   form. The `renderedChannelSetup` equality guard is **not optional polish —
   treat a missing guard as a defect.**
2. **Recording clears registration state.** `setHotKeyRecording(true)` calls
   `carbonRegisteredProfileIDs.removeAll()` (`VoiceKeyAppDelegate.swift:1039-1048`),
   and recording happens *in this very window*. Without the `isRecordingHotKey`
   suppression, every channel reads `.eventMonitorFallback` and a red
   Accessibility row flashes at 1 Hz exactly while the owner records a shortcut.
   **Do not "fix" this by changing `setHotKeyRecording`.**
3. **Custom spacing after a hidden view.** `endSection(after:)` sets custom
   spacing after a view that will now often be hidden, and `NSStackView`
   detaches hidden arranged subviews. Re-set
   `formStackView.setCustomSpacing(20, after: <last non-hidden view in section>)`
   at the end of each render.
4. **Window height.** Worst case is 3 rows + 3 reason lines (~+75pt) against
   today's 2 rows. If the sizing gate goes red, raise the 900pt default at
   :707 and re-check `contentMinSize` (540×640). **Do not trim the reason
   lines** — they are the part that answers the complaint.
5. **Delegate is `weak`.** Any test double must be held in a strong local for
   the duration of the test.
6. **First-render delegate callback.** `renderedChannelSetup` starts `nil`, so
   the first render must not fire `settingsControllerDidChangeSetup`.

## Test plan

House conventions, verified: one XCTest target run by plain `swift test`; no UI
test target; controllers build their window in `init` so
`controller.window?.contentView` is walkable without showing; UI state asserted
through whole `Equatable` snapshot structs plus recursive view-tree walks;
doubles are injected closures and file-private `final class` fakes; **no
`Thread.sleep`, no `usleep`, no fixed-duration `RunLoop.run`** — use `waitUntil`
from `Tests/VoiceKeyTests/OnboardingAsyncWait.swift:13-25`; any test calling
`showAndFocus()` must end with `controller.close()`.

### NEW `Tests/VoiceKeyTests/ChannelSetupPolicyTests.swift` (pure, no window)

| Test | Asserts |
|---|---|
| `testEveryProviderRequiresTheMicrophone` | Loop `VoiceProviderID.allCases` with microphone `.denied` → every provider, `chatGPTWeb` included, yields an outstanding microphone requirement |
| `testMicrophoneRowCopyComesFromTheShippedPolicy` | For all four states, `requirement.row == SettingsPermissionPolicy.microphone(state)` exactly — proves composition, so the two policies cannot drift |
| `testChatGPTWebExplainsTheSilentFailure` | ChatGPT Web reason differs from the default and names the ChatGPT window |
| `testCarbonRegisteredChannelNeverMentionsAccessibility` | `.carbonRegistered` + untrusted + mic authorized + ready profile → `outstanding.isEmpty`, `summary == readySummary`. **The anti-nag gate; most important assertion in the feature** |
| `testAccessibilityAppearsOnlyForUntrustedFallback` | Loop all four registration cases → only `.eventMonitorFallback` may emit it |
| `testAccessibilityIsSuppressedWhileRecording` | `.eventMonitorFallback` + untrusted + `isRecordingHotKey: true` → absent (pins hazard 2) |
| `testFallbackShortcutNamesTheShortcutItCannotRegister` | Reason contains the hotkey display name; flipping trusted clears `outstanding` |
| `testActivationRequirementMirrorsProfileActivationPolicy` | Cross-product over provider × hasHotKey × hasCredential × endpoint: an `.activation` requirement exists iff `ProfileActivationPolicy.failure(for:hasAPIKey:) != nil`, and its `reason == failure.settingsMessage` |
| `testActivationActionTitlesNeverCollideWithPermissionActions` | No activation `actionTitle` equals `"Enable"` or `"Open Settings"` |
| `testNoSetupCopyContainsTheEndpointOrCredential` | Plant `"tok_SENTINEL_DO_NOT_LOG"` in `endpointURL`; assert it appears in no `title`, `status`, `reason`, `summary`, or `requirementSummary` output |
| `testRequirementSummaryCoversEveryImplementedProvider` | Non-empty and distinct for every implemented provider |
| `testDiagnosticTermMatchesTheShippedStrings` | Three assertions pinning the exact registration terms, so the `hotKeyDiagnosticLine` refactor is provably behaviour-preserving |

### EXTEND `Tests/VoiceKeyTests/SettingsAutoApplyTests.swift`

| Test | Asserts |
|---|---|
| `testChannelSetupSnapshotIsDerivedLive` | Flip captured `var`s, compare the whole snapshot before and after |
| `testReadyChannelCollapsesToTheSummaryLine` | Ready channel → `outstanding.isEmpty`; walk `descendantViews` and assert all three rows **and their buttons** are `isHidden` while the summary label is visible |
| `testEmptyFormShowsTheAddAChannelSummary` | No selected profile → the exact summary string; every row hidden |
| `testSwitchingChannelsResyncsSetup` | Two channels, delegate double returns `.carbonRegistered` for one and `.eventMonitorFallback` for the other, untrusted; select each → the accessibility row appears only for the second. **This is the test that fails against today's code** |
| `testAddingAChannelNeverRequestsMicrophoneAccess` | Counting `requestMicrophoneAccess`, mic `.notDetermined`, drive `commitNewProfile(_:)` (the testable seam — `addProfile()` sits behind `runModal()`) → count is 0 |
| `testAddingAChannelSurfacesTheMissingShortcut` | After `commitNewProfile`, `outstanding.first?.id == .activation` with the shortcut reason |
| `testChangingProviderRebuildsRequirements` | Fire the provider popup's ChatGPT Web item → credential requirement disappears, microphone remains |
| `testSetupChangeNotifiesTheDelegate` | `showAndFocus()`, flip the injected mic var, `waitUntil { delegate.setupChangeCount > 0 }`, then `controller.close()` |
| `testNoStaleButtonSurvivesASatisfiedRequirement` | Render with mic `.denied`, flip to `.authorized`, re-render; no visible button carries a stale `"Open Settings"`/`"Enable"` |
| `testWindowIsTallEnoughForAChannelMissingEverything` | Worst case → `contentHeight >= formHeight` |
| `testProviderPickerStatesWhatTheChannelWillNeed` | Construct `VoiceChannelProviderPickerView()` directly, walk subviews for the third label, assert it equals `requirementSummary(for: .openAIRealtime)` and follows a popup selection change. **First-ever coverage of this view** |

### Exactly one sanctioned edit to a green test

`testPermissionRowsRequestOrOpenTheirExactPane` (:386-464) — its third block
sets mic `.authorized` + accessibility `false` and takes the first visible
`"Open Settings"` button, expecting the Accessibility one. With `.unknown`
correctly emitting no accessibility requirement and the controller built without
a delegate, that button will not exist. **Install a strongly-held delegate
double returning `.eventMonitorFallback`.** That is the only permitted change.
Both exact pane URL assertions, both request-count assertions, and the closing
`controller.close()` survive verbatim. If anything else in this test needs
touching, the implementation drifted — fix the implementation.

### Must stay green with zero edits

`testPermissionsSnapshotIsDerivedLive` (:313),
`testPermissionPolicyDistinguishesDeniedAndRestricted` (:367),
`testWindowDefaultsTallEnoughAndHasNoSaveButton` (:1167 — if it fails, bump the
default height, do not shrink the rows), `testAddDuplicateDeleteEachAutoApply`
(:525), the Settings lifecycle tests in
`HotKeyRoutingAndSettingsLifecycleTests.swift:181-203`, and **every test in
`OnboardingWizardTests.swift` and `OnboardingDiagnosticsTests.swift`**.

### App run (required by AGENTS.md; no test substitutes)

`./scripts/build-app.zsh && open .build/VoiceKey.app`. Add an OpenAI channel and
a ChatGPT Web channel with the microphone denied. Confirm: the alert's third
line is not clipped for **every** provider including the long OpenClaw copy; the
Setup section is visible without scrolling at the 620×900 default; nothing clips
at the 540×640 minimum; clicking Enable turns the row green within a second and
the section collapses; the menu bar stops reading "Finish Setup…"; **no row
flickers while recording a shortcut**; the Accessibility row is absent for a
normally Carbon-registered shortcut. Then run the first-run wizard from a clean
state and confirm the microphone screens are unchanged. Screenshot the changed
screens.

## Verified facts — do not re-investigate

Every line below was read in source by the scoping pass and spot-checked by the
CTO session.

**Settings shape and the add flow**
- Single scrolling form, no list/detail split: one `NSScrollView` whose
  `documentView` is `formStackView` — `SettingsWindowController.swift:804-823`
- Section order: Voice Channel → Voice Provider → OpenClaw runtime → Shortcut →
  Credentials → Permissions → Instructions → footer — `:835, 845, 926, 978, 988, 1085, 1101`
- `addSection("Permissions")` occurs **exactly once in the repo**, at `:1085`;
  no test pins the string
- Neither `syncFormFromSelectedProfile` (`:1602-1662`) nor `syncEmptyForm`
  (`:1664-1693`) touches the permission rows
- `addProfile()` → `chooseProviderForNewChannel()` →
  `VoiceChannelOperations.makeChannel` → `commitNewProfile` → `selectProfile`;
  no permission check anywhere — `:1931-1940`
- `chooseProviderForNewChannel()` is a blocking `alert.runModal()` with a
  `VoiceChannelProviderPickerView` accessory — `:2064-2076`
- `commitNewProfile(_:)` is the internal, drivable seam already used by tests —
  `:1942-1959`
- New channels are always `hotKey: nil`; `duplicate` sets `copy.hotKey = nil` —
  `:17-34`, `:36-55`
- `VoiceProfile.defaultOpenAI()` **does** carry `.defaultVoiceToggle`, so
  existing tests' profiles have a hotkey — `VoiceProfile.swift:99-110`

**The picker accessory**
- Hard-coded `NSRect(x: 0, y: 0, width: 440, height: 72)`; stack pinned
  leading/trailing/top, **no bottom pin**; `selectionChanged()` sets only
  `descriptionLabel.stringValue` — `:2894-2951`
- Zero references anywhere under `Tests/`

**Permission model**
- `PermissionRowSnapshot` / `SettingsPermissionsSnapshot` — `:133-142`
- `SettingsPermissionPolicy.microphone` distinguishes four states; `.accessibility`
  is binary — `:223-264`
- `permissionsSnapshot` is live-derived, nothing cached — `:487-499`
- Five injected closures with production defaults — `:603-609`, `:634-674`
- `renderPermissionRow` writes `"● \(status)"`, `.systemGreen`/`.systemRed`, and
  **`button.isHidden = snapshot.actionTitle == nil`** — `:2671-2681`
- Freshness: `didBecomeActive` observer in `init` (`:721-727`), `showAndFocus`
  (`:761-767`), `windowDidBecomeKey`, 1s `Timer` on `RunLoop.main` `.common`
  (`:2683-2697`); invalidated in `windowWillClose` (`:2873`) and `deinit`
  (`:743-750`)
- Mic action requests inline for `.notDetermined`, otherwise deep-links
  `…?Privacy_Microphone`; accessibility action calls `requestAccessibilityAccess()`
  **and** opens `…?Privacy_Accessibility` — `:2699-2727`

**Layout idioms**
- `addSection` = bold 13pt header + hairline separator, custom spacing 4;
  `endSection(after:)` = custom spacing 20; `addArranged` = `addArrangedSubview`
  **then** activate trailing to `formStackView` −20 — `:1400-1431`
- `indentedRow` uses `edgeInsets` (left `labelColumnWidth + 12` = 152pt), **not
  constraints** — `:1390-1398`
- `makePermissionRow` = 140pt styled title, hugging-1 spacer, status, button,
  spacing 10 — `:1361-1387`; `labelColumnWidth = 140` — `:619`
- `addFullWidth` does **not** exist in Settings; it is onboarding-only

**Window and sizing**
- Default 620×900, `contentMinSize` 540×640, resizable — `:707-716`
- `testWindowDefaultsTallEnoughAndHasNoSaveButton` asserts
  `contentHeight >= formHeight` and builds with **all defaults** (no delegate →
  `.unknown`; `InMemoryCredentialStore` → no key → a `.providerNotReady`
  activation requirement) — `SettingsAutoApplyTests.swift:1167-1193`

**Delegate and app delegate**
- `weak var delegate`; protocol has five methods, two with empty defaults in the
  extension — `:373-397`
- `presentSettings` calls `registerAllHotKeys()`, constructs the controller,
  **then** assigns `controller.delegate = self`, then `showAndFocus()` —
  `VoiceKeyAppDelegate.swift:657-674`
- `carbonRegisteredProfileIDs: Set<UUID>` is private; its only external
  expression is `hotKeyDiagnosticLine`'s nested ternary — `:59`, `:918-928`
- `registerHotKey` inserts into `carbonRegisteredProfileIDs` on success; on
  `GlobalHotKey` init returning nil it calls `HotKeyFallbackPolicy.diagnostic`,
  which **prompts for AX trust as a side effect of building a log string** —
  `:321-353`, `AppFlowPolicies.swift:231-244`
- **`setHotKeyRecording(true)` calls `carbonRegisteredProfileIDs.removeAll()`**
  while the recorder captures; the comment above it explains why — `:1030-1048`
- `recorderView.onRecordingStateChanged` already notifies the delegate —
  `SettingsWindowController.swift:734-737`
- Carbon `RegisterEventHotKey` needs no AX trust; `GlobalHotKey.init?` returns
  nil on failure — `GlobalHotKey.swift:81-106`. Only
  `NSEvent.addGlobalMonitorForEvents` needs trust — `VoiceKeyAppDelegate.swift:366-386`
- `updateMenuContent()` has eleven call sites, none permission-driven; there is
  no `NSMenuDelegate` and no app-level `didBecomeActive` observer

**Activation policy**
- `ProfileActivationPolicy.failure(for:hasAPIKey:)` checks in order: hotkey →
  custom-endpoint (whitespace-trimmed) → `provider.readiness(hasAPIKey:).allowsVoiceToggle`
  — `AppFlowPolicies.swift:32-53`
- `ProfileActivationFailure.settingsMessage`: `"Record a global shortcut for
  this voice channel."` / `"Set the endpoint URL for this voice channel."` / the
  readiness message — `:16-31`
- `readiness`: `.custom` and `.openClaw` always `.ready`; non-`requiresAPIKey` →
  `.providerSignIn`; otherwise `.needsAPIKey("\(credentialLabel) required.")`.
  Only `.needsAPIKey` and `.unavailable` block `allowsVoiceToggle`, so
  **ChatGPT Web never produces a credential requirement** — `VoiceProvider.swift:191-244`

**Test conventions**
- `descendantButtons(in:)` walks recursively and filters on **the button's own**
  `isHidden` — `SettingsAutoApplyTests.swift:1241-1253`
- `sendAction` uses `NSApplication.shared.sendAction(_:to:from:)` and asserts it
  returns true — `:1255-1265`
- `waitUntil` spins the run loop in 5 ms slices; its doc comment records the
  2026-07-27 incident where a fixed-duration `RunLoop.run(until:)` starved on a
  loaded runner and the following `removeFirst()` trapped the **whole process** —
  `OnboardingAsyncWait.swift:3-25`
- No `Thread.sleep`/`usleep` anywhere under `Tests/`
- Leak-gate shape: type a real-looking secret into the real field, drive the
  action, assert the collaborator got the raw value and
  `XCTAssertFalse(log.text.contains(secret))` — `OnboardingDiagnosticsTests.swift:447-547`

**Wizard (the "do not touch" boundary)**
- `OnboardingStep` has no accessibility case — `OnboardingState.swift:172-181`;
  `OnboardingGroundTruth` has six fields, none accessibility — `:31-38`
- `AXIsProcessTrusted` appears only in the app delegate, Settings and
  `WebWindowController`, never in the wizard
- The wizard's denied/restricted microphone recovery screen has **zero test
  coverage** — controller tests stub `microphoneAuthorizationProvider` to
  `.authorized`

## Skip-and-flag authority

Ship the rest and flag in the summary rather than fighting any of these:

1. **The picker's third line.** The only edit touching AppKit geometry, and no
   test can see clipping. If the frame fix does not render cleanly in the app
   run within reasonable effort, **drop the third label entirely** and ship
   everything else.
2. **The section move.** Keep the relocation as a separable final commit. If the
   sizing gate or the app run fights it, drop that commit and leave the section
   where it is; the rewiring is what fixes the complaint.
3. **Default window height.** If the sizing gate goes red, raise the 900pt
   default at `:707`. If a sensible value still fails, flag with measured
   numbers rather than trimming reason lines.
4. **Custom-spacing re-set.** If the app run shows `NSStackView` already handles
   spacing across a hidden arranged subview, drop the re-set call and say so.
5. **`.providerNotReady` action mapping.** If mapping the erased failure back to
   an action title proves awkward, ship the row with `actionTitle: nil` (reason
   line only) and flag it.
6. **Anything you cannot verify.** Do not assert a contract you did not read.

Do **not** skip: the equality guard, the recording suppression, the
both-row-and-button `isHidden` rule, the secret rule, or the pure-`Set`-lookup
constraint on `hotKeyRegistration(for:)`.

## Acceptance

1. `swift test` green. `git diff --stat` is **empty** for
   `OnboardingWizardController.swift`, `OnboardingState.swift`,
   `OnboardingDiagnostics.swift`, `AppFlowPolicies.swift`, `VoiceProvider.swift`,
   `OnboardingWizardTests.swift`, `OnboardingDiagnosticsTests.swift`.
2. `testPermissionsSnapshotIsDerivedLive` and
   `testPermissionPolicyDistinguishesDeniedAndRestricted` pass with **zero
   edits**; `SettingsPermissionPolicy`, `PermissionRowSnapshot`,
   `SettingsPermissionsSnapshot` and `permissionsSnapshot` keep their names,
   shapes and every copy string.
3. `testPermissionRowsRequestOrOpenTheirExactPane` is edited in exactly one way —
   a strongly-held delegate double returning `.eventMonitorFallback`.
4. **No `NSView` is instantiated, added, or removed after `buildContent()`
   returns.** Grep the render path for `addArrangedSubview` /
   `removeFromSuperview` / `NSStackView(` and find nothing.
5. Adding a channel with the microphone `.notDetermined` fires **zero** OS
   prompts (counting-closure test through `commitNewProfile`).
6. Immediately after adding an OpenAI channel with no key and the mic denied,
   `channelSetupSnapshot.outstanding` reads exactly `[.activation, .microphone]`
   in that order.
7. The accessibility requirement appears for `.eventMonitorFallback` **only**,
   and never while the recorder is capturing.
8. Every provider requires the microphone, `chatGPTWeb` included;
   `VoiceProvider.swift` is unmodified.
9. `hotKeyDiagnosticLine` output is byte-identical after the refactor.
10. `requestAccessibilityTrust` is invoked **zero** times across ≥3 seconds of
    polling with a channel in every registration state.
11. No setup string contains the endpoint URL, an API key, or a token (sentinel
    test).
12. With state unchanged, `syncChannelSetup` performs no writes and fires no
    delegate callback; `settingsControllerDidChangeSetup` fires exactly once per
    real change, never on first render.
13. Granting the microphone from the Setup section stops the menu title reading
    "Finish Setup…" (asserted via `waitUntil`, never a sleep).
14. Window sizing invariant holds in the **worst** case as well as the default.
15. `VoiceChannelProviderPickerView` has its first test.
16. The app-run walkthrough is completed and reported honestly, including the
    minimum-window-size and no-flicker-while-recording checks.

## Commit shape

Small, reviewable commits on `channel-setup`; the section move last and
separable. No AI co-author trailers. Do not push; the CTO session reviews,
merges `--no-ff`, and pushes.
