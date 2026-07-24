import Foundation

enum ApplicationLocationState: Equatable {
    case applications
    case outsideApplications
    case translocated

    static func detect(
        executableURL: URL?,
        bundleURL: URL
    ) -> ApplicationLocationState {
        if executableURL?.path.contains("/AppTranslocation/") == true {
            return .translocated
        }
        let path = bundleURL.standardizedFileURL.path
        if path == "/Applications"
            || path.hasPrefix("/Applications/") {
            return .applications
        }
        return .outsideApplications
    }
}

enum MicrophoneAuthorizationState: Equatable {
    case notDetermined
    case denied
    case authorized
    case restricted
}

struct OnboardingGroundTruth: Equatable {
    var applicationLocation: ApplicationLocationState
    var selectedServices: Set<OnboardingService>
    var hasOpenAIAPIKey: Bool
    var hasOpenClawConnection: Bool
    var microphoneAuthorization: MicrophoneAuthorizationState
    var hasHotKeysForSelectedServices: Bool
}

enum OnboardingService: String, CaseIterable, Codable, Hashable {
    case openAI
    case openClaw

    var providerID: VoiceProviderID {
        switch self {
        case .openAI:
            return .openAIRealtime
        case .openClaw:
            return .openClaw
        }
    }
}

enum OnboardingServicePreferences {
    private static let selectionKey = "Onboarding.selectedServices.v1"
    private static let openClawConnectedKey = "Onboarding.openClawConnected.v1"

    static func selectedServices(
        defaults: UserDefaults = .standard
    ) -> Set<OnboardingService>? {
        guard defaults.object(forKey: selectionKey) != nil else {
            return nil
        }
        let values = defaults.stringArray(forKey: selectionKey) ?? []
        return Set(values.compactMap(OnboardingService.init(rawValue:)))
    }

    static func saveSelectedServices(
        _ services: Set<OnboardingService>,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(
            services.map(\.rawValue).sorted(),
            forKey: selectionKey
        )
    }

    static func hasOpenClawConnection(
        defaults: UserDefaults = .standard
    ) -> Bool {
        defaults.bool(forKey: openClawConnectedKey)
    }

    static func setHasOpenClawConnection(
        _ connected: Bool,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(connected, forKey: openClawConnectedKey)
    }

    static func inferredServices(
        from profiles: [VoiceProfile]
    ) -> Set<OnboardingService> {
        let inferred = Set(profiles.compactMap { profile in
            OnboardingService.allCases.first {
                $0.providerID == profile.providerID
            }
        })
        return inferred.isEmpty ? [.openAI] : inferred
    }
}

enum OnboardingChannelEnsurer {
    static func ensure(
        services: Set<OnboardingService>,
        openClawEndpoint: String,
        in profiles: [VoiceProfile]
    ) -> [VoiceProfile] {
        var ensured = profiles
        for service in OnboardingService.allCases
            where services.contains(service) {
            let provider = service.providerID
            if let index = ensured.firstIndex(where: {
                $0.providerID == provider
            }) {
                if service == .openClaw,
                   openClawEndpoint.isEmpty == false {
                    ensured[index].endpointURL = openClawEndpoint
                }
                continue
            }
            ensured.append(VoiceProfile(
                name: service == .openAI ? "OpenAI" : "OpenClaw",
                providerID: provider,
                hotKey: nil,
                model: provider.defaultModel,
                voice: provider.defaultVoice,
                instructions: "",
                endpointURL: service == .openClaw
                    ? openClawEndpoint
                    : ""
            ))
        }
        return VoiceProfileStore.sortedByHotKey(ensured)
    }
}

enum OnboardingHotKeyPolicy {
    static func nextProfile(
        in profiles: [VoiceProfile],
        selectedServices: Set<OnboardingService>,
        handledProfileIDs: Set<UUID>
    ) -> VoiceProfile? {
        let selectedProviderIDs = Set(
            selectedServices.map(\.providerID)
        )
        return profiles.first {
            selectedProviderIDs.contains($0.providerID)
                && $0.hotKey == nil
                && handledProfileIDs.contains($0.id) == false
        }
    }

    static func hasHotKeysForEverySelectedChannel(
        profiles: [VoiceProfile],
        selectedServices: Set<OnboardingService>
    ) -> Bool {
        let selectedProviderIDs = Set(
            selectedServices.map(\.providerID)
        )
        let selectedProfiles = profiles.filter {
            selectedProviderIDs.contains($0.providerID)
        }
        return Set(selectedProfiles.map(\.providerID))
            == selectedProviderIDs
            && selectedProfiles.allSatisfy {
                $0.hotKey != nil
            }
    }
}

enum OnboardingStep: Int, CaseIterable, Hashable {
    case location
    case welcome
    case services
    case apiKey
    case openClawConnect
    case microphone
    case hotKey
    case done
}

