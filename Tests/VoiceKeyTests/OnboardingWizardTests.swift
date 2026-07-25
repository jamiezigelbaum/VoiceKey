@testable import VoiceKey
import AppKit
import Foundation
import XCTest

final class OnboardingFlowPolicyTests: XCTestCase {
    func testTranslocationIsBlockingAndCannotContinueAnyway() {
        let facts = groundTruth(
            location: .translocated,
            hasAPIKey: false,
            microphone: .notDetermined,
            hasHotKey: false
        )

        XCTAssertEqual(
            OnboardingFlowPolicy.initialStep(
                groundTruth: facts
            ),
            .location
        )
        XCTAssertEqual(
            OnboardingFlowPolicy.reentryStep(
                groundTruth: facts
            ),
            .location
        )
        XCTAssertFalse(
            OnboardingFlowPolicy.canSkip(
                .location,
                groundTruth: facts
            )
        )
    }

    func testOutsideApplicationsOffersContinueAnywayButInstalledDoesNotGate() {
        let outside = groundTruth(
            location: .outsideApplications,
            hasAPIKey: false,
            microphone: .notDetermined,
            hasHotKey: false
        )
        let installed = groundTruth(
            location: .applications,
            hasAPIKey: false,
            microphone: .notDetermined,
            hasHotKey: false
        )

        XCTAssertTrue(
            OnboardingFlowPolicy.canSkip(
                .location,
                groundTruth: outside
            )
        )
        XCTAssertEqual(
            OnboardingFlowPolicy.initialStep(
                groundTruth: installed
            ),
            .welcome
        )
        XCTAssertEqual(
            OnboardingFlowPolicy.reentryStep(
                groundTruth: installed
            ),
            .apiKey
        )
    }

    func testReentryChoosesFirstIncompleteLiveFact() {
        XCTAssertEqual(
            OnboardingFlowPolicy.reentryStep(
                groundTruth: groundTruth(
                    hasAPIKey: false,
                    microphone: .authorized,
                    hasHotKey: true
                )
            ),
            .apiKey
        )
        XCTAssertEqual(
            OnboardingFlowPolicy.reentryStep(
                groundTruth: groundTruth(
                    hasAPIKey: true,
                    microphone: .denied,
                    hasHotKey: true
                )
            ),
            .microphone
        )
        XCTAssertEqual(
            OnboardingFlowPolicy.reentryStep(
                groundTruth: groundTruth(
                    hasAPIKey: true,
                    microphone: .authorized,
                    hasHotKey: false
                )
            ),
            .hotKey
        )
        XCTAssertEqual(
            OnboardingFlowPolicy.reentryStep(
                groundTruth: groundTruth(
                    hasAPIKey: true,
                    hasOpenClawConnection: true,
                    microphone: .authorized,
                    hasHotKey: true
                )
            ),
            .done
        )
    }

    func testManualReentryOpensThePickerOnceEverythingSelectedIsComplete() {
        let complete = groundTruth(
            hasAPIKey: true,
            hasOpenClawConnection: true,
            microphone: .authorized,
            hasHotKey: true
        )

        XCTAssertEqual(
            OnboardingFlowPolicy.reentryStep(
                groundTruth: complete
            ),
            .done,
            "Entry the app makes on the owner’s behalf is unchanged."
        )
        let resolved = OnboardingFlowPolicy
            .manualReentryStepWithReason(
                groundTruth: complete
            )
        XCTAssertEqual(
            resolved.step,
            .services,
            "Done sits after the picker, so opening there is a dead end for adding a service."
        )
        XCTAssertEqual(resolved.reason, .addAnotherService)
    }

    func testManualReentryStillResumesWhereUnfinishedSetupStopped() {
        let expected: [(OnboardingGroundTruth, OnboardingStep, OnboardingStepReason)] = [
            (
                groundTruth(
                    location: .translocated,
                    hasAPIKey: true,
                    microphone: .authorized,
                    hasHotKey: true
                ),
                .location,
                .appNotInApplications
            ),
            (
                groundTruth(
                    services: [],
                    hasAPIKey: true,
                    microphone: .authorized,
                    hasHotKey: true
                ),
                .services,
                .noServicesSelected
            ),
            (
                groundTruth(
                    hasAPIKey: false,
                    microphone: .authorized,
                    hasHotKey: true
                ),
                .apiKey,
                .openAIKeyMissing
            ),
            (
                groundTruth(
                    services: [.openClaw],
                    hasAPIKey: true,
                    hasOpenClawConnection: false,
                    microphone: .authorized,
                    hasHotKey: true
                ),
                .openClawConnect,
                .openClawNotConnected
            ),
            (
                groundTruth(
                    hasAPIKey: true,
                    microphone: .denied,
                    hasHotKey: true
                ),
                .microphone,
                .microphoneNotAuthorized
            ),
            (
                groundTruth(
                    hasAPIKey: true,
                    microphone: .authorized,
                    hasHotKey: false
                ),
                .hotKey,
                .hotKeysMissing
            )
        ]

        for (facts, step, reason) in expected {
            let resolved = OnboardingFlowPolicy
                .manualReentryStepWithReason(groundTruth: facts)
            XCTAssertEqual(resolved.step, step)
            XCTAssertEqual(resolved.reason, reason)
            XCTAssertEqual(
                OnboardingFlowPolicy.reentryStep(
                    groundTruth: facts
                ),
                step,
                "Unfinished setup resumes identically however the wizard was opened."
            )
        }
    }

    func testEveryNonAuthorizedMicrophoneStateRemainsIncomplete() {
        for state in [
            MicrophoneAuthorizationState.notDetermined,
            .denied,
            .restricted
        ] {
            XCTAssertEqual(
                OnboardingFlowPolicy.reentryStep(
                    groundTruth: groundTruth(
                        hasAPIKey: true,
                        hasOpenClawConnection: true,
                        microphone: state,
                        hasHotKey: true
                    )
                ),
                .microphone
            )
        }
        XCTAssertEqual(
            OnboardingFlowPolicy.reentryStep(
                groundTruth: groundTruth(
                    hasAPIKey: true,
                    hasOpenClawConnection: true,
                    microphone: .authorized,
                    hasHotKey: true
                )
            ),
            .done
        )
    }

