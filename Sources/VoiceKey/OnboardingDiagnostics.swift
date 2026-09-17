import Foundation

/// Why the wizard is on a step, when the step was derived from ground truth
/// rather than picked by the owner.
enum OnboardingStepReason: String {
    case appNotInApplications = "app-not-in-applications"
    case firstRun = "first-run"
    case noServicesSelected = "no-services-selected"
    case openAIKeyMissing = "openai-key-missing"
    case openClawNotConnected = "openclaw-not-connected"
    case microphoneNotAuthorized = "microphone-not-authorized"
    case hotKeysMissing = "hotkeys-missing"
    case everythingComplete = "everything-complete"
    /// Nothing is left to finish and the owner opened the assistant anyway, so
    /// the picker is the only screen that can still do something for them.
    case addAnotherService = "add-another-service"
    case userChoice = "user-choice"
}

/// Sink for wizard diagnostics. `VoiceSessionLogFile` is the production
/// implementation; tests substitute a recorder.
protocol OnboardingDiagnosticsLogging: AnyObject {
    func record(_ event: OnboardingLogEvent, timestamp: Date)
}

extension OnboardingDiagnosticsLogging {
    func record(_ event: OnboardingLogEvent) {
        record(event, timestamp: Date())
    }
}

/// Every fact the onboarding wizard writes to the on-disk session log.
///
/// A remote Mac cannot be screen-recorded (macOS will not grant Screen
/// Recording to an ssh'd CLI binary), so this log is the only evidence that a
/// first-run walkthrough happened at all — the service picker shipped broken
/// mid-render with both the app log and the gateway log empty (2026-07-25).
///
/// The cases carry categories, step names, request ids, endpoints and shortcut
/// names. They never carry an API key, a gateway token or a device token, not
/// even truncated or masked: only presence/absence. Anything that could smuggle
/// one — an endpoint the owner typed — is run through the shared publishable
/// endpoint formatter, which keeps the address and drops user info and query.
enum OnboardingLogEvent {
    /// Fills the slot the provider wire name takes on voice-session lines.
    static let component = "onboarding"

    enum Opening: String {
        case fresh
        case reentrant
    }

    /// What moved the wizard off a step.
    enum StepTrigger: String {
        /// The owner clicked the step's primary button.
        case advance
        /// The owner chose "Skip for now".
        case skipped
        /// A live fact changed and the wizard moved itself.
        case groundTruth = "ground-truth"
        /// The relocation gate let the owner past it.
        case relocation
    }

    /// Deliberately a category, never the key or the server's reply.
    enum APIKeyOutcome: Equatable {
        case verified
        case rejected
        case serverStatus(Int)
        case networkFailure

        var logName: String {
            switch self {
            case .verified:
                return "verified"
            case .rejected:
                return "rejected"
            case let .serverStatus(status):
                return "server-status-\(status)"
            case .networkFailure:
                return "network-failure"
            }
        }
    }

    enum HotKeyOutcome: Equatable {
        case registered
        case registrationFailed
        case conflict(channel: String)
    }

    enum RelocationOutcome: Equatable {
        case gate(ApplicationLocationState)
        case moveStarted
        case moveSucceeded
        case moveFailed(String)
        case continuedOutsideApplications
    }

    case wizardOpened(
        Opening,
        step: OnboardingStep,
        reason: OnboardingStepReason
    )
    case wizardClosed(step: OnboardingStep)
    case stepTransition(
        from: OnboardingStep,
        to: OnboardingStep,
        trigger: StepTrigger,
        reason: OnboardingStepReason?
    )
    /// A skip that leaves the wizard on the same step — the hot-key step walks
    /// one channel at a time, so skipping one is invisible in a transition.
    case stepSkippedInPlace(step: OnboardingStep, detail: String)
    /// `added` is the subset with no channel yet — the difference between a
    /// walkthrough that re-confirms what the owner already had and one that is
    /// actually adding a service.
    case servicesConfirmed(
        [OnboardingService],
        added: [OnboardingService]
    )
    case channelsEnsured(
        services: [OnboardingService],
        hasOpenClawEndpoint: Bool
    )
    case apiKeyVerification(APIKeyOutcome)
    case credentialSaveFailed(channel: String, message: String)
    case openClawTest(
        attempt: Int,
        endpoint: String,
        isAutoRetry: Bool,
        pairingRequestID: String?
    )
    case openClawOutcome(OpenClawConnectionOutcome, endpoint: String)
    case openClawTokenEntered(present: Bool)
    case microphoneAuthorization(
        from: MicrophoneAuthorizationState?,
        to: MicrophoneAuthorizationState
    )
    case hotKeyCapture(
        channel: String,
        shortcut: String,
        outcome: HotKeyOutcome
    )
    case relocation(RelocationOutcome)

    /// The word between the component and the colon, matching the
    /// `status:`/`transcript:`/`diagnostic:` slot on voice-session lines.
    var kind: String {
        switch self {
        case .wizardOpened, .wizardClosed:
            return "wizard"
        case .stepTransition, .stepSkippedInPlace:
            return "step"
        case .servicesConfirmed:
            return "services"
        case .channelsEnsured:
            return "channels"
        case .apiKeyVerification, .credentialSaveFailed:
            return "apikey"
        case .openClawTest, .openClawOutcome, .openClawTokenEntered:
            return "openclaw"
        case .microphoneAuthorization:
            return "microphone"
        case .hotKeyCapture:
            return "hotkey"
        case .relocation:
            return "location"
        }
    }

