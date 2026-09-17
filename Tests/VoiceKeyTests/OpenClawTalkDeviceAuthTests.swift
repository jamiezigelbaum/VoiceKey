@testable import VoiceKey
import CryptoKit
import Foundation
import XCTest

/// Coverage for the paired-device connect handshake: signature payload format,
/// base64url encoding, Ed25519 signing (RFC 8032 vector), PEM identity parsing,
/// the device-auth token store, and the NOT_PAIRED scope-retry mapping.
final class OpenClawTalkDeviceAuthTests: XCTestCase {
    // MARK: - Signature payload

    func testSignaturePayloadMatchesGatewayCanonicalFormat() {
        let payload = OpenClawConnectSigner.signaturePayload(
            deviceID: "device-1",
            clientID: "openclaw-macos",
            clientMode: "backend",
            role: "operator",
            scopes: ["operator.read", "operator.write"],
            signedAtMs: 1_784_300_000_000,
            token: "gateway-token",
            nonce: "nonce-1"
        )

        XCTAssertEqual(
            payload,
            "v2|device-1|openclaw-macos|backend|operator|operator.read,operator.write|1784300000000|gateway-token|nonce-1"
        )
    }

    func testSignaturePayloadJoinsEmptyScopesAndKeepsEmptyFields() {
        let payload = OpenClawConnectSigner.signaturePayload(
            deviceID: "device-1",
            clientID: "openclaw-macos",
            clientMode: "backend",
            role: "operator",
            scopes: [],
            signedAtMs: 7,
            token: "",
            nonce: "n"
        )

        XCTAssertEqual(payload, "v2|device-1|openclaw-macos|backend|operator||7||n")
    }

    // MARK: - base64url

    func testBase64URLEncodeReplacesAlphabetAndDropsPadding() {
        // Standard base64 of these bytes is "+/++" (three bytes, no padding).
        XCTAssertEqual(OpenClawConnectSigner.base64URLEncode(Data([0xFB, 0xFF, 0xBE])), "-_--")
        // Two bytes exercise the stripped padding: standard base64 is "+/0=".
        XCTAssertEqual(OpenClawConnectSigner.base64URLEncode(Data([0xFB, 0xFD])), "-_0")
        XCTAssertEqual(OpenClawConnectSigner.base64URLEncode(Data()), "")
    }

    // MARK: - Ed25519 signing

