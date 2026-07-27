@testable import VoiceKey
import AppKit
import Foundation
import XCTest

/// The wizard's on-disk diagnostics are the only observability a remote
/// first-run test has — macOS will not grant Screen Recording to an ssh'd CLI
/// binary — so these tests pin what a walkthrough must leave behind and, above
/// all, what it must never contain.
final class OnboardingLogEventTests: XCTestCase {
    func testEveryAPIKeyOutcomeIsWrittenAsACategoryOnly() {
        let outcomes: [(
            Result<Void, APIKeyVerificationError>,
            String
        )] = [
            (.success(()), "verification verified"),
            (.failure(.rejected), "verification rejected"),
            (
                .failure(.serverStatus(503)),
                "verification server-status-503"
            ),
            (.failure(.network), "verification network-failure")
        ]

        for (result, expected) in outcomes {
            let event = OnboardingLogEvent.apiKeyVerification(
                OnboardingWizardController.verificationCategory(
                    for: result
                )
            )
            XCTAssertEqual(event.kind, "apikey")
            XCTAssertEqual(event.text, expected)
        }
    }

    func testOpenClawOutcomesKeepTheirTypedCaseNameAndNonSecretDetail() {
        XCTAssertEqual(
            OnboardingLogEvent.openClawOutcome(
                .ok(
                    serverVersion: "2026.7.1-2",
                    scopes: ["operator.read", "operator.write"]
                ),
                endpoint: "wss://gateway.example.com/ws"
            ).text,
            "outcome=ok serverVersion=2026.7.1-2 scopes=2 endpoint=wss://gateway.example.com/ws"
        )
        XCTAssertEqual(
            OnboardingLogEvent.openClawOutcome(
                .pairingRequired(
                    reason: "device-not-approved",
                    requestID: "req_42",
                    remediationHint: "Approve it."
                ),
                endpoint: ""
            ).text,
            "outcome=pairingRequired reason=device-not-approved requestId=req_42 endpoint=auto-discovery"
        )
        XCTAssertEqual(
            OnboardingLogEvent.openClawOutcome(
                .unreachable(endpointsTried: [
                    "ws://127.0.0.1:8765",
                    "wss://gateway.example.com"
                ]),
                endpoint: "wss://gateway.example.com"
            ).text,
            "outcome=unreachable endpointsTried=ws://127.0.0.1:8765,wss://gateway.example.com endpoint=wss://gateway.example.com"
        )
        XCTAssertEqual(
            OnboardingLogEvent.openClawOutcome(
                .deviceTokenMismatch,
                endpoint: ""
            ).text,
            "outcome=deviceTokenMismatch endpoint=auto-discovery"
        )
    }

    func testEndpointsAreLoggedWithoutAnyEmbeddedCredential() {
        XCTAssertEqual(
            OnboardingLogEvent.sanitizedEndpoint(
                "wss://gateway.example.com/ws?token=super-secret-token"
            ),
            "wss://gateway.example.com/ws"
        )
        XCTAssertEqual(
            OnboardingLogEvent.sanitizedEndpoint(
                "https://operator:super-secret-token@gateway.example.com"
            ),
            "https://gateway.example.com"
        )
        XCTAssertEqual(
            OnboardingLogEvent.sanitizedEndpoint("  "),
            "auto-discovery"
        )
    }

    func testStepNamesAreStableWireTerms() {
        XCTAssertEqual(
            OnboardingStep.allCases.map(\.logName),
            [
                "location",
                "welcome",
                "services",
                "apiKey",
                "openClawConnect",
                "microphone",
                "hotKey",
                "done"
            ]
        )
    }

