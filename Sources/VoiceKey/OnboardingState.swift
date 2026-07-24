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
    var requiresAPIKey: Bool
    var hasAPIKey: Bool
    var microphoneAuthorization: MicrophoneAuthorizationState
    var hasHotKey: Bool
}

enum OnboardingStep: Int, CaseIterable, Hashable {
    case location
    case welcome
    case apiKey
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
        if groundTruth.requiresAPIKey
            && groundTruth.hasAPIKey == false {
            return .apiKey
        }
        if groundTruth.microphoneAuthorization != .authorized {
            return .microphone
        }
        if groundTruth.hasHotKey == false {
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
        case .apiKey:
            return groundTruth.requiresAPIKey == false
                || groundTruth.hasAPIKey
        case .microphone:
            return groundTruth.microphoneAuthorization == .authorized
        case .hotKey:
            return groundTruth.hasHotKey
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
        case .welcome, .apiKey, .microphone, .hotKey:
            return true
        case .done:
            return false
        }
    }

    static func nextStep(
        after step: OnboardingStep,
        groundTruth: OnboardingGroundTruth,
        handledSteps: Set<OnboardingStep>
    ) -> OnboardingStep {
        let sequence: [OnboardingStep] = [
            .apiKey,
            .microphone,
            .hotKey
        ]
        let startIndex: Int
        switch step {
        case .location, .welcome:
            startIndex = 0
        case .apiKey:
            startIndex = 1
        case .microphone:
            startIndex = 2
        case .hotKey, .done:
            return .done
        }

        for candidate in sequence.dropFirst(startIndex) {
            if handledSteps.contains(candidate) == false,
               isComplete(candidate, groundTruth: groundTruth) == false {
                return candidate
            }
        }
        return .done
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