    func testSignMatchesRFC8032TestVector() throws {
        // RFC 8032 Ed25519 TEST 1.
        let seed = try Data(hexString: "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
        let expectedPublicKey = try Data(hexString: "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
        let rfcSignature = try Data(hexString: """
            e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155\
            5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b
            """)

        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        XCTAssertEqual(key.publicKey.rawRepresentation, expectedPublicKey)
        XCTAssertTrue(key.publicKey.isValidSignature(rfcSignature, for: Data()))

        // CryptoKit randomizes Ed25519 signing nonces (a side-channel
        // countermeasure), so its signatures are never byte-equal to the
        // RFC's deterministic one; they must still verify against the key.
        let signatureBase64 = try XCTUnwrap(OpenClawConnectSigner.sign(payload: "", privateKeySeed: seed))
        var base64 = signatureBase64
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        let signature = try XCTUnwrap(Data(base64Encoded: base64))
        XCTAssertTrue(key.publicKey.isValidSignature(signature, for: Data()))
    }

    func testSignVerifiesAgainstRawPublicKeyAndRejectsBadSeed() throws {
        let seed = Data((0..<32).map { UInt8($0) })
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)

        let signatureBase64 = try XCTUnwrap(OpenClawConnectSigner.sign(
            payload: "v2|d|c|m|r|s|1|t|n",
            privateKeySeed: seed
        ))
        // base64url → standard base64 for decoding.
        var base64 = signatureBase64
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        let rawSignature = try XCTUnwrap(Data(base64Encoded: base64))
        XCTAssertTrue(key.publicKey.isValidSignature(rawSignature, for: Data("v2|d|c|m|r|s|1|t|n".utf8)))
        XCTAssertFalse(key.publicKey.isValidSignature(rawSignature, for: Data("v2|tampered".utf8)))

        XCTAssertNil(OpenClawConnectSigner.sign(payload: "x", privateKeySeed: Data([0x01, 0x02])))
    }

    // MARK: - PEM identity parsing

    func testPEMParsingExtractsRawEd25519Keys() throws {
        let publicKeyRaw = Data((0..<32).map { UInt8(200 - $0) })
        let seedRaw = Data((0..<32).map { UInt8($0 + 10) })
        let device = makeDeviceJSON(publicKeyRaw: publicKeyRaw, seedRaw: seedRaw)

        XCTAssertEqual(
            OpenClawDeviceIdentityStore.ed25519PublicKey(fromPEM: device.publicKeyPEM),
            publicKeyRaw
        )
        XCTAssertEqual(
            OpenClawDeviceIdentityStore.ed25519PrivateSeed(fromPEM: device.privateKeyPEM),
            seedRaw
        )
    }

    func testPEMParsingAcceptsLineWrappedAndCRLFBodies() throws {
        let publicKeyRaw = Data(repeating: 0xAB, count: 32)
        let seedRaw = Data(repeating: 0xCD, count: 32)
        var device = makeDeviceJSON(publicKeyRaw: publicKeyRaw, seedRaw: seedRaw)
        // Wrap the base64 body at 16 columns with CRLF line endings.
        device.publicKeyPEM = wrapPEM(device.publicKeyPEM, column: 16, lineEnding: "\r\n")
        device.privateKeyPEM = wrapPEM(device.privateKeyPEM, column: 16, lineEnding: "\r\n")

        XCTAssertEqual(OpenClawDeviceIdentityStore.ed25519PublicKey(fromPEM: device.publicKeyPEM), publicKeyRaw)
        XCTAssertEqual(OpenClawDeviceIdentityStore.ed25519PrivateSeed(fromPEM: device.privateKeyPEM), seedRaw)
    }

    func testPEMParsingRejectsWrongDERShapes() {
        // Not an Ed25519 SPKI/PKCS8 prefix.
        let bogus = "-----BEGIN PUBLIC KEY-----\n\(Data(repeating: 0x00, count: 44).base64EncodedString())\n-----END PUBLIC KEY-----"
        XCTAssertNil(OpenClawDeviceIdentityStore.ed25519PublicKey(fromPEM: bogus))
        XCTAssertNil(OpenClawDeviceIdentityStore.ed25519PrivateSeed(fromPEM: bogus))
        XCTAssertNil(OpenClawDeviceIdentityStore.ed25519PublicKey(fromPEM: "not a pem"))
    }

    // MARK: - Credential loading

    func testLoadCredentialsReadsPairedDeviceStore() throws {
        let directory = try makeIdentityDirectory()
        let publicKeyRaw = Data(repeating: 0x11, count: 32)
        let seedRaw = Data(repeating: 0x22, count: 32)
        try writeDeviceFiles(
            in: directory,
            deviceID: "device-abc",
            publicKeyRaw: publicKeyRaw,
            seedRaw: seedRaw,
            operatorToken: "  op-token\n",
            operatorScopes: ["operator.read", "operator.write"]
        )

        XCTAssertEqual(
            OpenClawDeviceIdentityStore.loadCredentials(identityDirectory: directory),
            OpenClawDeviceCredentials(
                deviceID: "device-abc",
                publicKey: publicKeyRaw,
                privateKeySeed: seedRaw,
                operatorToken: "op-token",
                operatorScopes: ["operator.read", "operator.write"]
            )
        )
    }

    func testLoadCredentialsRejectsDeviceIDMismatch() throws {
        let directory = try makeIdentityDirectory()
        let device = makeDeviceJSON(publicKeyRaw: Data(repeating: 0x11, count: 32), seedRaw: Data(repeating: 0x22, count: 32))
        try writeJSON(
            ["deviceId": "device-abc", "publicKeyPem": device.publicKeyPEM, "privateKeyPem": device.privateKeyPEM],
            named: "device.json",
            in: directory
        )
        try writeJSON(
            [
                "version": 1,
                "deviceId": "some-other-device",
                "tokens": ["operator": ["token": "op-token", "role": "operator", "scopes": ["operator.write"], "updatedAtMs": 1]]
            ],
            named: "device-auth.json",
            in: directory
        )

        XCTAssertNil(OpenClawDeviceIdentityStore.loadCredentials(identityDirectory: directory))
    }

    func testLoadCredentialsReturnsNilWithoutFilesOrOperatorToken() throws {
        let empty = try makeIdentityDirectory()
        XCTAssertNil(OpenClawDeviceIdentityStore.loadCredentials(identityDirectory: empty))
        XCTAssertNil(OpenClawDeviceIdentityStore.loadCredentials(
            identityDirectory: empty.appendingPathComponent("missing", isDirectory: true)
        ))

        let directory = try makeIdentityDirectory()
        try writeDeviceFiles(
            in: directory,
            deviceID: "device-abc",
            publicKeyRaw: Data(repeating: 0x11, count: 32),
            seedRaw: Data(repeating: 0x22, count: 32),
            operatorToken: "  \n",
            operatorScopes: []
        )
        XCTAssertNil(OpenClawDeviceIdentityStore.loadCredentials(identityDirectory: directory))
    }

    // MARK: - Signed connect frame

    func testSignedConnectFrameMatchesGatewayContract() throws {
        let proof = OpenClawDeviceProof(
            deviceID: "device-1",
            publicKeyBase64URL: "pub",
            signatureBase64URL: "sig",
            signedAtMs: 1_784_300_000_000,
            nonce: "nonce-1"
        )
        let frame = OpenClawTalkRequestBuilder.connectFrame(
            token: "gateway-token",
            clientVersion: "0.2.0",
            scopes: ["operator.write"],
            deviceToken: "device-token",
            deviceProof: proof
        )

        XCTAssertEqual(frame["type"] as? String, "req")
        XCTAssertEqual(frame["id"] as? String, "1")
        XCTAssertEqual(frame["method"] as? String, "connect")

        let params = try XCTUnwrap(frame["params"] as? [String: Any])
        XCTAssertEqual(params["minProtocol"] as? Int, 1)
        XCTAssertEqual(params["maxProtocol"] as? Int, 4)
        XCTAssertEqual(params["role"] as? String, "operator")
        XCTAssertEqual(params["scopes"] as? [String], ["operator.write"])

        let client = try XCTUnwrap(params["client"] as? [String: Any])
        XCTAssertEqual(client["id"] as? String, "openclaw-macos")
        XCTAssertEqual(client["mode"] as? String, "backend")
        XCTAssertEqual(client["platform"] as? String, "macos")
        XCTAssertEqual(client["version"] as? String, "0.2.0")

        let device = try XCTUnwrap(params["device"] as? [String: Any])
        XCTAssertEqual(device["id"] as? String, "device-1")
        XCTAssertEqual(device["publicKey"] as? String, "pub")
        XCTAssertEqual(device["signature"] as? String, "sig")
        XCTAssertEqual(device["signedAt"] as? Int64, 1_784_300_000_000)
        XCTAssertEqual(device["nonce"] as? String, "nonce-1")

        let auth = try XCTUnwrap(params["auth"] as? [String: Any])
        XCTAssertEqual(auth["token"] as? String, "gateway-token")
        XCTAssertEqual(auth["deviceToken"] as? String, "device-token")
    }

    func testSignedConnectFrameSerializesToJSON() {
        let frame = OpenClawTalkRequestBuilder.connectFrame(
            token: "gateway-token",
            clientVersion: "0.2.0",
            scopes: ["operator.write"],
            deviceToken: "device-token",
            deviceProof: OpenClawDeviceProof(
                deviceID: "device-1",
                publicKeyBase64URL: "pub",
                signatureBase64URL: "sig",
                signedAtMs: 42,
                nonce: "nonce-1"
            )
        )

        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: frame))
    }

    // MARK: - Challenge nonce extraction

    func testConnectChallengeNonceExtraction() {
        let frame = #"{"type":"event","event":"connect.challenge","payload":{"nonce":"abc-123","ts":1}}"#
        XCTAssertEqual(OpenClawTalkEventMapper.connectChallengeNonce(from: frame), "abc-123")

        XCTAssertNil(OpenClawTalkEventMapper.connectChallengeNonce(from: "not json"))
        XCTAssertNil(OpenClawTalkEventMapper.connectChallengeNonce(from: #"{"type":"event","event":"talk.event","payload":{}}"#))
        XCTAssertNil(OpenClawTalkEventMapper.connectChallengeNonce(from: #"{"type":"event","event":"connect.challenge","payload":{}}"#))
    }

    func testConnectChallengeActionShapeIsUnchanged() {
        let frame = #"{"type":"event","event":"connect.challenge","payload":{"nonce":"abc","ts":1}}"#
        XCTAssertEqual(
            OpenClawTalkEventMapper.actions(from: frame, sessionID: nil),
            [
                .connectChallenge,
                .providerEvent(.diagnostic("OpenClaw gateway connect challenge received."))
            ]
        )
    }

    // MARK: - NOT_PAIRED scope retry mapping

    func testNotPairedConnectErrorMapsToScopeRetry() {
        let frame = #"{"type":"res","id":"1","ok":false,"error":{"code":"NOT_PAIRED","message":"pairing required: device identity changed and must be re-approved","details":{"code":"PAIRING_REQUIRED","approvedScopes":["operator.write"]}}}"#

        XCTAssertEqual(
            OpenClawTalkEventMapper.actions(from: frame, sessionID: nil),
            [.connectRetryWithScopes(
                scopes: ["operator.write"],
                reason: nil,
                requestID: nil,
                remediationHint: nil,
                message: "pairing required: device identity changed and must be re-approved"
            )]
        )
    }

    func testPairingRequiredDetailsCodeAloneMapsToScopeRetry() {
        let frame = #"{"type":"res","id":"1","ok":false,"error":{"code":"INVALID_REQUEST","message":"pairing required","details":{"code":"PAIRING_REQUIRED","approvedScopes":["operator.read","operator.write"]}}}"#

        XCTAssertEqual(
            OpenClawTalkEventMapper.actions(from: frame, sessionID: nil),
            [.connectRetryWithScopes(
                scopes: ["operator.read", "operator.write"],
                reason: nil,
                requestID: nil,
                remediationHint: nil,
                message: "pairing required"
            )]
        )
    }

    func testNotPairedWithoutApprovedScopesCarriesPairingDetails() {
        let frame = #"{"type":"res","id":"1","ok":false,"error":{"code":"NOT_PAIRED","message":"pairing required: unknown device","details":{"code":"PAIRING_REQUIRED"}}}"#

        XCTAssertEqual(
            OpenClawTalkEventMapper.actions(from: frame, sessionID: nil),
            [.pairingRequired(
                reason: nil,
                requestID: nil,
                remediationHint: nil,
                message: "pairing required: unknown device"
            )]
        )
    }

    func testSignedConnectFrameCanOmitStaleDeviceToken() throws {
        let frame = OpenClawTalkRequestBuilder.connectFrame(
            token: "gateway-token",
            clientVersion: "0.2.0",
            scopes: ["operator.write"],
            deviceToken: nil,
            deviceProof: OpenClawDeviceProof(
                deviceID: "device-1",
                publicKeyBase64URL: "pub",
                signatureBase64URL: "sig",
                signedAtMs: 42,
                nonce: "nonce-1"
            )
        )

        let params = try XCTUnwrap(frame["params"] as? [String: Any])
        let auth = try XCTUnwrap(params["auth"] as? [String: Any])
        XCTAssertEqual(auth["token"] as? String, "gateway-token")
        XCTAssertNil(auth["deviceToken"])
        XCTAssertNotNil(params["device"])
    }

    func testMissingScopeSessionCreateErrorIncludesPairingHint() {
        let frame = #"{"type":"res","id":"2","ok":false,"error":{"code":"INVALID_REQUEST","message":"missing scope: operator.write"}}"#

        XCTAssertEqual(
            OpenClawTalkEventMapper.actions(from: frame, sessionID: nil),
            [.handshakeFailed(message: """
                missing scope: operator.write — the gateway token alone has no talk scopes; \
                pair this Mac with OpenClaw (CLI/app) or use a scoped token
                """)]
        )
    }

    // MARK: - Helpers

    private func makeIdentityDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceKeyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func makeDeviceJSON(
        publicKeyRaw: Data,
        seedRaw: Data
    ) -> (publicKeyPEM: String, privateKeyPEM: String) {
        let spkiPrefix = Data([0x30, 0x2A, 0x30, 0x05, 0x06, 0x03, 0x2B, 0x65, 0x70, 0x03, 0x21, 0x00])
        let pkcs8Prefix = Data([0x30, 0x2E, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2B, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20])
        let publicKeyPEM = "-----BEGIN PUBLIC KEY-----\n"
            + (spkiPrefix + publicKeyRaw).base64EncodedString()
            + "\n-----END PUBLIC KEY-----"
        let privateKeyPEM = "-----BEGIN PRIVATE KEY-----\n"
            + (pkcs8Prefix + seedRaw).base64EncodedString()
            + "\n-----END PRIVATE KEY-----"
        return (publicKeyPEM, privateKeyPEM)
    }

    private func wrapPEM(_ pem: String, column: Int, lineEnding: String) -> String {
        var lines = pem.split(separator: "\n").map(String.init)
        guard lines.count >= 3 else { return pem }
        let body = lines[1...].dropLast().joined()
        var wrapped: [String] = []
        var index = body.startIndex
        while index < body.endIndex {
            let end = body.index(index, offsetBy: column, limitedBy: body.endIndex) ?? body.endIndex
            wrapped.append(String(body[index..<end]))
            index = end
        }
        lines = [lines[0]] + wrapped + [lines[lines.count - 1]]
        return lines.joined(separator: lineEnding)
    }

    private func writeDeviceFiles(
        in directory: URL,
        deviceID: String,
        publicKeyRaw: Data,
        seedRaw: Data,
        operatorToken: String,
        operatorScopes: [String]
    ) throws {
        let device = makeDeviceJSON(publicKeyRaw: publicKeyRaw, seedRaw: seedRaw)
        try writeJSON(
            ["version": 1, "deviceId": deviceID, "publicKeyPem": device.publicKeyPEM, "privateKeyPem": device.privateKeyPEM],
            named: "device.json",
            in: directory
        )
        try writeJSON(
            [
                "version": 1,
                "deviceId": deviceID,
                "tokens": [
                    "operator": [
                        "token": operatorToken,
                        "role": "operator",
                        "scopes": operatorScopes,
                        "updatedAtMs": 1
                    ]
                ]
            ],
            named: "device-auth.json",
            in: directory
        )
    }

    private func writeJSON(_ object: [String: Any], named name: String, in directory: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: directory.appendingPathComponent(name))
    }
}

private extension Data {
    struct HexDecodingError: Error {}

    init(hexString: String) throws {
        var data = Data()
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else {
                throw HexDecodingError()
            }
            data.append(byte)
            index = next
        }
        self = data
    }
}
