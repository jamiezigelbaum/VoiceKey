@testable import VoiceKey
import Foundation
import XCTest

final class OpenClawConnectionTesterTests: XCTestCase {
    func testSuccessFixtureMapsHelloWithoutOKAndCanonicalAuth() {
        let frame = """
            {"type":"res","id":"1","result":{"type":"hello-ok","protocol":4,\
            "server":{"version":"2026.7.1-2","connId":"connection-1"},\
            "auth":{"role":"operator","scopes":["operator.read","operator.write"],\
            "deviceToken":"canonical-device-token","issuedAtMs":1784300000000}}}
            """

        XCTAssertEqual(
            OpenClawConnectionOutcomeMapper.outcome(from: frame),
            .ok(
                serverVersion: "2026.7.1-2",
                scopes: ["operator.read", "operator.write"]
            )
        )
        XCTAssertEqual(
            OpenClawTalkEventMapper.actions(from: frame, sessionID: nil),
            [
                .connected(deviceToken: "canonical-device-token"),
                .providerEvent(.diagnostic("Connected to OpenClaw gateway."))
            ]
        )
    }

    func testPairingFixtureMapsAllApprovalDetails() {
        let frame = """
            {"type":"res","id":"1","ok":false,"error":{"code":"NOT_PAIRED",\
            "message":"pairing required: device identity changed and must be re-approved",\
            "details":{"code":"PAIRING_REQUIRED","reason":"metadata-upgrade",\
            "requestId":"267ca1ba-latest","remediationHint":"Review the refreshed device details, then approve the pending request.",\
            "deviceId":"device-1","requestedRole":"operator",\
            "requestedScopes":["operator.read"],"approvedRoles":["operator"],\
            "approvedScopes":["operator.read"]}}}
            """

        XCTAssertEqual(
            OpenClawConnectionOutcomeMapper.outcome(from: frame),
            .pairingRequired(
                reason: "metadata-upgrade",
                requestID: "267ca1ba-latest",
                remediationHint: "Review the refreshed device details, then approve the pending request."
            )
        )
    }

    func testDeviceTokenMismatchFixtureMapsTypedOutcome() {
        let frame = """
            {"type":"res","id":"1","ok":false,"error":{"code":"INVALID_REQUEST",\
            "message":"unauthorized: device token mismatch (rotate/reissue device token)",\
            "details":{"code":"AUTH_DEVICE_TOKEN_MISMATCH",\
            "authReason":"device_token_mismatch","canRetryWithDeviceToken":false,\
            "recommendedNextStep":"update_auth_credentials"}}}
            """

        XCTAssertEqual(
            OpenClawConnectionOutcomeMapper.outcome(from: frame),
            .deviceTokenMismatch
        )
    }

    func testGatewayTokenMissingFixtureMapsTypedOutcome() {
        let frame = """
            {"type":"res","id":"1","ok":false,"error":{"code":"INVALID_REQUEST",\
            "message":"unauthorized: gateway token missing (provide gateway auth token)",\
            "details":{"code":"AUTH_TOKEN_MISSING","authReason":"token_missing",\
            "canRetryWithDeviceToken":false,\
            "recommendedNextStep":"update_auth_configuration"}}}
            """

        XCTAssertEqual(
            OpenClawConnectionOutcomeMapper.outcome(from: frame),
            .gatewayTokenMissing
        )
    }

    func testGatewayTokenMismatchMapsTypedOutcome() {
        let frame = """
            {"type":"res","id":"1","ok":false,"error":{"code":"INVALID_REQUEST",\
            "message":"unauthorized: gateway token mismatch",\
            "details":{"code":"AUTH_TOKEN_MISMATCH","authReason":"token_mismatch",\
            "canRetryWithDeviceToken":false,\
            "recommendedNextStep":"update_auth_configuration"}}}
            """

        XCTAssertEqual(
            OpenClawConnectionOutcomeMapper.outcome(from: frame),
            .gatewayTokenMismatch
        )
    }