enum OnboardingFlowPolicy {
    static func initialStep(
        groundTruth: OnboardingGroundTruth
    ) -> OnboardingStep {
        if groundTruth.applicationLocation != .applications {
            return .location
        }
        return .welcome
    }

    static func reentryStep(
        groundTruth: OnboardingGroundTruth
    ) -> OnboardingStep {
        firstIncompleteStep(groundTruth: groundTruth)
    }

    static func firstIncompleteStep(
        groundTruth: OnboardingGroundTruth
    ) -> OnboardingStep {
        if groundTruth.applicationLocation != .applications {
            return .location
        }
        if groundTruth.selectedServices.isEmpty {
            return .services
        }
        if groundTruth.selectedServices.contains(.openAI)
            && groundTruth.hasOpenAIAPIKey == false {
            return .apiKey
        }
        if groundTruth.selectedServices.contains(.openClaw)
            && groundTruth.hasOpenClawConnection == false {
            return .openClawConnect
        }
        if groundTruth.microphoneAuthorization != .authorized {
            return .microphone
        }
        if groundTruth.hasHotKeysForSelectedServices == false {
            return .hotKey
        }
        return .done
    }

    static func isComplete(
        _ step: OnboardingStep,
        groundTruth: OnboardingGroundTruth
    ) -> Bool {
        switch step {
        case .location:
            return groundTruth.applicationLocation == .applications
        case .welcome:
            return false
        case .services:
            return groundTruth.selectedServices.isEmpty == false
        case .apiKey:
            return groundTruth.selectedServices.contains(.openAI) == false
                || groundTruth.hasOpenAIAPIKey
        case .openClawConnect:
            return groundTruth.selectedServices.contains(.openClaw) == false
                || groundTruth.hasOpenClawConnection
        case .microphone:
            return groundTruth.microphoneAuthorization == .authorized
        case .hotKey:
            return groundTruth.hasHotKeysForSelectedServices
        case .done:
            return false
        }
    }

    static func canSkip(
        _ step: OnboardingStep,
        groundTruth: OnboardingGroundTruth
    ) -> Bool {
        switch step {
        case .location:
            return groundTruth.applicationLocation == .outsideApplications
        case .welcome, .apiKey, .openClawConnect, .microphone, .hotKey:
            return true
        case .services, .done:
            return false
        }
    }

    static func nextStep(
        after step: OnboardingStep,
        groundTruth: OnboardingGroundTruth,
        handledSteps: Set<OnboardingStep>
    ) -> OnboardingStep {
        let sequence: [OnboardingStep] = [
            .services,
            .apiKey,
            .openClawConnect,
            .microphone,
            .hotKey
        ]
        let startIndex: Int
        switch step {
        case .location, .welcome:
            startIndex = 0
        case .services:
            startIndex = 1
        case .apiKey:
            startIndex = 2
        case .openClawConnect:
            startIndex = 3
        case .microphone:
            startIndex = 4
        case .hotKey, .done:
            return .done
        }

        for candidate in sequence.dropFirst(startIndex) {
            if candidate == .services,
               handledSteps.contains(.services) == false {
                return .services
            }
            if handledSteps.contains(candidate) == false,
               isComplete(candidate, groundTruth: groundTruth) == false {
                return candidate
            }
        }
        return .done
    }
}

enum OpenClawConnectionWizardState: Equatable {
    case searching
    case testing
    case needsToken(message: String)
    case needsEndpoint
    case pairingWait(
        reason: String?,
        requestID: String?,
        remediationHint: String?
    )
    case success(serverVersion: String)
    case failed(message: String)
}

protocol OnboardingRetryCancellation: AnyObject {
    func cancel()
}

typealias OnboardingRetryScheduler = (
    TimeInterval,
    @escaping () -> Void
) -> OnboardingRetryCancellation

extension DispatchWorkItem: OnboardingRetryCancellation {}

final class OpenClawConnectionWizard {
    var onStateChange: ((OpenClawConnectionWizardState) -> Void)?

    private let tester: OpenClawConnectionTesting
    private let tokenProvider: () -> String?
    private let retryScheduler: OnboardingRetryScheduler
    private var activeTest: OpenClawConnectionTestCancellation?
    private var retryCancellation: OnboardingRetryCancellation?
    private var endpointURL = ""
    private var isVisible = false
    private(set) var state: OpenClawConnectionWizardState = .searching {
        didSet {
            onStateChange?(state)
        }
    }

    init(
        tester: OpenClawConnectionTesting,
        tokenProvider: @escaping () -> String?,
        retryScheduler: @escaping OnboardingRetryScheduler = { delay, action in
            let workItem = DispatchWorkItem(block: action)
            DispatchQueue.main.asyncAfter(
                deadline: .now() + delay,
                execute: workItem
            )
            return workItem
        }
    ) {
        self.tester = tester
        self.tokenProvider = tokenProvider
        self.retryScheduler = retryScheduler
    }

