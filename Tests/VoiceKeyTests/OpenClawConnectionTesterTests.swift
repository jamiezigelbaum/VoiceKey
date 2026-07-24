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

    private func makeTester(
        factory: ConnectionTesterWebSocketFactory
    ) -> OpenClawConnectionTester {
        OpenClawConnectionTester(
            tokenProvider: { "gateway-token" },
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