    func testUnknownFailureMapsCodeAndMessage() {
        let frame = """
            {"type":"res","id":"1","ok":false,"error":{\
            "code":"UNAVAILABLE","message":"Talk is disabled."}}
            """

        XCTAssertEqual(
            OpenClawConnectionOutcomeMapper.outcome(from: frame),
            .failed(code: "UNAVAILABLE", message: "Talk is disabled.")
        )
    }

    func testDeviceTokenMismatchRetriesSameEndpointOnceWithoutDeviceToken() throws {
        let firstSocket = ConnectionTesterFakeWebSocket(messages: [
            connectChallenge(nonce: "nonce-1"),
            deviceTokenMismatchResponse
        ])
        let retrySocket = ConnectionTesterFakeWebSocket(messages: [
            connectChallenge(nonce: "nonce-2"),
            successfulHelloResponse
        ])
        let factory = ConnectionTesterWebSocketFactory(
            sockets: [firstSocket, retrySocket]
        )
        let tester = makeTester(factory: factory)
        let completed = expectation(description: "connection repaired")
        var receivedOutcome: OpenClawConnectionOutcome?

        _ = tester.testConnection(
            endpointURL: "ws://127.0.0.1:18790"
        ) { outcome in
            receivedOutcome = outcome
            completed.fulfill()
        }

        wait(for: [completed], timeout: 1)
        XCTAssertEqual(
            receivedOutcome,
            .ok(
                serverVersion: "2026.7.1-2",
                scopes: ["operator.read"]
            )
        )
        XCTAssertEqual(
            factory.requestedURLs.map(\.absoluteString),
            [
                "ws://127.0.0.1:18790",
                "ws://127.0.0.1:18790"
            ]
        )

        let firstParameters = try XCTUnwrap(
            firstSocket.sentFrames.first?["params"]
                as? [String: Any]
        )
        let firstAuth = try XCTUnwrap(
            firstParameters["auth"] as? [String: Any]
        )
        XCTAssertEqual(
            firstAuth["deviceToken"] as? String,
            "stale-device-token"
        )
        XCTAssertEqual(
            (firstParameters["device"] as? [String: Any])?["nonce"]
                as? String,
            "nonce-1"
        )

        let retryParameters = try XCTUnwrap(
            retrySocket.sentFrames.first?["params"]
                as? [String: Any]
        )
        let retryAuth = try XCTUnwrap(
            retryParameters["auth"] as? [String: Any]
        )
        XCTAssertNil(retryAuth["deviceToken"])
        XCTAssertEqual(
            (retryParameters["device"] as? [String: Any])?["nonce"]
                as? String,
            "nonce-2"
        )
    }

    func testSecondDeviceTokenMismatchSurfacesFailureWithoutLooping() {
        let firstSocket = ConnectionTesterFakeWebSocket(messages: [
            connectChallenge(nonce: "nonce-1"),
            deviceTokenMismatchResponse
        ])
        let retrySocket = ConnectionTesterFakeWebSocket(messages: [
            connectChallenge(nonce: "nonce-2"),
            deviceTokenMismatchResponse
        ])
        let unexpectedThirdSocket =
            ConnectionTesterFakeWebSocket(messages: [
                connectChallenge(nonce: "nonce-3"),
                successfulHelloResponse
            ])
        let factory = ConnectionTesterWebSocketFactory(
            sockets: [
                firstSocket,
                retrySocket,
                unexpectedThirdSocket
            ]
        )
        let tester = makeTester(factory: factory)
        let completed = expectation(description: "mismatch surfaced")
        var receivedOutcome: OpenClawConnectionOutcome?

        _ = tester.testConnection(
            endpointURL: "ws://127.0.0.1:18790"
        ) { outcome in
            receivedOutcome = outcome
            completed.fulfill()
        }

        wait(for: [completed], timeout: 1)
        XCTAssertEqual(receivedOutcome, .deviceTokenMismatch)
        XCTAssertEqual(factory.requestedURLs.count, 2)
        XCTAssertTrue(unexpectedThirdSocket.sentFrames.isEmpty)
    }

    // MARK: - Credential source reporting

