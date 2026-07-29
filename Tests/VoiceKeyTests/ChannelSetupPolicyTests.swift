@testable import VoiceKey
import XCTest

final class ChannelSetupPolicyTests: XCTestCase {
    private func makeProfile(
        provider: VoiceProviderID = .openAIRealtime,
        hasHotKey: Bool = true,
        endpointURL: String = ""
    ) -> VoiceProfile {
        VoiceProfile(
            name: "Channel",
            providerID: provider,
            hotKey: hasHotKey ? .defaultVoiceToggle : nil,
            model: provider.defaultModel,
            voice: provider.defaultVoice,
            endpointURL: endpointURL
        )
    }

    private func snapshot(
        provider: VoiceProviderID = .openAIRealtime,
        hasHotKey: Bool = true,
        endpointURL: String = "",
        hasCredential: Bool = true,
        registration: ChannelHotKeyRegistration = .carbonRegistered,
        isRecordingHotKey: Bool = false,
        microphone: MicrophoneAuthorizationState = .authorized,
        isAccessibilityTrusted: Bool = true
    ) -> ChannelSetupSnapshot {
        ChannelSetupPolicy.snapshot(
            profile: makeProfile(
                provider: provider,
                hasHotKey: hasHotKey,
                endpointURL: endpointURL
            ),
            hasCredential: hasCredential,
            registration: registration,
            isRecordingHotKey: isRecordingHotKey,
            microphone: microphone,
            isAccessibilityTrusted: isAccessibilityTrusted
        )
    }

    func testEveryProviderRequiresTheMicrophone() {
        for provider in VoiceProviderID.allCases {
            let result = snapshot(
                provider: provider,
                endpointURL: "wss://example.com/realtime",
                microphone: .denied
            )
            XCTAssertTrue(
                result.outstanding.contains(where: {
                    $0.id == .microphone
                }),
                "\(provider) must require the microphone"
            )
        }
    }

    func testMicrophoneRowCopyComesFromTheShippedPolicy() {
        for state: MicrophoneAuthorizationState in [
            .authorized, .notDetermined, .denied, .restricted
        ] {
            let result = ChannelSetupPolicy.snapshot(
                profile: makeProfile(hasHotKey: false),
                hasCredential: false,
                registration: .noHotKey,
                isRecordingHotKey: false,
                microphone: state,
                isAccessibilityTrusted: true
            )
            // Satisfied states drop out of `outstanding`, so assert against the
            // policy composition directly for the ones that remain.
            let expected = SettingsPermissionPolicy.microphone(state)
            let requirement = result.outstanding.first(where: {
                $0.id == .microphone
            })
            if expected.isReady {
                XCTAssertNil(requirement, "\(state) should be satisfied")
            } else {
                XCTAssertEqual(requirement?.row, expected)
            }
        }
    }

    func testChatGPTWebExplainsTheSilentFailure() throws {
        let webReason = try XCTUnwrap(
            snapshot(provider: .chatGPTWeb, microphone: .denied)
                .outstanding
                .first(where: { $0.id == .microphone })?.reason
        )
        let defaultReason = try XCTUnwrap(
            snapshot(provider: .openAIRealtime, microphone: .denied)
                .outstanding
                .first(where: { $0.id == .microphone })?.reason
        )
        XCTAssertNotEqual(webReason, defaultReason)
        XCTAssertTrue(webReason.contains("ChatGPT window"))
    }

    /// The anti-nag gate: a channel whose shortcut registered through Carbon
    /// must never be told it needs Accessibility, trusted or not.
    func testCarbonRegisteredChannelNeverMentionsAccessibility() {
        let result = snapshot(
            registration: .carbonRegistered,
            microphone: .authorized,
            isAccessibilityTrusted: false
        )
        XCTAssertTrue(result.outstanding.isEmpty)
        XCTAssertTrue(result.isReady)
        XCTAssertEqual(result.summary, ChannelSetupPolicy.readySummary)
    }

    func testAccessibilityAppearsOnlyForUntrustedFallback() {
        for registration: ChannelHotKeyRegistration in [
            .noHotKey, .carbonRegistered, .eventMonitorFallback, .unknown
        ] {
            let result = snapshot(
                registration: registration,
                isAccessibilityTrusted: false
            )
            let mentionsAccessibility = result.outstanding.contains(
                where: { $0.id == .accessibility }
            )
            XCTAssertEqual(
                mentionsAccessibility,
                registration == .eventMonitorFallback,
                "\(registration) emitted the wrong accessibility state"
            )
        }
    }

    func testAccessibilityIsSuppressedWhileRecording() {
        let result = snapshot(
            registration: .eventMonitorFallback,
            isRecordingHotKey: true,
            isAccessibilityTrusted: false
        )
        XCTAssertFalse(
            result.outstanding.contains(where: { $0.id == .accessibility })
        )
    }

    func testFallbackShortcutNamesTheShortcutItCannotRegister() throws {
        let reason = try XCTUnwrap(
            snapshot(
                registration: .eventMonitorFallback,
                isAccessibilityTrusted: false
            ).outstanding.first(where: { $0.id == .accessibility })?.reason
        )
        XCTAssertTrue(
            reason.contains(HotKeyConfiguration.defaultVoiceToggle.displayName)
        )

        let trusted = snapshot(
            registration: .eventMonitorFallback,
            isAccessibilityTrusted: true
        )
        XCTAssertTrue(trusted.outstanding.isEmpty)
    }

