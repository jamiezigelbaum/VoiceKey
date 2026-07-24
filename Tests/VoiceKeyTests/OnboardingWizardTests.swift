@testable import VoiceKey
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
                    microphone: .authorized,
                    hasHotKey: true
                )
            ),
            .done
        )
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
            requiresAPIKey: false,
            hasAPIKey: false,
            microphoneAuthorization: .authorized,
            hasHotKey: true
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
        XCTAssertFalse(
            OnboardingWizardController.maskedKey.contains(
                "sk-"
            )
        )
    }

    private func groundTruth(
        location: ApplicationLocationState = .applications,
        hasAPIKey: Bool,
        microphone: MicrophoneAuthorizationState,
        hasHotKey: Bool
    ) -> OnboardingGroundTruth {
        OnboardingGroundTruth(
            applicationLocation: location,
            requiresAPIKey: true,
            hasAPIKey: hasAPIKey,
            microphoneAuthorization: microphone,
            hasHotKey: hasHotKey
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