    func testSuccessReportsEnteredTokenSourceAndNamesItInCopy() {
        let result = runTest(
            messages: [
                connectChallenge(nonce: "nonce-1"),
                successfulHelloResponse
            ],
            resolution: OpenClawGatewayTokenResolution(
                token: "entered-token",
                source: .enteredToken
            ),
            discoveredToken: "discovered-token"
        )

        XCTAssertEqual(result?.tokenSource, .enteredToken)
        XCTAssertTrue(result?.discoveryWouldSupplyDifferentToken == true)
        let presentation = OpenClawConnectionTestPresentation(
            result: XCTUnwrapOrFail(result)
        )
        XCTAssertEqual(
            presentation.message,
            "Connected to OpenClaw (gateway 2026.7.1-2) using the token you entered."
        )
        XCTAssertEqual(presentation.tone, .success)
        XCTAssertNil(presentation.recoveryActionTitle)
    }

    func testSuccessReportsDiscoveredPairingSourceAndNamesItInCopy() {
        for source in [
            OpenClawGatewayTokenSource.secretsDirectory,
            OpenClawGatewayTokenSource.secretsJSON
        ] {
            let result = runTest(
                messages: [
                    connectChallenge(nonce: "nonce-1"),
                    successfulHelloResponse
                ],
                resolution: OpenClawGatewayTokenResolution(
                    token: "discovered-token",
                    source: source
                ),
                discoveredToken: "discovered-token"
            )

            XCTAssertEqual(result?.tokenSource, source)
            XCTAssertFalse(
                result?.discoveryWouldSupplyDifferentToken == true,
                "Discovery supplied this very token, so it is not an alternative."
            )
            XCTAssertEqual(
                OpenClawConnectionTestPresentation(
                    result: XCTUnwrapOrFail(result)
                ).message,
                "Connected to OpenClaw (gateway 2026.7.1-2) using this Mac's OpenClaw pairing."
            )
        }
    }

    func testRejectedEnteredTokenWithDiscoveryOffersRemovalRecovery() {
        let result = runTest(
            messages: [
                connectChallenge(nonce: "nonce-1"),
                gatewayTokenMismatchResponse
            ],
            resolution: OpenClawGatewayTokenResolution(
                token: "stale-entered-token",
                source: .enteredToken
            ),
            discoveredToken: "working-discovered-token"
        )

        XCTAssertEqual(result?.outcome, .gatewayTokenMismatch)
        let presentation = OpenClawConnectionTestPresentation(
            result: XCTUnwrapOrFail(result)
        )
        XCTAssertEqual(
            presentation.message,
            """
            OpenClaw rejected the token you entered. Remove it and VoiceKey will \
            use this Mac's OpenClaw pairing instead.
            """
        )
        XCTAssertEqual(presentation.tone, .failure)
        XCTAssertEqual(
            presentation.recoveryActionTitle,
            "Use This Mac's Pairing"
        )
    }

    func testRejectedEnteredTokenWithoutDiscoveryOffersNoRecovery() {
        let result = runTest(
            messages: [
                connectChallenge(nonce: "nonce-1"),
                gatewayTokenMismatchResponse
            ],
            resolution: OpenClawGatewayTokenResolution(
                token: "stale-entered-token",
                source: .enteredToken
            ),
            discoveredToken: nil
        )

        let presentation = OpenClawConnectionTestPresentation(
            result: XCTUnwrapOrFail(result)
        )
        XCTAssertEqual(
            presentation.message,
            """
            OpenClaw rejected the token you entered. Check it, or remove it and \
            pair this Mac with OpenClaw.
            """
        )
        XCTAssertNil(presentation.recoveryActionTitle)
    }

    func testRejectedDiscoveredPairingPointsAtRepairing() {
        let result = runTest(
            messages: [
                connectChallenge(nonce: "nonce-1"),
                gatewayTokenMismatchResponse
            ],
            resolution: OpenClawGatewayTokenResolution(
                token: "discovered-token",
                source: .secretsJSON
            ),
            discoveredToken: "discovered-token"
        )

        let presentation = OpenClawConnectionTestPresentation(
            result: XCTUnwrapOrFail(result)
        )
        XCTAssertEqual(
            presentation.message,
            """
            OpenClaw rejected this Mac's pairing. Re-pair this Mac in OpenClaw, \
            then try again.
            """
        )
        XCTAssertNil(presentation.recoveryActionTitle)
    }