    func testGroundTruthExplainsWhyAStepWasChosen() {
        let missingKey = OnboardingGroundTruth(
            applicationLocation: .applications,
            selectedServices: [.openAI],
            hasOpenAIAPIKey: false,
            hasOpenClawConnection: false,
            microphoneAuthorization: .authorized,
            hasHotKeysForSelectedServices: true
        )
        let resolved = OnboardingFlowPolicy
            .firstIncompleteStepWithReason(
                groundTruth: missingKey
            )
        XCTAssertEqual(resolved.step, .apiKey)
        XCTAssertEqual(resolved.reason, .openAIKeyMissing)
        XCTAssertEqual(
            OnboardingFlowPolicy.reason(
                for: .done,
                groundTruth: missingKey
            ),
            .userChoice,
            "Reaching Done while a fact is still missing is a choice, not completion."
        )

        var complete = missingKey
        complete.hasOpenAIAPIKey = true
        XCTAssertEqual(
            OnboardingFlowPolicy
                .firstIncompleteStepWithReason(
                    groundTruth: complete
                )
                .reason,
            .everythingComplete
        )
        XCTAssertEqual(
            OnboardingFlowPolicy.reason(
                for: .microphone,
                groundTruth: complete
            ),
            .userChoice
        )
    }
}

final class OnboardingWizardDiagnosticsTests: XCTestCase {
    func testOpeningRecordsTheResolvedStepAndItsGroundTruthReason() {
        let log = RecordingOnboardingDiagnostics()
        let controller = makeController(
            log: log,
            services: [.openAI],
            hasAPIKey: false
        )
        defer { controller.close() }

        controller.showReentrant()

        XCTAssertEqual(controller.currentStepSnapshot, .apiKey)
        XCTAssertEqual(
            log.lines.first,
            "wizard: opened reentrant at step=apiKey reason=openai-key-missing"
        )
    }

    func testFreshOpenRecordsWelcomeAndCloseRecordsWhereItStopped() {
        let log = RecordingOnboardingDiagnostics()
        let controller = makeController(
            log: log,
            services: [.openAI],
            hasAPIKey: false
        )

        controller.showInitial()
        XCTAssertEqual(
            log.lines.first,
            "wizard: opened fresh at step=welcome reason=first-run"
        )

        controller.close()
        XCTAssertEqual(
            log.lines.last,
            "wizard: closed at step=welcome"
        )
    }

    func testEveryTransitionIsRecordedAndSkipsAreMarkedAsSkipped() {
        let log = RecordingOnboardingDiagnostics()
        let controller = makeController(
            log: log,
            services: [.openAI],
            hasAPIKey: false
        )
        defer { controller.close() }
        controller.showInitial()

        perform(title: "Get Started", in: controller)
        XCTAssertEqual(controller.currentStepSnapshot, .services)
        perform(title: "Continue", in: controller)
        XCTAssertEqual(controller.currentStepSnapshot, .apiKey)
        perform(title: "Skip for now", in: controller)

        XCTAssertEqual(
            log.lines(ofKind: "step"),
            [
                "step: welcome -> services trigger=advance reason=user-choice",
                "step: services -> apiKey trigger=advance reason=openai-key-missing",
                "step: apiKey -> done trigger=skipped reason=user-choice"
            ]
        )
        XCTAssertEqual(
            log.lines(ofKind: "services"),
            ["services: confirmed openAI added=none"]
        )
        XCTAssertEqual(
            log.lines(ofKind: "channels"),
            ["channels: ensured openAI openClawEndpoint=absent"]
        )
    }

    func testReopeningAFinishedSetupRecordsThePickerAndTheServiceItAdds() {
        let log = RecordingOnboardingDiagnostics()
        let controller = makeController(
            log: log,
            services: [.openAI],
            hasAPIKey: true
        )
        defer { controller.close() }

        controller.showManualReentry()
        XCTAssertEqual(
            controller.currentStepSnapshot,
            .services
        )
        guard let checkbox = allViews(
            ofType: NSButton.self,
            in: controller.window?.contentView
        ).first(where: { $0.title == "OpenClaw" }) else {
            return XCTFail("The OpenClaw card never rendered.")
        }
        checkbox.state = .on
        _ = checkbox.target?.perform(
            checkbox.action,
            with: checkbox
        )
        perform(title: "Continue", in: controller)

        XCTAssertEqual(
            log.lines.first,
            "wizard: opened reentrant at step=services reason=add-another-service"
        )
        XCTAssertEqual(
            log.lines(ofKind: "services"),
            ["services: confirmed openAI, openClaw added=openClaw"]
        )
        XCTAssertEqual(
            log.lines(ofKind: "channels"),
            ["channels: ensured openAI, openClaw openClawEndpoint=absent"]
        )
        XCTAssertEqual(
            log.lines(ofKind: "step"),
            [
                "step: services -> openClawConnect trigger=advance reason=openclaw-not-connected"
            ]
        )
    }