    func testOptionalCredentialDoesNotCreateAnIncompleteKeyStep() {
        let facts = OnboardingGroundTruth(
            applicationLocation: .applications,
            selectedServices: [.openClaw],
            hasOpenAIAPIKey: false,
            hasOpenClawConnection: true,
            microphoneAuthorization: .authorized,
            hasHotKeysForSelectedServices: true
        )

        XCTAssertEqual(
            OnboardingFlowPolicy.reentryStep(
                groundTruth: facts
            ),
            .done
        )
    }

    func testSkipSemanticsAdvanceWithoutPretendingLiveFactChanged() {
        let facts = groundTruth(
            hasAPIKey: false,
            microphone: .denied,
            hasHotKey: false
        )
        var handled: Set<OnboardingStep> = [.apiKey]

        XCTAssertTrue(
            OnboardingFlowPolicy.canSkip(
                .apiKey,
                groundTruth: facts
            )
        )
        XCTAssertEqual(
            OnboardingFlowPolicy.nextStep(
                after: .apiKey,
                groundTruth: facts,
                handledSteps: handled
            ),
            .microphone
        )

        handled.insert(.microphone)
        XCTAssertEqual(
            OnboardingFlowPolicy.nextStep(
                after: .microphone,
                groundTruth: facts,
                handledSteps: handled
            ),
            .hotKey
        )

        handled.insert(.hotKey)
        XCTAssertEqual(
            OnboardingFlowPolicy.nextStep(
                after: .hotKey,
                groundTruth: facts,
                handledSteps: handled
            ),
            .done
        )
        XCTAssertEqual(
            OnboardingFlowPolicy.reentryStep(
                groundTruth: facts
            ),
            .apiKey,
            "Re-entry must use live facts, not the prior window’s skips."
        )
    }

    func testWelcomeAlwaysFlowsThroughServicePickerBeforeConditionalSteps() {
        let facts = groundTruth(
            hasAPIKey: true,
            microphone: .authorized,
            hasHotKey: true
        )

        XCTAssertEqual(
            OnboardingFlowPolicy.nextStep(
                after: .welcome,
                groundTruth: facts,
                handledSteps: [.welcome]
            ),
            .services
        )
    }

    func testConditionalServiceStepsFollowSelection() {
        let bothMissing = groundTruth(
            services: [.openAI, .openClaw],
            hasAPIKey: false,
            hasOpenClawConnection: false,
            microphone: .authorized,
            hasHotKey: true
        )
        XCTAssertEqual(
            OnboardingFlowPolicy.reentryStep(
                groundTruth: bothMissing
            ),
            .apiKey
        )
        XCTAssertEqual(
            OnboardingFlowPolicy.nextStep(
                after: .apiKey,
                groundTruth: bothMissing,
                handledSteps: [.apiKey]
            ),
            .openClawConnect
        )

        let openClawOnly = groundTruth(
            services: [.openClaw],
            hasAPIKey: false,
            hasOpenClawConnection: false,
            microphone: .authorized,
            hasHotKey: true
        )
        XCTAssertEqual(
            OnboardingFlowPolicy.reentryStep(
                groundTruth: openClawOnly
            ),
            .openClawConnect
        )

        let none = groundTruth(
            services: [],
            hasAPIKey: false,
            microphone: .authorized,
            hasHotKey: true
        )
        XCTAssertEqual(
            OnboardingFlowPolicy.reentryStep(
                groundTruth: none
            ),
            .services
        )
    }

    func testFreshBothServicesWalksEveryRequiredStepInOrder() {
        let facts = groundTruth(
            services: [.openAI, .openClaw],
            hasAPIKey: false,
            hasOpenClawConnection: false,
            microphone: .notDetermined,
            hasHotKey: false
        )
        var handled: Set<OnboardingStep> = [.welcome]
        var step = OnboardingFlowPolicy.nextStep(
            after: .welcome,
            groundTruth: facts,
            handledSteps: handled
        )
        XCTAssertEqual(step, .services)

        let expected: [OnboardingStep] = [
            .apiKey,
            .openClawConnect,
            .microphone,
            .hotKey,
            .done
        ]
        for next in expected {
            handled.insert(step)
            step = OnboardingFlowPolicy.nextStep(
                after: step,
                groundTruth: facts,
                handledSteps: handled
            )
            XCTAssertEqual(step, next)
        }
    }

    func testLocationDetectionUsesExecutableTranslocationBeforeBundlePath() {
        XCTAssertEqual(
            ApplicationLocationState.detect(
                executableURL: URL(
                    fileURLWithPath:
                        "/private/var/folders/AppTranslocation/VoiceKey"
                ),
                bundleURL: URL(
                    fileURLWithPath:
                        "/Applications/VoiceKey.app"
                )
            ),
            .translocated
        )
        XCTAssertEqual(
            ApplicationLocationState.detect(
                executableURL: URL(
                    fileURLWithPath:
                        "/Applications/VoiceKey.app/Contents/MacOS/VoiceKey"
                ),
                bundleURL: URL(
                    fileURLWithPath:
                        "/Applications/VoiceKey.app"
                )
            ),
            .applications
        )
    }

    func testOwnerCredentialCopyAndMaskedValueAreExact() {
        XCTAssertEqual(
            OnboardingWizardController.keyPlaceholder,
            "Paste key here"
        )
        XCTAssertEqual(
            OnboardingWizardController.keyCaption,
            "API keys are stored in Apple keychain and shared across channels of this provider."
        )
        XCTAssertEqual(
            OnboardingWizardController.maskedKey,
            "••••••••••••"
        )
        XCTAssertEqual(
            OnboardingWizardController
                .openClawTokenPlaceholder,
            "Paste token here"
        )
        XCTAssertFalse(
            OnboardingWizardController.maskedKey.contains(
                "sk-"
            )
        )
    }