    var text: String {
        switch self {
        case let .wizardOpened(opening, step, reason):
            return "opened \(opening.rawValue) at step=\(step.logName) reason=\(reason.rawValue)"
        case let .wizardClosed(step):
            return "closed at step=\(step.logName)"
        case let .stepTransition(from, to, trigger, reason):
            var text = "\(from.logName) -> \(to.logName) trigger=\(trigger.rawValue)"
            if let reason {
                text += " reason=\(reason.rawValue)"
            }
            return text
        case let .stepSkippedInPlace(step, detail):
            return "\(step.logName) skipped \(detail)"
        case let .servicesConfirmed(services, added):
            return "confirmed \(Self.list(services))"
                + " added=\(Self.list(added))"
        case let .channelsEnsured(services, hasOpenClawEndpoint):
            return "ensured \(Self.list(services)) openClawEndpoint="
                + (hasOpenClawEndpoint ? "present" : "absent")
        case let .apiKeyVerification(outcome):
            return "verification \(outcome.logName)"
        case let .credentialSaveFailed(channel, message):
            return "save failed channel=\(channel) message=\(Self.clipped(message))"
        case let .openClawTest(attempt, endpoint, isAutoRetry, requestID):
            var text = "test #\(attempt) endpoint=\(Self.sanitizedEndpoint(endpoint))"
            if isAutoRetry {
                text += " auto-retry"
            }
            if let requestID, requestID.isEmpty == false {
                text += " requestId=\(requestID)"
            }
            return text
        case let .openClawOutcome(outcome, endpoint):
            return "outcome=\(Self.describe(outcome)) endpoint="
                + Self.sanitizedEndpoint(endpoint)
        case let .openClawTokenEntered(present):
            return "token entered: " + (present ? "present" : "absent")
        case let .microphoneAuthorization(from, to):
            return "\(from?.logName ?? "unknown") -> \(to.logName)"
        case let .hotKeyCapture(channel, shortcut, outcome):
            let result: String
            switch outcome {
            case .registered:
                result = "registered"
            case .registrationFailed:
                result = "registration-failed"
            case let .conflict(other):
                result = "conflict-with=\(other)"
            }
            return "channel=\(channel) shortcut=\(shortcut) \(result)"
        case let .relocation(outcome):
            switch outcome {
            case let .gate(state):
                return "gate state=\(state.logName)"
            case .moveStarted:
                return "move to Applications started"
            case .moveSucceeded:
                return "move to Applications succeeded"
            case let .moveFailed(message):
                return "move to Applications failed: \(Self.clipped(message))"
            case .continuedOutsideApplications:
                return "continued outside Applications"
            }
        }
    }

    private static func list(_ services: [OnboardingService]) -> String {
        guard services.isEmpty == false else { return "none" }
        return services.map(\.rawValue).sorted().joined(separator: ", ")
    }

    private static func clipped(_ message: String) -> String {
        message.count <= 200
            ? message
            : String(message.prefix(200)) + "…"
    }

    /// Compatibility entry point for the onboarding diagnostics contract.
    /// Formatting is owned by `PublishableDiagnosticEndpoint` so every
    /// persisted or pasteable endpoint has one mandatory representation.
    static func sanitizedEndpoint(_ endpoint: String) -> String {
        PublishableDiagnosticEndpoint(endpoint).description
    }

    private static func describe(
        _ outcome: OpenClawConnectionOutcome
    ) -> String {
        switch outcome {
        case let .ok(serverVersion, scopes):
            return "ok serverVersion=\(serverVersion) scopes=\(scopes.count)"
        case let .pairingRequired(reason, requestID, _):
            var text = "pairingRequired"
            if let reason, reason.isEmpty == false {
                text += " reason=\(reason)"
            }
            if let requestID, requestID.isEmpty == false {
                text += " requestId=\(requestID)"
            }
            return text
        case .gatewayTokenMissing:
            return "gatewayTokenMissing"
        case .gatewayTokenMismatch:
            return "gatewayTokenMismatch"
        case .deviceTokenMismatch:
            return "deviceTokenMismatch"
        case let .unreachable(endpointsTried):
            let tried = endpointsTried
                .map(Self.sanitizedEndpoint)
                .joined(separator: ",")
            return "unreachable endpointsTried=\(tried.isEmpty ? "none" : tried)"
        case let .failed(code, message):
            return "failed code=\(code) message=\(Self.clipped(message))"
        }
    }
}

extension OnboardingStep {
    /// Stable name for the log; renaming a case must not change the on-disk
    /// term, the same contract the provider wire names hold.
    var logName: String {
        switch self {
        case .location:
            return "location"
        case .welcome:
            return "welcome"
        case .services:
            return "services"
        case .apiKey:
            return "apiKey"
        case .openClawConnect:
            return "openClawConnect"
        case .microphone:
            return "microphone"
        case .hotKey:
            return "hotKey"
        case .done:
            return "done"
        }
    }
}

extension MicrophoneAuthorizationState {
    var logName: String {
        switch self {
        case .notDetermined:
            return "notDetermined"
        case .denied:
            return "denied"
        case .authorized:
            return "authorized"
        case .restricted:
            return "restricted"
        }
    }
}

extension ApplicationLocationState {
    var logName: String {
        switch self {
        case .applications:
            return "applications"
        case .outsideApplications:
            return "outsideApplications"
        case .translocated:
            return "translocated"
        }
    }
}