    func testSkippingOneHotKeyChannelIsVisibleEvenWhenTheStepStays() {
        let log = RecordingOnboardingDiagnostics()
        let openAI = VoiceProfile(
            name: "OpenAI",
            providerID: .openAIRealtime,
            hotKey: nil,
            model: "model",
            voice: "voice"
        )
        let openClaw = VoiceProfile(
            name: "OpenClaw",
            providerID: .openClaw,
            hotKey: nil,
            model: "",
            voice: ""
        )
        let controller = makeController(
            log: log,
            services: [.openAI, .openClaw],
            hasAPIKey: true,
            hasOpenClawConnection: true,
            profiles: [openAI, openClaw]
        )
        defer { controller.close() }
        controller.showReentrant()
        XCTAssertEqual(controller.currentStepSnapshot, .hotKey)

        perform(title: "Skip for now", in: controller)
        XCTAssertEqual(controller.currentStepSnapshot, .hotKey)
        perform(title: "Skip for now", in: controller)

        XCTAssertEqual(
            log.lines(ofKind: "step"),
            [
                "step: hotKey skipped channel=OpenAI",
                "step: hotKey skipped channel=OpenClaw",
                "step: hotKey -> done trigger=skipped reason=user-choice"
            ]
        )
    }

    func testHotKeyCaptureRecordsChannelShortcutAndRegistrationResult() {
        let log = RecordingOnboardingDiagnostics()
        let openAI = VoiceProfile(
            name: "OpenAI",
            providerID: .openAIRealtime,
            hotKey: nil,
            model: "model",
            voice: "voice"
        )
        let delegate = RejectingHotKeyDelegate(
            profiles: [openAI]
        )
        let controller = makeController(
            log: log,
            services: [.openAI],
            hasAPIKey: true,
            profiles: [openAI]
        )
        controller.delegate = delegate
        defer { controller.close() }
        controller.showReentrant()
        XCTAssertEqual(controller.currentStepSnapshot, .hotKey)

        guard let recorder = firstView(
            ofType: HotKeyRecorderView.self,
            in: controller.window?.contentView
        ) else {
            return XCTFail("The hot-key step never rendered a recorder.")
        }
        recorder.onHotKeyRecorded?(
            openAI.id,
            .defaultVoiceToggle
        )
        delegate.accepts = true
        recorder.onHotKeyRecorded?(
            openAI.id,
            .defaultVoiceToggle
        )

        XCTAssertEqual(
            log.lines(ofKind: "hotkey"),
            [
                "hotkey: channel=OpenAI shortcut=\(HotKeyConfiguration.defaultVoiceToggle.displayName) registration-failed",
                "hotkey: channel=OpenAI shortcut=\(HotKeyConfiguration.defaultVoiceToggle.displayName) registered"
            ]
        )
    }

    func testMicrophoneTransitionsAreRecordedOncePerChange() {
        let log = RecordingOnboardingDiagnostics()
        var authorization = MicrophoneAuthorizationState.denied
        let controller = makeController(
            log: log,
            services: [.openAI],
            hasAPIKey: true,
            microphone: { authorization }
        )
        defer { controller.close() }

        controller.showReentrant()
        XCTAssertEqual(
            controller.currentStepSnapshot,
            .microphone
        )
        // "Check Again" re-samples without any change to report.
        perform(title: "Check Again", in: controller)
        authorization = .authorized
        perform(title: "Check Again", in: controller)

        XCTAssertEqual(
            log.lines(ofKind: "microphone"),
            [
                "microphone: unknown -> denied",
                "microphone: denied -> authorized"
            ]
        )
        XCTAssertEqual(
            log.lines(ofKind: "step").last,
            "step: microphone -> done trigger=ground-truth reason=everything-complete"
        )
    }

