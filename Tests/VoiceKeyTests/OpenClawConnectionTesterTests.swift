@testable import VoiceKey
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
}