    func testActivationRequirementMirrorsProfileActivationPolicy() {
        for provider in VoiceProviderID.allCases {
            for hasHotKey in [true, false] {
                for hasCredential in [true, false] {
                    for endpoint in ["", "wss://example.com/realtime"] {
                        let profile = makeProfile(
                            provider: provider,
                            hasHotKey: hasHotKey,
                            endpointURL: endpoint
                        )
                        let failure = ProfileActivationPolicy.failure(
                            for: profile,
                            hasAPIKey: hasCredential
                        )
                        let result = ChannelSetupPolicy.snapshot(
                            profile: profile,
                            hasCredential: hasCredential,
                            registration: .carbonRegistered,
                            isRecordingHotKey: false,
                            microphone: .authorized,
                            isAccessibilityTrusted: true
                        )
                        let activation = result.outstanding.first(where: {
                            $0.id == .activation
                        })
                        XCTAssertEqual(
                            activation != nil,
                            failure != nil,
                            "\(provider) hotKey:\(hasHotKey) key:\(hasCredential) endpoint:\(endpoint.isEmpty)"
                        )
                        XCTAssertEqual(
                            activation?.reason,
                            failure?.settingsMessage
                        )
                    }
                }
            }
        }
    }

    /// The shipped pane test picks the first visible button titled "Enable" or
    /// "Open Settings"; an activation button wearing either title would steal it.
    func testActivationActionTitlesNeverCollideWithPermissionActions() {
        for provider in VoiceProviderID.allCases {
            for hasHotKey in [true, false] {
                for hasCredential in [true, false] {
                    let result = ChannelSetupPolicy.snapshot(
                        profile: makeProfile(
                            provider: provider,
                            hasHotKey: hasHotKey
                        ),
                        hasCredential: hasCredential,
                        registration: .carbonRegistered,
                        isRecordingHotKey: false,
                        microphone: .authorized,
                        isAccessibilityTrusted: true
                    )
                    for requirement in result.outstanding
                    where requirement.id == .activation {
                        XCTAssertNotEqual(
                            requirement.row.actionTitle,
                            "Enable"
                        )
                        XCTAssertNotEqual(
                            requirement.row.actionTitle,
                            "Open Settings"
                        )
                    }
                }
            }
        }
    }

    func testNoSetupCopyContainsTheEndpointOrCredential() {
        let secret = "tok_SENTINEL_DO_NOT_LOG"
        for provider in VoiceProviderID.allCases {
            for microphone: MicrophoneAuthorizationState in [
                .authorized, .notDetermined, .denied, .restricted
            ] {
                for registration: ChannelHotKeyRegistration in [
                    .noHotKey, .carbonRegistered,
                    .eventMonitorFallback, .unknown
                ] {
                    let profile = VoiceProfile(
                        name: "Channel",
                        providerID: provider,
                        hotKey: .defaultVoiceToggle,
                        model: provider.defaultModel,
                        voice: provider.defaultVoice,
                        endpointURL: "wss://gateway.example.com/?token=\(secret)"
                    )
                    let result = ChannelSetupPolicy.snapshot(
                        profile: profile,
                        hasCredential: false,
                        registration: registration,
                        isRecordingHotKey: false,
                        microphone: microphone,
                        isAccessibilityTrusted: false
                    )
                    var strings = [result.summary]
                    for requirement in result.outstanding {
                        strings.append(requirement.title)
                        strings.append(requirement.row.status)
                        strings.append(requirement.row.actionTitle ?? "")
                        strings.append(requirement.reason)
                    }
                    strings.append(
                        ChannelSetupPolicy.requirementSummary(for: provider)
                    )
                    for string in strings {
                        XCTAssertFalse(
                            string.contains(secret),
                            "leaked in: \(string)"
                        )
                        XCTAssertFalse(
                            string.contains("gateway.example.com"),
                            "leaked in: \(string)"
                        )
                    }
                }
            }
        }
    }

    func testRequirementSummaryCoversEveryImplementedProvider() {
        var seen: Set<String> = []
        for provider in VoiceProviderID.allCases
        where provider.isImplemented {
            let summary = ChannelSetupPolicy.requirementSummary(
                for: provider
            )
            XCTAssertFalse(summary.isEmpty, "\(provider) has no summary")
            XCTAssertTrue(
                seen.insert(summary).inserted,
                "\(provider) repeats another provider's summary"
            )
        }
    }

    func testDiagnosticTermMatchesTheShippedStrings() {
        XCTAssertEqual(
            ChannelHotKeyRegistration.carbonRegistered
                .diagnosticTerm(isAccessibilityTrusted: false),
            "Carbon registered"
        )
        XCTAssertEqual(
            ChannelHotKeyRegistration.eventMonitorFallback
                .diagnosticTerm(isAccessibilityTrusted: true),
            "trusted event-monitor fallback"
        )
        XCTAssertEqual(
            ChannelHotKeyRegistration.eventMonitorFallback
                .diagnosticTerm(isAccessibilityTrusted: false),
            "unavailable without Accessibility access"
        )
    }

    func testNoChannelSummaryIsDistinctFromTheReadySummary() {
        XCTAssertNotEqual(
            ChannelSetupPolicy.noChannelSummary,
            ChannelSetupPolicy.readySummary
        )
    }
}