    func testRelocationGateOutcomesAreRecorded() {
        let log = RecordingOnboardingDiagnostics()
        let controller = makeController(
            log: log,
            services: [.openAI],
            hasAPIKey: true,
            location: .outsideApplications,
            moveApplication: { completion in
                completion(
                    .failure(
                        ApplicationRelocationError.relaunchFailed
                    )
                )
            }
        )
        defer { controller.close() }

        controller.showInitial()
        XCTAssertEqual(
            controller.currentStepSnapshot,
            .location
        )
        perform(title: "Move to Applications", in: controller)
        // The relocator answers on the main queue.
        waitUntil(
            { log.lines(ofKind: "location").count >= 3 },
            "The relocation failure never reached the log."
        )
        perform(title: "continue anyway", in: controller)

        XCTAssertEqual(
            log.lines(ofKind: "location"),
            [
                "location: gate state=outsideApplications",
                "location: move to Applications started",
                "location: move to Applications failed: VoiceKey moved, but macOS couldn’t reopen it.",
                "location: continued outside Applications"
            ]
        )
        XCTAssertEqual(
            log.lines(ofKind: "step"),
            [
                "step: location -> welcome trigger=relocation reason=first-run"
            ]
        )
    }

    func testAPIKeyVerificationReachesTheLogAsACategoryAndTheKeyNeverDoes() {
        let secret = "sk-live-do-not-log-9f8e7d6c5b4a"
        let log = RecordingOnboardingDiagnostics()
        let verifier = StubAPIKeyVerifier(
            result: .failure(.serverStatus(500))
        )
        let controller = makeController(
            log: log,
            services: [.openAI],
            hasAPIKey: false,
            verifier: verifier
        )
        defer { controller.close() }
        controller.showReentrant()
        XCTAssertEqual(controller.currentStepSnapshot, .apiKey)

        guard let field = firstView(
            ofType: NSSecureTextField.self,
            in: controller.window?.contentView
        ) else {
            return XCTFail("The API key step never rendered a field.")
        }
        field.stringValue = secret
        perform(title: "Verify", in: controller)
        verifier.result = .success(())
        field.stringValue = secret
        perform(title: "Verify", in: controller)

        XCTAssertEqual(
            log.lines(ofKind: "apikey"),
            [
                "apikey: verification server-status-500",
                "apikey: verification verified"
            ]
        )
        XCTAssertEqual(verifier.verifiedKeys, [secret, secret])
        XCTAssertFalse(
            log.text.contains(secret),
            "The API key reached the log: \(log.text)"
        )
    }

    func testGatewayTokenAndTokenBearingEndpointNeverReachTheLog() {
        let token = "vk-gateway-token-4d3c2b1a"
        let log = RecordingOnboardingDiagnostics()
        let tester = ReplayingOpenClawTester()
        let scheduler = ImmediateRetryScheduler()
        let wizard = OpenClawConnectionWizard(
            tester: tester,
            tokenProvider: { token },
            retryScheduler: scheduler.schedule,
            diagnostics: log
        )

        wizard.begin(
            endpointURL: "wss://gateway.example.com/ws?token=\(token)"
        )
        tester.completeNext(
            .pairingRequired(
                reason: "device-not-approved",
                requestID: "req_9",
                remediationHint: "openclaw devices approve req_9"
            )
        )
        scheduler.fireNext()
        tester.completeNext(
            .ok(serverVersion: "2026.7.1-2", scopes: ["operator.read"])
        )

        XCTAssertEqual(
            log.lines(ofKind: "openclaw"),
            [
                "openclaw: test #1 endpoint=wss://gateway.example.com/ws",
                "openclaw: outcome=pairingRequired reason=device-not-approved requestId=req_9 endpoint=wss://gateway.example.com/ws",
                "openclaw: test #2 endpoint=wss://gateway.example.com/ws auto-retry requestId=req_9",
                "openclaw: outcome=ok serverVersion=2026.7.1-2 scopes=1 endpoint=wss://gateway.example.com/ws"
            ]
        )
        XCTAssertFalse(
            log.text.contains(token),
            "The gateway token reached the log: \(log.text)"
        )
    }