    func testNoTokenAnywhereReportsNoSourceAndPromptsForOne() {
        let tester = OpenClawConnectionTester(
            tokenResolutionProvider: { nil },
            discoveredTokenProvider: { nil },
            deviceCredentialsProvider: { nil },
            webSocketFactory: { _ in
                XCTFail("A test without a token must not open a socket.")
                return ConnectionTesterFakeWebSocket(messages: [])
            },
            watchdogScheduler: { _, _ in ConnectionTesterWatchdog() }
        )
        let completed = expectation(description: "missing token reported")
        var received: OpenClawConnectionTestResult?
        tester.testConnection(
            endpointURL: "ws://127.0.0.1:18790"
        ) { (result: OpenClawConnectionTestResult) in
            received = result
            completed.fulfill()
        }
        wait(for: [completed], timeout: 1)

        XCTAssertEqual(received?.outcome, .gatewayTokenMissing)
        XCTAssertNil(received?.tokenSource)
        let presentation = OpenClawConnectionTestPresentation(
            result: XCTUnwrapOrFail(received)
        )
        XCTAssertEqual(
            presentation.message,
            "No gateway token found — paste one, or pair this Mac with OpenClaw."
        )
        XCTAssertNil(presentation.recoveryActionTitle)
    }

    func testTestOutcomeCopyNeverContainsATokenValue() {
        let entered = "ENTERED-TOKEN-VALUE"
        let discovered = "DISCOVERED-TOKEN-VALUE"
        for messages in [
            [connectChallenge(nonce: "n"), successfulHelloResponse],
            [connectChallenge(nonce: "n"), gatewayTokenMismatchResponse],
            [connectChallenge(nonce: "n"), gatewayTokenMissingResponse]
        ] {
            let result = runTest(
                messages: messages,
                resolution: OpenClawGatewayTokenResolution(
                    token: entered,
                    source: .enteredToken
                ),
                discoveredToken: discovered
            )
            let presentation = OpenClawConnectionTestPresentation(
                result: XCTUnwrapOrFail(result)
            )
            XCTAssertFalse(presentation.message.contains(entered))
            XCTAssertFalse(presentation.message.contains(discovered))
        }
    }

    // MARK: - Helpers

    private func runTest(
        messages: [String],
        resolution: OpenClawGatewayTokenResolution,
        discoveredToken: String?
    ) -> OpenClawConnectionTestResult? {
        let factory = ConnectionTesterWebSocketFactory(
            sockets: [ConnectionTesterFakeWebSocket(messages: messages)]
        )
        let tester = makeTester(
            factory: factory,
            resolution: resolution,
            discoveredToken: discoveredToken
        )
        let completed = expectation(description: "test finished")
        var received: OpenClawConnectionTestResult?
        tester.testConnection(
            endpointURL: "ws://127.0.0.1:18790"
        ) { (result: OpenClawConnectionTestResult) in
            received = result
            completed.fulfill()
        }
        wait(for: [completed], timeout: 1)
        return received
    }

    private func XCTUnwrapOrFail(
        _ result: OpenClawConnectionTestResult?
    ) -> OpenClawConnectionTestResult {
        guard let result else {
            XCTFail("Expected a connection test result.")
            return OpenClawConnectionTestResult(outcome: .gatewayTokenMissing)
        }
        return result
    }

