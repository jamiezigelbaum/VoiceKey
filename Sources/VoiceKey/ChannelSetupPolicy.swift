import Foundation

/// How this Mac ended up serving a channel's global shortcut. Carbon
/// registration needs no Accessibility trust; only the `NSEvent` global monitor
/// fallback does, which is why the two are distinguished rather than collapsed
/// into "the shortcut works / doesn't".
enum ChannelHotKeyRegistration: Equatable {
    case noHotKey
    case carbonRegistered
    case eventMonitorFallback
    /// No app delegate answered — Settings built standalone, as in tests.
    case unknown

    func diagnosticTerm(isAccessibilityTrusted: Bool) -> String {
        switch self {
        case .carbonRegistered:
            return "Carbon registered"
        case .noHotKey, .eventMonitorFallback, .unknown:
            return isAccessibilityTrusted
                ? "trusted event-monitor fallback"
                : "unavailable without Accessibility access"
        }
    }
}

enum ChannelSetupRequirementID: String {
    case activation
    case microphone
    case accessibility
}

enum ChannelSetupAction: Equatable {
    case recordHotKey
    case focusEndpoint
    case focusCredential
    case requestMicrophone
    case requestAccessibility
}

struct ChannelSetupRequirement: Equatable {
    var id: ChannelSetupRequirementID
    var title: String
    var row: PermissionRowSnapshot
    var reason: String
    var action: ChannelSetupAction?
}

struct ChannelSetupSnapshot: Equatable {
    var outstanding: [ChannelSetupRequirement]
    var summary: String

    var isReady: Bool { outstanding.isEmpty }
}

/// Everything the Setup section says about a channel, as pure values.
///
/// No `NSView` is imported or vended here on purpose: a cross-window
/// constraint-ordering failure is then structurally impossible rather than
/// merely avoided, and every decision the section makes is testable without a
/// window.
enum ChannelSetupPolicy {
    static let readySummary = "Everything this channel needs is ready."
    static let noChannelSummary = "Add a voice channel to see what it needs."

    static let microphoneReason =
        "This channel can't start a session without microphone access."
    /// The one provider whose microphone failure surfaces nowhere else: the
    /// WKWebView simply goes quiet.
    static let chatGPTWebMicrophoneReason =
        "The ChatGPT window records through VoiceKey, so it stays silent until microphone access is on."

    /// - Parameter hasCredential: whether a credential exists, never the
    ///   credential itself. No string this function returns may carry an
    ///   endpoint URL, an API key or a gateway token; OpenClaw endpoints can
    ///   carry a token in their query string.
    static func snapshot(
        profile: VoiceProfile,
        hasCredential: Bool,
        registration: ChannelHotKeyRegistration,
        isRecordingHotKey: Bool,
        microphone: MicrophoneAuthorizationState,
        isAccessibilityTrusted: Bool
    ) -> ChannelSetupSnapshot {
        var requirements: [ChannelSetupRequirement] = []

        if let failure = ProfileActivationPolicy.failure(
            for: profile,
            hasAPIKey: hasCredential
        ) {
            requirements.append(activationRequirement(
                failure: failure,
                provider: profile.providerID,
                hasCredential: hasCredential
            ))
        }

        requirements.append(microphoneRequirement(
            provider: profile.providerID,
            microphone: microphone
        ))

        // Accessibility is not a standing requirement: Carbon needs no trust.
        // The row appears only for the "worked yesterday, silent today" case,
        // and never while the recorder is capturing — recording deliberately
        // tears every Carbon registration down, so every channel would read as
        // a fallback for as long as the owner holds the recorder open.
        if registration == .eventMonitorFallback,
           isRecordingHotKey == false {
            requirements.append(accessibilityRequirement(
                profile: profile,
                isAccessibilityTrusted: isAccessibilityTrusted
            ))
        }

        let outstanding = requirements.filter { $0.row.isReady == false }
        return ChannelSetupSnapshot(
            outstanding: outstanding,
            summary: outstanding.isEmpty ? readySummary : ""
        )
    }

    /// Static per-provider copy for the add-channel alert. Reads no live state,
    /// so it can never prompt while the modal owns the run loop.
    static func requirementSummary(
        for provider: VoiceProviderID
    ) -> String {
        // Deliberately no `default`: a seventh provider must state what it
        // needs before the build succeeds.
        switch provider {
        case .openAIRealtime:
            return "Needs: a global shortcut, microphone access, and an OpenAI API key."
        case .chatGPTWeb:
            return "Needs: a global shortcut and microphone access. You sign in to ChatGPT in its own window."
        case .geminiLive:
            return "Needs: a global shortcut, microphone access, and a Gemini API key."
        case .deepgramVoiceAgent:
            return "Needs: a global shortcut, microphone access, and a Deepgram API key."
        case .custom:
            return "Needs: a global shortcut, microphone access, and the endpoint URL of your realtime service."
        case .openClaw:
            return "Needs: a global shortcut and microphone access. The gateway token comes from this Mac's OpenClaw pairing unless you enter one."
        }
    }

    // MARK: - Requirements

    private static func activationRequirement(
        failure: ProfileActivationFailure,
        provider: VoiceProviderID,
        hasCredential: Bool
    ) -> ChannelSetupRequirement {
        let title: String
        let status: String
        let actionTitle: String?
        let action: ChannelSetupAction?

        switch failure {
        case .missingHotKey:
            title = "Shortcut"
            status = "Not set"
            actionTitle = "Record…"
            action = .recordHotKey
        case .missingEndpoint:
            title = "Endpoint"
            status = "Required"
            actionTitle = "Set Endpoint"
            action = .focusEndpoint
        case .providerNotReady:
            title = provider.credentialLabel
            status = "Required"
            // Only a missing key has a place in this window to go to; an
            // unimplemented provider gets the reason line and nothing else.
            if case .needsAPIKey = provider.readiness(
                hasAPIKey: hasCredential
            ) {
                actionTitle = "Add Key"
                action = .focusCredential
            } else {
                actionTitle = nil
                action = nil
            }
        }

        return ChannelSetupRequirement(
            id: .activation,
            title: title,
            row: PermissionRowSnapshot(
                isReady: false,
                status: status,
                actionTitle: actionTitle
            ),
            reason: failure.settingsMessage,
            action: action
        )
    }

    private static func microphoneRequirement(
        provider: VoiceProviderID,
        microphone: MicrophoneAuthorizationState
    ) -> ChannelSetupRequirement {
        let reason: String
        switch provider {
        case .chatGPTWeb:
            reason = chatGPTWebMicrophoneReason
        default:
            reason = microphoneReason
        }
        return ChannelSetupRequirement(
            id: .microphone,
            title: "Microphone",
            // Composed, never restated: the two policies cannot drift.
            row: SettingsPermissionPolicy.microphone(microphone),
            reason: reason,
            action: .requestMicrophone
        )
    }

    private static func accessibilityRequirement(
        profile: VoiceProfile,
        isAccessibilityTrusted: Bool
    ) -> ChannelSetupRequirement {
        let shortcutName = profile.hotKey?.displayName
            ?? "this channel's shortcut"
        return ChannelSetupRequirement(
            id: .accessibility,
            title: "Accessibility",
            row: SettingsPermissionPolicy.accessibility(
                isTrusted: isAccessibilityTrusted
            ),
            reason: "macOS refused to register \(shortcutName) the usual way, so this channel's shortcut only works while VoiceKey has Accessibility access.",
            action: .requestAccessibility
        )
    }
}