    func testAbsentGatewayTokenIsRecordedAsAbsenceOnly() {
        let log = RecordingOnboardingDiagnostics()
        let tester = ReplayingOpenClawTester()
        let wizard = OpenClawConnectionWizard(
            tester: tester,
            tokenProvider: { nil },
            diagnostics: log
        )

        wizard.begin(endpointURL: "")

        XCTAssertEqual(
            log.lines(ofKind: "openclaw"),
            ["openclaw: token entered: absent"]
        )
        XCTAssertEqual(tester.testCount, 0)
    }

    // MARK: - Helpers

    private func makeController(
        log: RecordingOnboardingDiagnostics,
        services: Set<OnboardingService>,
        hasAPIKey: Bool,
        hasOpenClawConnection: Bool = false,
        profiles: [VoiceProfile] = [
            VoiceProfile.defaultOpenAI()
        ],
        verifier: APIKeyVerifying = StubAPIKeyVerifier(
            result: .success(())
        ),
        location: ApplicationLocationState = .applications,
        microphone: @escaping (
        ) -> MicrophoneAuthorizationState = { .authorized },
        moveApplication: @escaping (
            @escaping (Result<Void, Error>) -> Void
        ) -> Void = { _ in }
    ) -> OnboardingWizardController {
        let suiteName = "OnboardingWizardDiagnosticsTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        OnboardingServicePreferences.saveSelectedServices(
            services,
            defaults: defaults
        )
        OnboardingServicePreferences.setHasOpenClawConnection(
            hasOpenClawConnection,
            defaults: defaults
        )
        return OnboardingWizardController(
            profileProvider: { profiles },
            credentialStore: StubCredentialStore(
                hasAPIKey: hasAPIKey
            ),
            apiKeyVerifier: verifier,
            userDefaults: defaults,
            openClawTester: ReplayingOpenClawTester(),
            diagnostics: log,
            applicationLocationProvider: { location },
            microphoneAuthorizationProvider: microphone,
            audioEngineFactory: { SilentAudioEngine() },
            openURL: { _ in },
            moveApplication: moveApplication,
            quitApplication: {},
            activationPolicyProvider: { .accessory },
            applyActivationPolicy: { _ in }
        )
    }

    private func perform(
        title: String,
        in controller: OnboardingWizardController,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let buttons = allViews(
            ofType: NSButton.self,
            in: controller.window?.contentView
        )
        guard let button = buttons.first(where: {
            $0.title == title
        }), let action = button.action else {
            XCTFail(
                "No \"\(title)\" button in \(buttons.map(\.title))",
                file: file,
                line: line
            )
            return
        }
        _ = button.target?.perform(action, with: button)
    }

    private func firstView<V: NSView>(
        ofType type: V.Type,
        in view: NSView?
    ) -> V? {
        allViews(ofType: type, in: view).first
    }

    private func allViews<V: NSView>(
        ofType type: V.Type,
        in view: NSView?
    ) -> [V] {
        guard let view else { return [] }
        return view.subviews.flatMap { subview -> [V] in
            var found: [V] = []
            if let match = subview as? V {
                found.append(match)
            }
            found.append(
                contentsOf: allViews(ofType: type, in: subview)
            )
            return found
        }
    }
}