    deinit {
        leave()
    }

    func begin(endpointURL: String) {
        leave()
        self.endpointURL = endpointURL
        isVisible = true
        state = .searching
        guard hasToken else {
            state = .needsToken(
                message: "No gateway token was found on this Mac."
            )
            return
        }
        testConnection(preservingPairingScreen: false)
    }

    func retry(endpointURL: String? = nil) {
        if let endpointURL {
            self.endpointURL = endpointURL
        }
        retryCancellation?.cancel()
        retryCancellation = nil
        guard isVisible else { return }
        guard hasToken else {
            state = .needsToken(
                message: "Paste a gateway token, then try again."
            )
            return
        }
        testConnection(preservingPairingScreen: false)
    }

    func leave() {
        isVisible = false
        activeTest?.cancel()
        activeTest = nil
        retryCancellation?.cancel()
        retryCancellation = nil
    }

    private var hasToken: Bool {
        guard let token = tokenProvider()?
            .trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return token.isEmpty == false
    }

    private func testConnection(
        preservingPairingScreen: Bool
    ) {
        activeTest?.cancel()
        activeTest = nil
        if preservingPairingScreen == false {
            state = .testing
        }
        activeTest = tester.testConnection(
            endpointURL: endpointURL
        ) { [weak self] outcome in
            guard let self, self.isVisible else { return }
            self.activeTest = nil
            self.handle(outcome)
        }
    }

    private func handle(_ outcome: OpenClawConnectionOutcome) {
        retryCancellation?.cancel()
        retryCancellation = nil
        switch outcome {
        case let .ok(serverVersion, _):
            state = .success(serverVersion: serverVersion)
        case let .pairingRequired(reason, requestID, remediationHint):
            state = .pairingWait(
                reason: reason,
                requestID: requestID,
                remediationHint: remediationHint
            )
            retryCancellation = retryScheduler(4) { [weak self] in
                guard let self, self.isVisible else { return }
                self.retryCancellation = nil
                self.testConnection(
                    preservingPairingScreen: true
                )
            }
        case .gatewayTokenMissing:
            state = .needsToken(
                message: "The gateway needs an access token."
            )
        case .gatewayTokenMismatch:
            state = .needsToken(
                message: "That gateway token wasn’t accepted."
            )
        case .deviceTokenMismatch:
            state = .failed(
                message: "OpenClaw’s saved device approval is no longer valid. Re-pair this Mac in OpenClaw, then try again."
            )
        case .unreachable:
            state = .needsEndpoint
        case let .failed(_, message):
            state = .failed(message: message)
        }
    }
}

enum APIKeyVerificationError: Error, Equatable {
    case rejected
    case serverStatus(Int)
    case network

    var userMessage: String {
        switch self {
        case .rejected:
            return "That key wasn’t accepted. Check it and try again."
        case let .serverStatus(status):
            return "OpenAI couldn’t verify that key (HTTP \(status)). Try again."
        case .network:
            return "Couldn’t reach OpenAI. Check your connection and try again."
        }
    }
}

enum APIKeyVerificationState: Equatable {
    case idle
    case verifying
    case verified
    case failed(String)

    mutating func begin() {
        self = .verifying
    }

    mutating func finish(
        _ result: Result<Void, APIKeyVerificationError>
    ) {
        switch result {
        case .success:
            self = .verified
        case let .failure(error):
            self = .failed(error.userMessage)
        }
    }
}

protocol APIKeyVerifying {
    func verify(
        apiKey: String,
        completion: @escaping (
            Result<Void, APIKeyVerificationError>
        ) -> Void
    )
}

final class OpenAIAPIKeyVerifier: APIKeyVerifying {
    private let endpoint: URL
    private let session: URLSession

    init(
        endpoint: URL = URL(
            string: "https://api.openai.com/v1/models"
        )!,
        session: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.session = session
    }

    func verify(
        apiKey: String,
        completion: @escaping (
            Result<Void, APIKeyVerificationError>
        ) -> Void
    ) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue(
            "Bearer \(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))",
            forHTTPHeaderField: "Authorization"
        )
        session.dataTask(with: request) { _, response, error in
            let result: Result<Void, APIKeyVerificationError>
            if error != nil {
                result = .failure(.network)
            } else if let response = response as? HTTPURLResponse {
                switch response.statusCode {
                case 200..<300:
                    result = .success(())
                case 401, 403:
                    result = .failure(.rejected)
                default:
                    result = .failure(
                        .serverStatus(response.statusCode)
                    )
                }
            } else {
                result = .failure(.network)
            }
            DispatchQueue.main.async {
                completion(result)
            }
        }.resume()
    }
}