    private func makeTester(
        factory: ConnectionTesterWebSocketFactory,
        resolution: OpenClawGatewayTokenResolution = OpenClawGatewayTokenResolution(
            token: "gateway-token",
            source: .enteredToken
        ),
        discoveredToken: String? = nil
    ) -> OpenClawConnectionTester {
        OpenClawConnectionTester(
            tokenResolutionProvider: { resolution },
            discoveredTokenProvider: { discoveredToken },
            deviceCredentialsProvider: {
                OpenClawDeviceCredentials(
                    deviceID: "device-1",
                    publicKey: Data(repeating: 0x11, count: 32),
                    privateKeySeed: Data(
                        repeating: 0x22,
                        count: 32
                    ),
                    operatorToken: "stale-device-token",
                    operatorScopes: ["operator.read"]
                )
            },
            webSocketFactory: factory.makeSocket,
            watchdogScheduler: { _, _ in
                ConnectionTesterWatchdog()
            },
            now: {
                Date(timeIntervalSince1970: 1_784_300_000)
            }
        )
    }
}

private let deviceTokenMismatchResponse = """
    {"type":"res","id":"1","ok":false,"error":{"code":"INVALID_REQUEST",\
    "message":"unauthorized: device token mismatch",\
    "details":{"code":"AUTH_DEVICE_TOKEN_MISMATCH"}}}
    """

private let gatewayTokenMismatchResponse = """
    {"type":"res","id":"1","ok":false,"error":{"code":"INVALID_REQUEST",\
    "message":"unauthorized: gateway token mismatch (provide gateway auth token)",\
    "details":{"code":"AUTH_TOKEN_MISMATCH","authReason":"token_mismatch"}}}
    """

private let gatewayTokenMissingResponse = """
    {"type":"res","id":"1","ok":false,"error":{"code":"INVALID_REQUEST",\
    "message":"unauthorized: gateway token missing (provide gateway auth token)",\
    "details":{"code":"AUTH_TOKEN_MISSING","authReason":"token_missing"}}}
    """

private let successfulHelloResponse = """
    {"type":"res","id":"1","result":{"type":"hello-ok","protocol":4,\
    "server":{"version":"2026.7.1-2"},\
    "auth":{"role":"operator","scopes":["operator.read"]}}}
    """

private func connectChallenge(nonce: String) -> String {
    """
    {"type":"event","event":"connect.challenge",\
    "payload":{"nonce":"\(nonce)","ts":1}}
    """
}

private final class ConnectionTesterWebSocketFactory {
    private let lock = NSLock()
    private var sockets: [ConnectionTesterFakeWebSocket]
    private var requests: [URL] = []

    init(sockets: [ConnectionTesterFakeWebSocket]) {
        self.sockets = sockets
    }

    var requestedURLs: [URL] {
        lock.withLock { requests }
    }

    func makeSocket(request: URLRequest) -> OpenClawTalkWebSocket {
        lock.withLock {
            if let url = request.url {
                requests.append(url)
            }
            return sockets.removeFirst()
        }
    }
}

private final class ConnectionTesterFakeWebSocket:
    OpenClawTalkWebSocket {
    var onOpen: (() -> Void)?
    var onClose: ((URLSessionWebSocketTask.CloseCode) -> Void)?

    private let lock = NSLock()
    private var messages: [URLSessionWebSocketTask.Message]
    private var frames: [[String: Any]] = []

    init(messages: [String]) {
        self.messages = messages.map(
            URLSessionWebSocketTask.Message.string
        )
    }

    var sentFrames: [[String: Any]] {
        lock.withLock { frames }
    }

    func resume() {
        onOpen?()
    }

    func receive(
        completionHandler: @escaping (
            Result<URLSessionWebSocketTask.Message, Error>
        ) -> Void
    ) {
        let message = lock.withLock {
            messages.isEmpty ? nil : messages.removeFirst()
        }
        if let message {
            completionHandler(.success(message))
        }
    }

    func send(
        _ message: URLSessionWebSocketTask.Message,
        completionHandler: @escaping (Error?) -> Void
    ) {
        if case let .string(text) = message,
           let data = text.data(using: .utf8),
           let frame = try? JSONSerialization
            .jsonObject(with: data) as? [String: Any] {
            lock.withLock {
                frames.append(frame)
            }
        }
        completionHandler(nil)
    }

    func cancel(
        with closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {}

    func invalidateAndCancel() {}
}

private final class ConnectionTesterWatchdog:
    OpenClawTalkWatchdogCancellation {
    func cancel() {}
}