final class RecordingOnboardingDiagnostics:
    OnboardingDiagnosticsLogging {
    private(set) var lines: [String] = []

    var text: String {
        lines.joined(separator: "\n")
    }

    func lines(ofKind kind: String) -> [String] {
        lines.filter { $0.hasPrefix("\(kind): ") }
    }

    func record(
        _ event: OnboardingLogEvent,
        timestamp: Date
    ) {
        lines.append("\(event.kind): \(event.text)")
    }
}

private final class StubAPIKeyVerifier: APIKeyVerifying {
    var result: Result<Void, APIKeyVerificationError>
    private(set) var verifiedKeys: [String] = []

    init(result: Result<Void, APIKeyVerificationError>) {
        self.result = result
    }

    func verify(
        apiKey: String,
        completion: @escaping (
            Result<Void, APIKeyVerificationError>
        ) -> Void
    ) {
        verifiedKeys.append(apiKey)
        completion(result)
    }
}

private final class StubCredentialStore: VoiceCredentialStoring {
    private let hasAPIKeyValue: Bool

    init(hasAPIKey: Bool) {
        hasAPIKeyValue = hasAPIKey
    }

    func hasAPIKey(for profile: VoiceProfile) -> Bool {
        hasAPIKeyValue
    }

    func apiKey(for profile: VoiceProfile) -> String? {
        nil
    }

    func setAPIKey(
        _ apiKey: String,
        for profile: VoiceProfile
    ) throws {}

    func deleteAPIKey(for profile: VoiceProfile) throws {}

    func authorizationToken(
        forMCPServer id: UUID
    ) -> String? {
        nil
    }

    func setAuthorizationToken(
        _ token: String,
        forMCPServer id: UUID
    ) throws {}

    func deleteAuthorizationToken(
        forMCPServer id: UUID
    ) throws {}
}

private final class RejectingHotKeyDelegate:
    OnboardingWizardControllerDelegate {
    var profiles: [VoiceProfile]
    var accepts = false

    init(profiles: [VoiceProfile]) {
        self.profiles = profiles
    }

    func onboardingController(
        _ controller: OnboardingWizardController,
        didRecordHotKey hotKey: HotKeyConfiguration,
        for profile: VoiceProfile
    ) -> Bool {
        accepts
    }

    func onboardingController(
        _ controller: OnboardingWizardController,
        isRecordingHotKey: Bool
    ) {}
}

private final class ReplayingOpenClawTester:
    OpenClawConnectionTesting {
    private var completions:
        [(OpenClawConnectionOutcome) -> Void] = []
    private(set) var testCount = 0

    @discardableResult
    func testConnection(
        endpointURL: String,
        completion: @escaping (
            OpenClawConnectionOutcome
        ) -> Void
    ) -> OpenClawConnectionTestCancellation {
        testCount += 1
        completions.append(completion)
        return NoopConnectionTestCancellation()
    }

    func completeNext(_ outcome: OpenClawConnectionOutcome) {
        completions.removeFirst()(outcome)
    }
}

private final class NoopConnectionTestCancellation:
    OpenClawConnectionTestCancellation {
    func cancel() {}
}

private final class ImmediateRetryScheduler {
    private var actions: [() -> Void] = []

    func schedule(
        after delay: TimeInterval,
        action: @escaping () -> Void
    ) -> OnboardingRetryCancellation {
        actions.append(action)
        return NoopRetryCancellation()
    }

    func fireNext() {
        actions.removeFirst()()
    }
}

private final class NoopRetryCancellation:
    OnboardingRetryCancellation {
    func cancel() {}
}

/// The hot-key step starts a microphone preview; tests must never open the
/// real input device.
private final class SilentAudioEngine: RealtimeAudioEngineProtocol {
    func requestMicrophoneAccess(
        _ completion: @escaping (Bool) -> Void
    ) {
        completion(true)
    }

    func start(
        inputHandler: @escaping (Data) -> Void,
        activityHandler: @escaping (
            RealtimeAudioInputActivity
        ) -> Void
    ) throws {}

    func stop() {}

    func stopPlayback() {}

    func playPCM16(_ data: Data) {}
}