    private func groundTruth(
        location: ApplicationLocationState = .applications,
        services: Set<OnboardingService> = [.openAI],
        hasAPIKey: Bool,
        hasOpenClawConnection: Bool = false,
        microphone: MicrophoneAuthorizationState,
        hasHotKey: Bool
    ) -> OnboardingGroundTruth {
        OnboardingGroundTruth(
            applicationLocation: location,
            selectedServices: services,
            hasOpenAIAPIKey: hasAPIKey,
            hasOpenClawConnection: hasOpenClawConnection,
            microphoneAuthorization: microphone,
            hasHotKeysForSelectedServices: hasHotKey
        )
    }
}

final class OnboardingWizardControllerServiceTests:
    XCTestCase {
    func testReentryDropsDeletedServiceAndDoesNotRecreateChannel() {
        let defaults = makeDefaults()
        OnboardingServicePreferences.saveSelectedServices(
            [.openAI, .openClaw],
            defaults: defaults
        )
        OnboardingServicePreferences.setHasOpenClawConnection(
            true,
            defaults: defaults
        )
        let delegate = OnboardingChannelRecordingDelegate(
            profiles: [VoiceProfile.defaultOpenAI()]
        )
        let controller = OnboardingWizardController(
            profileProvider: { delegate.profiles },
            credentialStore: OnboardingCredentialStore(
                hasAPIKey: true
            ),
            userDefaults: defaults,
            applicationLocationProvider: { .applications },
            microphoneAuthorizationProvider: { .authorized }
        )
        controller.delegate = delegate
        defer { controller.close() }

        controller.showReentrant()

        XCTAssertEqual(controller.currentStepSnapshot, .done)
        XCTAssertEqual(
            OnboardingServicePreferences.selectedServices(
                defaults: defaults
            ),
            [.openAI]
        )
        XCTAssertTrue(delegate.ensureRequests.isEmpty)
        XCTAssertFalse(delegate.profiles.contains {
            $0.providerID == .openClaw
        })
    }

    func testFreshServiceConfirmationStillCreatesSelectedChannels() {
        let defaults = makeDefaults()
        let delegate = OnboardingChannelRecordingDelegate(
            profiles: [VoiceProfile.defaultOpenAI()]
        )
        let controller = OnboardingWizardController(
            profileProvider: { delegate.profiles },
            credentialStore: OnboardingCredentialStore(),
            userDefaults: defaults,
            applicationLocationProvider: { .applications },
            microphoneAuthorizationProvider: { .authorized }
        )
        controller.delegate = delegate
        defer { controller.close() }

        controller.confirmServices([.openAI, .openClaw])

        XCTAssertEqual(
            delegate.ensureRequests,
            [[.openAI, .openClaw]]
        )
        XCTAssertEqual(
            delegate.profiles.filter {
                $0.providerID == .openAIRealtime
            }.count,
            1
        )
        XCTAssertEqual(
            delegate.profiles.filter {
                $0.providerID == .openClaw
            }.count,
            1
        )
        XCTAssertEqual(
            OnboardingServicePreferences.selectedServices(
                defaults: defaults
            ),
            [.openAI, .openClaw]
        )
    }

    func testFinishedSetupReopenedFromTheMenuLandsOnServicesWithWhatTheOwnerHasTicked() {
        let defaults = makeDefaults()
        OnboardingServicePreferences.saveSelectedServices(
            [.openAI],
            defaults: defaults
        )
        let delegate = OnboardingChannelRecordingDelegate(
            profiles: [VoiceProfile.defaultOpenAI()]
        )
        let controller = makeController(
            defaults: defaults,
            delegate: delegate,
            hasAPIKey: true
        )
        defer { controller.close() }

        controller.showManualReentry()

        XCTAssertEqual(
            controller.currentStepSnapshot,
            .services,
            "The menu item is the only way back in, so a finished setup has to reach the picker."
        )
        let checkboxes = onboardingButtons(
            in: controller.window?.contentView
        )
        XCTAssertEqual(
            checkboxes.first { $0.title == "OpenAI" }?.state,
            .on
        )
        XCTAssertEqual(
            checkboxes.first { $0.title == "OpenClaw" }?.state,
            .off
        )
        XCTAssertTrue(
            delegate.ensureRequests.isEmpty,
            "Opening the picker must not touch channels."
        )
    }

    func testUnfinishedSetupReopenedFromTheMenuStillResumesWhereItStopped() {
        let defaults = makeDefaults()
        OnboardingServicePreferences.saveSelectedServices(
            [.openAI],
            defaults: defaults
        )
        let delegate = OnboardingChannelRecordingDelegate(
            profiles: [VoiceProfile.defaultOpenAI()]
        )
        let controller = makeController(
            defaults: defaults,
            delegate: delegate,
            hasAPIKey: false
        )
        defer { controller.close() }

        controller.showManualReentry()

        XCTAssertEqual(
            controller.currentStepSnapshot,
            .apiKey
        )
    }

    func testAddingASecondServiceWalksOnlyThatServicesRemainingSteps() {
        let defaults = makeDefaults()
        OnboardingServicePreferences.saveSelectedServices(
            [.openAI],
            defaults: defaults
        )
        let delegate = OnboardingChannelRecordingDelegate(
            profiles: [VoiceProfile.defaultOpenAI()]
        )
        delegate.acceptsHotKeys = true
        let tester = FakeOpenClawConnectionTester()
        let controller = makeController(
            defaults: defaults,
            delegate: delegate,
            hasAPIKey: true,
            openClawTester: tester
        )
        defer { controller.close() }
        controller.showManualReentry()

        tick(service: "OpenClaw", on: true, in: controller)
        performButton(title: "Continue", in: controller)

        XCTAssertEqual(
            controller.currentStepSnapshot,
            .openClawConnect,
            "The OpenAI key step was already satisfied and must not be walked again."
        )
        XCTAssertEqual(
            delegate.ensureRequests.first,
            [.openAI, .openClaw]
        )
        XCTAssertEqual(
            delegate.profiles.filter {
                $0.providerID == .openClaw
            }.count,
            1
        )
        XCTAssertEqual(
            delegate.profiles.filter {
                $0.providerID == .openAIRealtime
            }.count,
            1,
            "Ensuring stays append-only: the existing channel is untouched."
        )

        // The connect step starts on the next main-queue turn.
        RunLoop.current.run(
            until: Date().addingTimeInterval(0.05)
        )
        XCTAssertEqual(tester.testCount, 1)
        tester.completeNext(
            .ok(serverVersion: "2026.7.1-2", scopes: [])
        )
        performButton(title: "Continue", in: controller)

        XCTAssertEqual(controller.currentStepSnapshot, .hotKey)
        guard let openClaw = delegate.profiles.first(where: {
            $0.providerID == .openClaw
        }) else {
            return XCTFail("The OpenClaw channel was never created.")
        }
        XCTAssertEqual(
            firstHotKeyRecorder(in: controller)?.profileID,
            openClaw.id,
            "Only the new channel still needs a shortcut."
        )

        firstHotKeyRecorder(in: controller)?.onHotKeyRecorded?(
            openClaw.id,
            .secondaryTestShortcut
        )

        XCTAssertEqual(controller.currentStepSnapshot, .done)
        XCTAssertEqual(
            delegate.profiles.first {
                $0.providerID == .openAIRealtime
            }?.hotKey,
            .defaultVoiceToggle,
            "The shortcut the owner already had is left alone."
        )
    }

    func testUncheckingAServiceNeverDeletesItsChannel() {
        let defaults = makeDefaults()
        OnboardingServicePreferences.saveSelectedServices(
            [.openAI, .openClaw],
            defaults: defaults
        )
        OnboardingServicePreferences.setHasOpenClawConnection(
            true,
            defaults: defaults
        )
        let openClaw = VoiceProfile(
            name: "OpenClaw",
            providerID: .openClaw,
            hotKey: .secondaryTestShortcut,
            model: "",
            voice: ""
        )
        let delegate = OnboardingChannelRecordingDelegate(
            profiles: [VoiceProfile.defaultOpenAI(), openClaw]
        )
        let controller = makeController(
            defaults: defaults,
            delegate: delegate,
            hasAPIKey: true
        )
        defer { controller.close() }
        controller.showManualReentry()
        XCTAssertEqual(
            controller.currentStepSnapshot,
            .services
        )

        tick(service: "OpenClaw", on: false, in: controller)
        performButton(title: "Continue", in: controller)

        XCTAssertEqual(controller.currentStepSnapshot, .done)
        XCTAssertEqual(
            delegate.profiles.filter {
                $0.providerID == .openClaw
            },
            [openClaw],
            "Deleting a channel stays a deliberate Settings action."
        )
        XCTAssertFalse(
            delegate.ensureRequests.contains {
                $0.contains(.openClaw)
            }
        )
        XCTAssertEqual(
            OnboardingServicePreferences.selectedServices(
                defaults: defaults
            ),
            [.openAI]
        )
    }

    private func makeController(
        defaults: UserDefaults,
        delegate: OnboardingChannelRecordingDelegate,
        hasAPIKey: Bool,
        openClawTester: OpenClawConnectionTesting =
            FakeOpenClawConnectionTester()
    ) -> OnboardingWizardController {
        let controller = OnboardingWizardController(
            profileProvider: { delegate.profiles },
            credentialStore: OnboardingCredentialStore(
                hasAPIKey: hasAPIKey,
                // Keeps the gateway-token lookup off this Mac's own
                // ~/.openclaw secrets, so the connect step is deterministic.
                apiKey: "test-gateway-token"
            ),
            userDefaults: defaults,
            openClawTester: openClawTester,
            applicationLocationProvider: { .applications },
            microphoneAuthorizationProvider: { .authorized },
            audioEngineFactory: { SilentOnboardingAudioEngine() },
            activationPolicyProvider: { .accessory },
            applyActivationPolicy: { _ in }
        )
        controller.delegate = delegate
        return controller
    }

    private func tick(
        service title: String,
        on: Bool,
        in controller: OnboardingWizardController,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let checkbox = onboardingButtons(
            in: controller.window?.contentView
        ).first(where: { $0.title == title }) else {
            XCTFail(
                "No \"\(title)\" card on screen.",
                file: file,
                line: line
            )
            return
        }
        checkbox.state = on ? .on : .off
        _ = checkbox.target?.perform(
            checkbox.action,
            with: checkbox
        )
    }

    private func performButton(
        title: String,
        in controller: OnboardingWizardController,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let buttons = onboardingButtons(
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

    private func firstHotKeyRecorder(
        in controller: OnboardingWizardController
    ) -> HotKeyRecorderView? {
        func search(_ view: NSView?) -> HotKeyRecorderView? {
            guard let view else { return nil }
            for subview in view.subviews {
                if let match = subview as? HotKeyRecorderView {
                    return match
                }
                if let match = search(subview) {
                    return match
                }
            }
            return nil
        }
        return search(controller.window?.contentView)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName =
            "OnboardingWizardControllerServiceTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }
}

final class OnboardingWizardWindowTests: XCTestCase {
    func testServicesStepRendersBothCardsAndItsFooter() {
        let recorder = ActivationPolicyRecorder()
        let controller = makeController(policy: recorder)
        defer { controller.close() }

        controller.showReentrant()

        XCTAssertEqual(
            controller.currentStepSnapshot,
            .services
        )
        let titles = buttonTitles(
            in: controller.window?.contentView
        )
        XCTAssertTrue(titles.contains("OpenAI"), "\(titles)")
        XCTAssertTrue(titles.contains("OpenClaw"), "\(titles)")
        XCTAssertTrue(titles.contains("Continue"), "\(titles)")
        XCTAssertTrue(
            titles.contains("Set up later"),
            "\(titles)"
        )
    }

    func testServicesStepCheckboxTogglesSelectionAndEnablesContinue() {
        let defaults = makeDefaults()
        let recorder = ActivationPolicyRecorder()
        let controller = makeController(
            policy: recorder,
            defaults: defaults
        )
        defer { controller.close() }
        controller.showReentrant()

        guard let checkbox = buttons(
            in: controller.window?.contentView
        ).first(where: { $0.title == "OpenAI" }) else {
            return XCTFail("The OpenAI card never rendered.")
        }
        XCTAssertEqual(
            buttons(in: controller.window?.contentView)
                .first { $0.title == "Continue" }?.isEnabled,
            false
        )

        checkbox.state = .on
        _ = checkbox.target?.perform(
            checkbox.action,
            with: checkbox
        )

        XCTAssertEqual(
            OnboardingServicePreferences.selectedServices(
                defaults: defaults
            ),
            [.openAI]
        )
        XCTAssertEqual(
            buttons(in: controller.window?.contentView)
                .first { $0.title == "Continue" }?.isEnabled,
            true
        )
    }

    func testWindowHeightTracksTheRenderedStepInsteadOfAFixedFrame() {
        let recorder = ActivationPolicyRecorder()
        let controller = makeController(policy: recorder)
        defer { controller.close() }

        controller.showReentrant()

        guard let window = controller.window,
              let contentView = window.contentView else {
            return XCTFail("The wizard has no window.")
        }
        XCTAssertEqual(
            window.frame.width,
            OnboardingWindowMetrics.width,
            accuracy: 0.5
        )
        XCTAssertEqual(
            contentView.frame.height,
            max(
                contentView.fittingSize.height,
                OnboardingWindowMetrics.minimumContentHeight
            ),
            accuracy: 1
        )
        XCTAssertLessThan(contentView.frame.height, 700)
    }

    func testWizardBecomesRegularWhileOpenAndHandsThePolicyBack() {
        let recorder = ActivationPolicyRecorder()
        let controller = makeController(policy: recorder)

        controller.showReentrant()
        XCTAssertEqual(recorder.applied, [.regular])

        // Re-entry from the menu bar must not stack a second borrow.
        controller.showReentrant()
        XCTAssertEqual(recorder.applied, [.regular])

        controller.close()
        XCTAssertEqual(
            recorder.applied,
            [.regular, .accessory]
        )
        XCTAssertEqual(recorder.current, .accessory)

        controller.close()
        XCTAssertEqual(
            recorder.applied,
            [.regular, .accessory]
        )
    }

    private func makeController(
        policy recorder: ActivationPolicyRecorder,
        defaults: UserDefaults? = nil
    ) -> OnboardingWizardController {
        let defaults = defaults ?? makeDefaults()
        OnboardingServicePreferences.saveSelectedServices(
            [],
            defaults: defaults
        )
        return OnboardingWizardController(
            profileProvider: { [] },
            credentialStore: OnboardingCredentialStore(),
            userDefaults: defaults,
            applicationLocationProvider: { .applications },
            microphoneAuthorizationProvider: { .authorized },
            activationPolicyProvider: { recorder.current },
            applyActivationPolicy: { recorder.apply($0) }
        )
    }

    private func buttons(in view: NSView?) -> [NSButton] {
        guard let view else { return [] }
        return view.subviews.flatMap { subview -> [NSButton] in
            var found: [NSButton] = []
            if let button = subview as? NSButton {
                found.append(button)
            }
            found.append(contentsOf: buttons(in: subview))
            return found
        }
    }

    private func buttonTitles(in view: NSView?) -> [String] {
        buttons(in: view).map(\.title)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "OnboardingWizardWindowTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }
}

final class OnboardingWindowMetricsTests: XCTestCase {
    func testHeightFollowsContentUntilTheScreenRunsOut() {
        XCTAssertEqual(
            OnboardingWindowMetrics.contentHeight(
                fitting: 342,
                visibleFrameHeight: 900,
                windowChromeHeight: 28
            ),
            342
        )
        XCTAssertEqual(
            OnboardingWindowMetrics.contentHeight(
                fitting: 1_400,
                visibleFrameHeight: 900,
                windowChromeHeight: 28
            ),
            900 - 120 - 28
        )
        XCTAssertEqual(
            OnboardingWindowMetrics.contentHeight(
                fitting: 40,
                visibleFrameHeight: 900,
                windowChromeHeight: 28
            ),
            OnboardingWindowMetrics.minimumContentHeight
        )
    }

    func testUnknownScreenNeverClampsTheStep() {
        XCTAssertEqual(
            OnboardingWindowMetrics.contentHeight(
                fitting: 640,
                visibleFrameHeight: 0,
                windowChromeHeight: 28
            ),
            640
        )
    }

    func testResizingKeepsTheWindowCentredAndOnScreen() {
        let visible = NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let current = NSRect(
            x: 410,
            y: 250,
            width: 620,
            height: 400
        )

        let grown = OnboardingWindowMetrics.centeredFrame(
            currentFrame: current,
            targetSize: NSSize(width: 620, height: 600),
            visibleFrame: visible
        )
        XCTAssertEqual(grown.midX, current.midX, accuracy: 0.5)
        XCTAssertEqual(grown.midY, current.midY, accuracy: 0.5)

        let pushedBack = OnboardingWindowMetrics.centeredFrame(
            currentFrame: NSRect(
                x: 410,
                y: 820,
                width: 620,
                height: 200
            ),
            targetSize: NSSize(width: 620, height: 700),
            visibleFrame: visible
        )
        XCTAssertGreaterThanOrEqual(
            pushedBack.minY,
            visible.minY
        )
        XCTAssertLessThanOrEqual(
            pushedBack.maxY,
            visible.maxY
        )
    }
}

final class OnboardingActivationPolicySwitchTests: XCTestCase {
    func testBorrowsOnceAndReturnsTheOriginalPolicy() {
        var policySwitch = OnboardingActivationPolicySwitch()

        XCTAssertEqual(
            policySwitch.borrow(from: .accessory),
            .regular
        )
        XCTAssertNil(policySwitch.borrow(from: .accessory))
        XCTAssertEqual(policySwitch.release(), .accessory)
        XCTAssertNil(policySwitch.release())
    }

    func testARegularAppIsLeftAlone() {
        var policySwitch = OnboardingActivationPolicySwitch()

        XCTAssertNil(policySwitch.borrow(from: .regular))
        XCTAssertNil(policySwitch.release())
    }
}

private final class ActivationPolicyRecorder {
    private(set) var current: NSApplication.ActivationPolicy =
        .accessory
    private(set) var applied:
        [NSApplication.ActivationPolicy] = []

    func apply(_ policy: NSApplication.ActivationPolicy) {
        current = policy
        applied.append(policy)
    }
}

final class OnboardingServicePreferencesTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "OnboardingServicePreferencesTests-\(UUID())"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testSelectionRoundTripsIncludingEmptySelection() {
        XCTAssertNil(
            OnboardingServicePreferences.selectedServices(
                defaults: defaults
            )
        )

        OnboardingServicePreferences.saveSelectedServices(
            [.openAI, .openClaw],
            defaults: defaults
        )
        XCTAssertEqual(
            OnboardingServicePreferences.selectedServices(
                defaults: defaults
            ),
            [.openAI, .openClaw]
        )

        OnboardingServicePreferences.saveSelectedServices(
            [],
            defaults: defaults
        )
        XCTAssertEqual(
            OnboardingServicePreferences.selectedServices(
                defaults: defaults
            ),
            []
        )
    }

    func testOpenClawConnectionFactRoundTrips() {
        XCTAssertFalse(
            OnboardingServicePreferences.hasOpenClawConnection(
                defaults: defaults
            )
        )
        OnboardingServicePreferences.setHasOpenClawConnection(
            true,
            defaults: defaults
        )
        XCTAssertTrue(
            OnboardingServicePreferences.hasOpenClawConnection(
                defaults: defaults
            )
        )
    }
}

final class OnboardingChannelEnsurerTests: XCTestCase {
    func testEnsuringBothServicesIsIdempotentAndPreservesUnselectedChannels() {
        let custom = VoiceProfile(
            name: "Custom",
            providerID: .custom,
            hotKey: nil,
            model: "model",
            voice: "voice"
        )
        let initial = [custom]
        let once = OnboardingChannelEnsurer.ensure(
            services: [.openAI, .openClaw],
            openClawEndpoint: "https://gateway.example.com",
            in: initial
        )
        let twice = OnboardingChannelEnsurer.ensure(
            services: [.openAI, .openClaw],
            openClawEndpoint: "https://gateway.example.com",
            in: once
        )

        XCTAssertEqual(once, twice)
        XCTAssertEqual(
            once.filter { $0.providerID == .openAIRealtime }.count,
            1
        )
        XCTAssertEqual(
            once.filter { $0.providerID == .openClaw }.count,
            1
        )
        XCTAssertTrue(once.contains { $0.id == custom.id })
        XCTAssertEqual(
            once.first { $0.providerID == .openClaw }?.endpointURL,
            "https://gateway.example.com"
        )
        XCTAssertEqual(
            once.first { $0.providerID == .openClaw }?.instructions,
            ""
        )
    }

    func testEnsuringOneServiceNeverDeletesAnother() {
        let openClaw = VoiceProfile(
            name: "OpenClaw",
            providerID: .openClaw,
            model: "",
            voice: ""
        )
        let ensured = OnboardingChannelEnsurer.ensure(
            services: [.openAI],
            openClawEndpoint: "",
            in: [openClaw]
        )

        XCTAssertTrue(ensured.contains { $0.id == openClaw.id })
        XCTAssertTrue(
            ensured.contains {
                $0.providerID == .openAIRealtime
            }
        )
    }
}

final class OnboardingHotKeyPolicyTests: XCTestCase {
    func testSequentiallyReturnsEachSelectedUnassignedChannel() {
        let openAI = VoiceProfile(
            name: "OpenAI",
            providerID: .openAIRealtime,
            model: "model",
            voice: "voice"
        )
        let openClaw = VoiceProfile(
            name: "OpenClaw",
            providerID: .openClaw,
            model: "",
            voice: ""
        )
        let unrelated = VoiceProfile(
            name: "Custom",
            providerID: .custom,
            model: "model",
            voice: "voice"
        )
        let profiles = [openAI, openClaw, unrelated]

        XCTAssertEqual(
            OnboardingHotKeyPolicy.nextProfile(
                in: profiles,
                selectedServices: [.openAI, .openClaw],
                handledProfileIDs: []
            )?.id,
            openAI.id
        )
        XCTAssertEqual(
            OnboardingHotKeyPolicy.nextProfile(
                in: profiles,
                selectedServices: [.openAI, .openClaw],
                handledProfileIDs: [openAI.id]
            )?.id,
            openClaw.id
        )
        XCTAssertNil(
            OnboardingHotKeyPolicy.nextProfile(
                in: profiles,
                selectedServices: [.openAI, .openClaw],
                handledProfileIDs: [openAI.id, openClaw.id]
            )
        )
    }

    func testGroundTruthRequiresAChannelAndHotKeyForEverySelection() {
        var openAI = VoiceProfile(
            name: "OpenAI",
            providerID: .openAIRealtime,
            model: "model",
            voice: "voice"
        )
        XCTAssertFalse(
            OnboardingHotKeyPolicy
                .hasHotKeysForEverySelectedChannel(
                    profiles: [openAI],
                    selectedServices: [.openAI, .openClaw]
                )
        )
        openAI.hotKey = .defaultVoiceToggle
        XCTAssertTrue(
            OnboardingHotKeyPolicy
                .hasHotKeysForEverySelectedChannel(
                    profiles: [openAI],
                    selectedServices: [.openAI]
                )
        )
    }
}

final class OpenClawConnectionWizardTests: XCTestCase {
    func testPairingRetryKeepsScreenAndAdoptsLatestRequestID() {
        let tester = FakeOpenClawConnectionTester()
        let scheduler = FakeOnboardingRetryScheduler()
        let wizard = OpenClawConnectionWizard(
            tester: tester,
            tokenProvider: { "gateway-token" },
            retryScheduler: scheduler.schedule
        )

        wizard.begin(endpointURL: "")
        XCTAssertEqual(wizard.state, .testing)
        tester.completeNext(.pairingRequired(
            reason: "metadata-upgrade",
            requestID: "expired-request",
            remediationHint: "Approve it."
        ))
        XCTAssertEqual(
            wizard.state,
            .pairingWait(
                reason: "metadata-upgrade",
                requestID: "expired-request",
                remediationHint: "Approve it."
            )
        )

        scheduler.fireNext()
        XCTAssertEqual(
            wizard.state,
            .pairingWait(
                reason: "metadata-upgrade",
                requestID: "expired-request",
                remediationHint: "Approve it."
            ),
            "The approval command remains visible while the retry is in flight."
        )
        tester.completeNext(.pairingRequired(
            reason: "metadata-upgrade",
            requestID: "latest-request",
            remediationHint: "Approve the latest request."
        ))
        XCTAssertEqual(
            wizard.state,
            .pairingWait(
                reason: "metadata-upgrade",
                requestID: "latest-request",
                remediationHint: "Approve the latest request."
            )
        )
    }

    func testLeavingPairingScreenCancelsRetryAndActiveTest() {
        let tester = FakeOpenClawConnectionTester()
        let scheduler = FakeOnboardingRetryScheduler()
        let wizard = OpenClawConnectionWizard(
            tester: tester,
            tokenProvider: { "gateway-token" },
            retryScheduler: scheduler.schedule
        )
        wizard.begin(endpointURL: "")
        tester.completeNext(.pairingRequired(
            reason: nil,
            requestID: "request-1",
            remediationHint: nil
        ))

        wizard.leave()
        scheduler.fireNext()

        XCTAssertEqual(tester.testCount, 1)
        XCTAssertTrue(scheduler.cancellations.allSatisfy(\.isCancelled))
    }

    func testMissingTokenAndSuccessMapToWizardStates() {
        let missingTester = FakeOpenClawConnectionTester()
        let missing = OpenClawConnectionWizard(
            tester: missingTester,
            tokenProvider: { nil }
        )
        missing.begin(endpointURL: "")
        XCTAssertEqual(
            missing.state,
            .needsToken(
                message: "No gateway token was found on this Mac."
            )
        )
        XCTAssertEqual(missingTester.testCount, 0)

        let tester = FakeOpenClawConnectionTester()
        let connected = OpenClawConnectionWizard(
            tester: tester,
            tokenProvider: { "token" }
        )
        connected.begin(endpointURL: "")
        tester.completeNext(.ok(
            serverVersion: "2026.7.1-2",
            scopes: ["operator.read"]
        ))
        XCTAssertEqual(
            connected.state,
            .success(serverVersion: "2026.7.1-2")
        )
    }

    func testDeviceTokenMismatchCopyRequiresRepairInsteadOfPromisingRefresh() {
        let tester = FakeOpenClawConnectionTester()
        let wizard = OpenClawConnectionWizard(
            tester: tester,
            tokenProvider: { "token" }
        )

        wizard.begin(endpointURL: "")
        tester.completeNext(.deviceTokenMismatch)

        XCTAssertEqual(
            wizard.state,
            .failed(
                message: "OpenClaw’s saved device approval is no longer valid. Re-pair this Mac in OpenClaw, then try again."
            )
        )
    }
}

final class APIKeyVerificationStateTests: XCTestCase {
    func testSuccessState() {
        var state = APIKeyVerificationState.idle
        state.begin()
        XCTAssertEqual(state, .verifying)
        state.finish(.success(()))
        XCTAssertEqual(state, .verified)
    }

    func testAuthAndNetworkFailureCopy() {
        var state = APIKeyVerificationState.verifying
        state.finish(.failure(.rejected))
        XCTAssertEqual(
            state,
            .failed(
                "That key wasn’t accepted. Check it and try again."
            )
        )

        state.begin()
        state.finish(.failure(.network))
        XCTAssertEqual(
            state,
            .failed(
                "Couldn’t reach OpenAI. Check your connection and try again."
            )
        )
    }
}

final class OpenAIAPIKeyVerifierTests: XCTestCase {
    override func tearDown() {
        StubOnboardingURLProtocol.handler = nil
        super.tearDown()
    }

    func testStubbedModelsEndpointSuccessTrimsAndAuthenticates() {
        let expectation = expectation(
            description: "verified"
        )
        let verifier = makeVerifier { request in
            XCTAssertEqual(
                request.url?.path,
                "/v1/models"
            )
            XCTAssertEqual(
                request.value(
                    forHTTPHeaderField: "Authorization"
                ),
                "Bearer test-key"
            )
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data()
            )
        }

        verifier.verify(apiKey: "  test-key\n") { result in
            if case let .failure(error) = result {
                XCTFail("Unexpected failure: \(error)")
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
    }

    func testStubbedModelsEndpointMapsAuthenticationFailure() {
        let expectation = expectation(
            description: "rejected"
        )
        let verifier = makeVerifier { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 401,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data()
            )
        }

        verifier.verify(apiKey: "bad-key") { result in
            if case let .failure(error) = result {
                XCTAssertEqual(error, .rejected)
            } else {
                XCTFail("Expected an authentication failure.")
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
    }

    func testStubbedModelsEndpointMapsNetworkFailure() {
        let expectation = expectation(
            description: "network failure"
        )
        let configuration =
            URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [
            StubOnboardingURLProtocol.self
        ]
        StubOnboardingURLProtocol.handler = { _ in
            throw URLError(.notConnectedToInternet)
        }
        let verifier = OpenAIAPIKeyVerifier(
            endpoint: URL(
                string:
                    "https://stub.voicekey.test/v1/models"
            )!,
            session: URLSession(
                configuration: configuration
            )
        )

        verifier.verify(apiKey: "test-key") { result in
            if case let .failure(error) = result {
                XCTAssertEqual(error, .network)
            } else {
                XCTFail("Expected a network failure.")
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
    }

    private func makeVerifier(
        handler: @escaping (
            URLRequest
        ) throws -> (HTTPURLResponse, Data)
    ) -> OpenAIAPIKeyVerifier {
        let configuration =
            URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [
            StubOnboardingURLProtocol.self
        ]
        StubOnboardingURLProtocol.handler = handler
        return OpenAIAPIKeyVerifier(
            endpoint: URL(
                string:
                    "https://stub.voicekey.test/v1/models"
            )!,
            session: URLSession(
                configuration: configuration
            )
        )
    }
}

private final class FakeOpenClawConnectionTester:
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
        return FakeOpenClawTestCancellation()
    }

    func completeNext(
        _ outcome: OpenClawConnectionOutcome
    ) {
        completions.removeFirst()(outcome)
    }
}

private final class FakeOpenClawTestCancellation:
    OpenClawConnectionTestCancellation {
    private(set) var isCancelled = false

    func cancel() {
        isCancelled = true
    }
}

private final class FakeOnboardingRetryScheduler {
    private(set) var cancellations:
        [FakeOnboardingRetryCancellation] = []
    private var actions: [() -> Void] = []

    func schedule(
        after delay: TimeInterval,
        action: @escaping () -> Void
    ) -> OnboardingRetryCancellation {
        XCTAssertEqual(delay, 4)
        let cancellation =
            FakeOnboardingRetryCancellation()
        cancellations.append(cancellation)
        actions.append {
            guard cancellation.isCancelled == false else {
                return
            }
            action()
        }
        return cancellation
    }

    func fireNext() {
        actions.removeFirst()()
    }
}

private final class FakeOnboardingRetryCancellation:
    OnboardingRetryCancellation {
    private(set) var isCancelled = false

    func cancel() {
        isCancelled = true
    }
}

private final class OnboardingChannelRecordingDelegate:
    OnboardingWizardControllerDelegate {
    var profiles: [VoiceProfile]
    var acceptsHotKeys = false
    private(set) var ensureRequests:
        [Set<OnboardingService>] = []

    init(profiles: [VoiceProfile]) {
        self.profiles = profiles
    }

    func onboardingController(
        _ controller: OnboardingWizardController,
        didRecordHotKey hotKey: HotKeyConfiguration,
        for profile: VoiceProfile
    ) -> Bool {
        guard acceptsHotKeys,
              let index = profiles.firstIndex(where: {
                  $0.id == profile.id
              }) else {
            return false
        }
        profiles[index].hotKey = hotKey
        return true
    }

    func onboardingController(
        _ controller: OnboardingWizardController,
        isRecordingHotKey: Bool
    ) {}

    func onboardingController(
        _ controller: OnboardingWizardController,
        ensureChannelsFor services: Set<OnboardingService>,
        openClawEndpoint: String
    ) {
        ensureRequests.append(services)
        profiles = OnboardingChannelEnsurer.ensure(
            services: services,
            openClawEndpoint: openClawEndpoint,
            in: profiles
        )
    }
}

private final class OnboardingCredentialStore:
    VoiceCredentialStoring {
    private let hasAPIKeyValue: Bool
    private let apiKeyValue: String?

    init(hasAPIKey: Bool = false, apiKey: String? = nil) {
        hasAPIKeyValue = hasAPIKey
        apiKeyValue = apiKey
    }

    func hasAPIKey(for profile: VoiceProfile) -> Bool {
        hasAPIKeyValue
    }

    func apiKey(for profile: VoiceProfile) -> String? {
        apiKeyValue
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

/// A shortcut that is never `defaultVoiceToggle`, so a second channel can be
/// recorded without tripping the conflict path.
extension HotKeyConfiguration {
    static let secondaryTestShortcut = HotKeyConfiguration(
        keyCode: 100,
        carbonModifiers: 0,
        menuKeyEquivalent: "",
        menuModifierMask: [],
        displayName: "F8",
        mainKeyDisplayName: "F8"
    )
}

/// The hot-key step starts a microphone preview; tests must never open the
/// real input device.
private final class SilentOnboardingAudioEngine:
    RealtimeAudioEngineProtocol {
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

private func onboardingButtons(in view: NSView?) -> [NSButton] {
    guard let view else { return [] }
    return view.subviews.flatMap { subview -> [NSButton] in
        var found: [NSButton] = []
        if let button = subview as? NSButton {
            found.append(button)
        }
        found.append(
            contentsOf: onboardingButtons(in: subview)
        )
        return found
    }
}

private final class StubOnboardingURLProtocol:
    URLProtocol {
    static var handler: ((
        URLRequest
    ) throws -> (HTTPURLResponse, Data))?

    override class func canInit(
        with request: URLRequest
    ) -> Bool {
        true
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.badServerResponse)
            )
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(
                self,
                didReceive: response,
                cacheStoragePolicy: .notAllowed
            )
            client?.urlProtocol(
                self,
                didLoad: data
            )
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(
                self,
                didFailWithError: error
            )
        }
    }

    override func stopLoading() {}
}
