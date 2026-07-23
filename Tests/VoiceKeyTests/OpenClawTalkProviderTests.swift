@testable import VoiceKey
import Foundation
import XCTest

final class OpenClawTalkProviderTests: XCTestCase {
    // MARK: - Endpoint candidates

    func testEndpointCandidatesDefaultToTunnelThenLocalGateway() {
        XCTAssertEqual(
            OpenClawTalkRequestBuilder.endpointCandidates(endpointURL: ""),
            ["ws://127.0.0.1:18790", "ws://127.0.0.1:18789"]
        )
        XCTAssertEqual(
            OpenClawTalkRequestBuilder.endpointCandidates(endpointURL: "  \n"),
            ["ws://127.0.0.1:18790", "ws://127.0.0.1:18789"]
        )
    }

    func testEndpointCandidatesPreferConfiguredEndpoint() {
        XCTAssertEqual(
            OpenClawTalkRequestBuilder.endpointCandidates(endpointURL: "wss://gateway.example.com"),
            ["wss://gateway.example.com", "ws://127.0.0.1:18790", "ws://127.0.0.1:18789"]
        )
    }

    func testEndpointCandidatesDeduplicateConfiguredDefault() {
        XCTAssertEqual(
            OpenClawTalkRequestBuilder.endpointCandidates(endpointURL: "ws://127.0.0.1:18790"),
            ["ws://127.0.0.1:18790", "ws://127.0.0.1:18789"]
        )
    }

    func testEndpointCandidatesNormalizeHTTPSchemes() {
        XCTAssertEqual(
            OpenClawTalkRequestBuilder.endpointCandidates(endpointURL: "https://gateway.example.com"),
            ["wss://gateway.example.com", "ws://127.0.0.1:18790", "ws://127.0.0.1:18789"]
        )
        XCTAssertEqual(
            OpenClawTalkRequestBuilder.endpointCandidates(endpointURL: "http://gateway.local:9000"),
            ["ws://gateway.local:9000", "ws://127.0.0.1:18790", "ws://127.0.0.1:18789"]
        )
    }

    func testWebSocketRequestUsesRootPathWithoutSubprotocolAndShortTimeout() throws {
        let request = try XCTUnwrap(OpenClawTalkRequestBuilder.webSocketRequest(
            endpoint: "ws://127.0.0.1:18790"
        ))

        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.scheme, "ws")
        XCTAssertEqual(url.host, "127.0.0.1")
        XCTAssertEqual(url.port, 18790)
        XCTAssertEqual(url.path, "")
        XCTAssertNil(request.value(forHTTPHeaderField: "Sec-WebSocket-Protocol"))
        XCTAssertEqual(request.timeoutInterval, 3)
    }

    // MARK: - Frame encoding

    func testConnectFrameMatchesGatewayHandshakeContract() throws {
        let frame = OpenClawTalkRequestBuilder.connectFrame(token: "secret-token", clientVersion: "1.2.3")

        XCTAssertEqual(frame["type"] as? String, "req")
        XCTAssertEqual(frame["id"] as? String, "1")
        XCTAssertEqual(frame["method"] as? String, "connect")

        let params = try dictionary(frame["params"])
        XCTAssertEqual(params["minProtocol"] as? Int, 1)
        XCTAssertEqual(params["maxProtocol"] as? Int, 4)
        XCTAssertEqual(params["role"] as? String, "operator")
        XCTAssertEqual(params["scopes"] as? [String], [
            "operator.admin", "operator.talk", "operator.write", "operator.read"
        ])

        let client = try dictionary(params["client"])
        XCTAssertEqual(client["id"] as? String, "openclaw-macos")
        XCTAssertEqual(client["version"] as? String, "1.2.3")
        XCTAssertEqual(client["platform"] as? String, "macos")
        XCTAssertEqual(client["mode"] as? String, "backend")

        let auth = try dictionary(params["auth"])
        XCTAssertEqual(auth["token"] as? String, "secret-token")
    }

    func testSessionCreateFrameMatchesTalkContract() throws {
        let frame = OpenClawTalkRequestBuilder.sessionCreateFrame()

        XCTAssertEqual(frame["type"] as? String, "req")
        XCTAssertEqual(frame["id"] as? String, "2")
        XCTAssertEqual(frame["method"] as? String, "talk.session.create")

        let params = try dictionary(frame["params"])
        XCTAssertEqual(params["sessionKey"] as? String, "agent:main:voicekey")
        XCTAssertEqual(params["mode"] as? String, "realtime")
        XCTAssertEqual(params["transport"] as? String, "gateway-relay")
        XCTAssertEqual(params["brain"] as? String, "agent-consult")
    }

    func testAppendAudioFrameCorrelatesIDAndBase64EncodesPCM() throws {
        let frame = OpenClawTalkRequestBuilder.appendAudioFrame(
            id: "7",
            sessionID: "session-1",
            audio: Data([0x01, 0x02, 0x03])
        )

        XCTAssertEqual(frame["type"] as? String, "req")
        XCTAssertEqual(frame["id"] as? String, "7")
        XCTAssertEqual(frame["method"] as? String, "talk.session.appendAudio")

        let params = try dictionary(frame["params"])
        XCTAssertEqual(params["sessionId"] as? String, "session-1")
        XCTAssertEqual(params["audioBase64"] as? String, "AQID")
        XCTAssertNil(params["timestamp"])
    }

    func testCancelOutputFrameUsesUserInterruptedReason() throws {
        let frame = OpenClawTalkRequestBuilder.cancelOutputFrame(id: "8", sessionID: "session-1")

        XCTAssertEqual(frame["method"] as? String, "talk.session.cancelOutput")
        let params = try dictionary(frame["params"])
        XCTAssertEqual(params["sessionId"] as? String, "session-1")
        XCTAssertEqual(params["reason"] as? String, "user-interrupted")
    }

    func testCloseFrameShape() throws {
        let frame = OpenClawTalkRequestBuilder.closeFrame(id: "9", sessionID: "session-1")

        XCTAssertEqual(frame["method"] as? String, "talk.session.close")
        let params = try dictionary(frame["params"])
        XCTAssertEqual(params["sessionId"] as? String, "session-1")
    }

    // MARK: - Handshake mapping

    func testConnectChallengeMapsToChallengeAction() {
        let frame = #"{"type":"event","event":"connect.challenge","payload":{"nonce":"abc","ts":1}}"#

        XCTAssertEqual(
            OpenClawTalkEventMapper.actions(from: frame, sessionID: nil),
            [
                .connectChallenge,
                .providerEvent(.diagnostic("OpenClaw gateway connect challenge received."))
            ]
        )
    }

    func testConnectHelloOKMapsToConnected() {
        let frame = #"{"type":"res","id":"1","ok":true,"payload":{"type":"hello-ok","protocol":4}}"#

        XCTAssertEqual(
            OpenClawTalkEventMapper.actions(from: frame, sessionID: nil),
            [
                .connected,
                .providerEvent(.diagnostic("Connected to OpenClaw gateway."))
            ]
        )
    }

    func testConnectErrorMapsToHandshakeFailed() {
        let frame = #"{"type":"res","id":"1","ok":false,"error":{"code":"unauthorized","message":"Invalid gateway token.","retryable":false}}"#

        XCTAssertEqual(
            OpenClawTalkEventMapper.actions(from: frame, sessionID: nil),
            [.handshakeFailed(message: "Invalid gateway token.")]
        )
    }

    func testSessionCreateResponseMapsToSessionCreated() {
        let frame = #"{"type":"res","id":"2","ok":true,"payload":{"sessionId":"session-1","relaySessionId":"session-1","audio":{"format":"pcm16","sampleRate":24000}}}"#

        XCTAssertEqual(
            OpenClawTalkEventMapper.actions(from: frame, sessionID: nil),
            [
                .sessionCreated(sessionID: "session-1"),
                .providerEvent(.diagnostic("OpenClaw talk session created."))
            ]
        )
    }

    func testSessionCreateResponseWithoutSessionIDMapsToHandshakeFailed() {
        let frame = #"{"type":"res","id":"2","ok":true,"payload":{}}"#

        XCTAssertEqual(
            OpenClawTalkEventMapper.actions(from: frame, sessionID: nil),
            [.handshakeFailed(message: "OpenClaw gateway did not return a talk session id.")]
        )
    }

    func testSessionCreateErrorMapsToHandshakeFailed() {
        let frame = #"{"type":"res","id":"2","ok":false,"error":{"code":"unavailable","message":"Talk is disabled."}}"#

        XCTAssertEqual(
            OpenClawTalkEventMapper.actions(from: frame, sessionID: nil),
            [.handshakeFailed(message: "Talk is disabled.")]
        )
    }

    func testAppendAudioAckIsIgnored() {
        let frame = #"{"type":"res","id":"7","ok":true,"payload":{"ok":true}}"#
        XCTAssertEqual(OpenClawTalkEventMapper.actions(from: frame, sessionID: "session-1"), [])
    }

    func testAppendAudioErrorMapsToDiagnostic() {
        let frame = #"{"type":"res","id":"7","ok":false,"error":{"code":"bad-audio","message":"Audio rejected."}}"#

        XCTAssertEqual(
            OpenClawTalkEventMapper.actions(from: frame, sessionID: "session-1"),
            [.providerEvent(.diagnostic("OpenClaw request 7 failed: Audio rejected."))]
        )
    }

    // MARK: - Relay envelope mapping

    func testReadyEnvelopeMapsToSessionReady() {
        let frame = talkEventFrame(#"{"relaySessionId":"session-1","type":"ready","talkEvent":{"type":"session.ready","payload":{}}}"#)

        XCTAssertEqual(
            OpenClawTalkEventMapper.actions(from: frame, sessionID: "session-1"),
            [
                .sessionReady,
                .providerEvent(.diagnostic("OpenClaw talk session ready."))
            ]
        )
    }

    func testEnvelopeForAnotherSessionIsIgnored() {
        let frame = talkEventFrame(#"{"relaySessionId":"other-session","type":"ready","talkEvent":{"type":"session.ready","payload":{}}}"#)

        XCTAssertEqual(OpenClawTalkEventMapper.actions(from: frame, sessionID: "session-1"), [])
    }

    func testEnvelopeBeforeSessionCreateIsIgnored() {
        let frame = talkEventFrame(#"{"relaySessionId":"session-1","type":"ready"}"#)

        XCTAssertEqual(OpenClawTalkEventMapper.actions(from: frame, sessionID: nil), [])
    }

    func testInputAudioEnvelopeIsIgnored() {
        let frame = talkEventFrame(#"{"relaySessionId":"session-1","type":"inputAudio","talkEvent":{"type":"input.audio","payload":{"byteLength":9600}}}"#)

        XCTAssertEqual(OpenClawTalkEventMapper.actions(from: frame, sessionID: "session-1"), [])
    }

    func testAudioEnvelopePlaysEnvelopeBytesAndMapsToSpeaking() {
        let audio = Data([0x01, 0x02, 0x03, 0x04])
        let envelope = #"{"relaySessionId":"session-1","type":"audio","audioBase64":"\#(audio.base64EncodedString())","talkEvent":{"type":"output.audio","payload":{"byteLength":4}}}"#
        let frame = talkEventFrame(envelope)

        XCTAssertEqual(
            OpenClawTalkEventMapper.actions(from: frame, sessionID: "session-1"),
            [
                .audio(audio),
                .providerEvent(.status(.speaking))
            ]
        )
    }

    func testAudioDoneEnvelopeMapsToListening() {
        let frame = talkEventFrame(#"{"relaySessionId":"session-1","type":"audioDone"}"#)

        XCTAssertEqual(
            OpenClawTalkEventMapper.actions(from: frame, sessionID: "session-1"),
            [.providerEvent(.status(.listening))]
        )
    }

    func testClearEnvelopeFlushesPlaybackAndMapsToListening() {
        let frame = talkEventFrame(#"{"relaySessionId":"session-1","type":"clear","talkEvent":{"type":"output.audio.done","payload":{"reason":"clear"}}}"#)

        XCTAssertEqual(
            OpenClawTalkEventMapper.actions(from: frame, sessionID: "session-1"),
            [
                .stopPlayback,
                .providerEvent(.status(.listening))
            ]
        )
    }

    func testFinalUserTranscriptMapsToListeningAndPrefixedTranscript() {
        let frame = talkEventFrame(#"{"relaySessionId":"session-1","type":"transcript","role":"user","text":"hello there","final":true,"talkEvent":{"type":"transcript.done","payload":{"role":"user","text":"hello there"}}}"#)

        XCTAssertEqual(
            OpenClawTalkEventMapper.actions(from: frame, sessionID: "session-1"),
            [
                .providerEvent(.status(.listening)),
                .providerEvent(.transcript("You: hello there"))
            ]
        )
    }

    func testUserTranscriptDeltaMapsToListeningOnly() {
        let frame = talkEventFrame(#"{"relaySessionId":"session-1","type":"transcript","role":"user","text":"hel","final":false,"talkEvent":{"type":"transcript.delta","payload":{"role":"user","text":"hel"}}}"#)

        XCTAssertEqual(
            OpenClawTalkEventMapper.actions(from: frame, sessionID: "session-1"),
            [.providerEvent(.status(.listening))]
        )
    }

    func testAssistantOutputTextDeltaMapsToTranscript() {
        let frame = talkEventFrame(#"{"relaySessionId":"session-1","type":"transcript","talkEvent":{"type":"output.text.delta","payload":{"text":"Hi"}}}"#)

        XCTAssertEqual(
            OpenClawTalkEventMapper.actions(from: frame, sessionID: "session-1"),
            [.providerEvent(.transcript("Hi"))]
        )
    }

    func testAssistantOutputTextDoneIsIgnored() {
        let frame = talkEventFrame(#"{"relaySessionId":"session-1","type":"transcript","talkEvent":{"type":"output.text.done","payload":{"text":"Hi there"}}}"#)

        XCTAssertEqual(OpenClawTalkEventMapper.actions(from: frame, sessionID: "session-1"), [])
    }

    func testErrorEnvelopeMapsToNeedsAttention() {
        let frame = talkEventFrame(#"{"relaySessionId":"session-1","type":"error","code":"stt-failed","message":"Speech recognition failed.","phase":"input"}"#)

        XCTAssertEqual(
            OpenClawTalkEventMapper.actions(from: frame, sessionID: "session-1"),
            [.providerEvent(.status(.needsAttention("Speech recognition failed.")))]
        )
    }

    func testCloseEnvelopeMapsToSessionClosedWithReason() {
        let frame = talkEventFrame(#"{"relaySessionId":"session-1","type":"close","reason":"user-hangup","talkEvent":{"type":"session.closed","payload":{"reason":"user-hangup"}}}"#)

        XCTAssertEqual(
            OpenClawTalkEventMapper.actions(from: frame, sessionID: "session-1"),
            [.sessionClosed(reason: "user-hangup")]
        )
    }

    func testToolEnvelopesMapToDiagnostic() {
        let frame = talkEventFrame(#"{"relaySessionId":"session-1","type":"toolCall","talkEvent":{"type":"tool.call","payload":{"name":"search"}}}"#)

        XCTAssertEqual(
            OpenClawTalkEventMapper.actions(from: frame, sessionID: "session-1"),
            [.providerEvent(.diagnostic("talk.event.toolCall"))]
        )
    }

    func testNonTalkEventFramesAreIgnored() {
        for event in ["health", "tick", "agent", "chat", "heartbeat"] {
            let frame = #"{"type":"event","event":"\#(event)","payload":{}}"#
            XCTAssertEqual(OpenClawTalkEventMapper.actions(from: frame, sessionID: "session-1"), [])
        }
    }

    func testMalformedFramesAreIgnored() {
        XCTAssertEqual(OpenClawTalkEventMapper.actions(from: "not json", sessionID: "session-1"), [])
        XCTAssertEqual(OpenClawTalkEventMapper.actions(from: "{}", sessionID: "session-1"), [])
        XCTAssertEqual(OpenClawTalkEventMapper.actions(from: #"{"type":"event"}"#, sessionID: "session-1"), [])
    }

    // MARK: - Token resolution

    func testTokenResolutionPrefersKeychainOverSecretsFile() throws {
        let secrets = try makeSecretsDirectory()
        try writeSecretsFile("sparta-gateway-token", contents: "file-token", in: secrets)

        XCTAssertEqual(
            OpenClawTokenResolver.resolveGatewayToken(
                apiKeyProvider: { "  keychain-token\n" },
                secretsDirectory: secrets
            ),
            "keychain-token"
        )
    }

    func testTokenResolutionFallsBackToSecretsFile() throws {
        let secrets = try makeSecretsDirectory()
        try writeSecretsFile("sparta-gateway-token", contents: "  file-token\n\n", in: secrets)

        XCTAssertEqual(
            OpenClawTokenResolver.resolveGatewayToken(
                apiKeyProvider: { nil },
                secretsDirectory: secrets
            ),
            "file-token"
        )
    }

    func testTokenResolutionPicksFirstGatewayTokenFileSortedByName() throws {
        let secrets = try makeSecretsDirectory()
        try writeSecretsFile("b-gateway-token", contents: "token-b", in: secrets)
        try writeSecretsFile("a-gateway-token", contents: "token-a", in: secrets)
        try writeSecretsFile("unrelated.txt", contents: "not-a-token", in: secrets)

        XCTAssertEqual(
            OpenClawTokenResolver.resolveGatewayToken(
                apiKeyProvider: { nil },
                secretsDirectory: secrets
            ),
            "token-a"
        )
    }

    func testTokenResolutionSkipsEmptyAndNonRegularFiles() throws {
        let secrets = try makeSecretsDirectory()
        try writeSecretsFile("a-gateway-token", contents: "  \n", in: secrets)
        try FileManager.default.createDirectory(
            at: secrets.appendingPathComponent("dir-gateway-token", isDirectory: true),
            withIntermediateDirectories: true
        )
        try writeSecretsFile("z-gateway-token", contents: "token-z", in: secrets)

        XCTAssertEqual(
            OpenClawTokenResolver.resolveGatewayToken(
                apiKeyProvider: { nil },
                secretsDirectory: secrets
            ),
            "token-z"
        )
    }

    func testTokenResolutionReturnsNilWhenNothingIsAvailable() throws {
        let secrets = try makeSecretsDirectory()
        XCTAssertNil(
            OpenClawTokenResolver.resolveGatewayToken(
                apiKeyProvider: { nil },
                secretsDirectory: secrets
            )
        )

        let missing = secrets.appendingPathComponent("does-not-exist", isDirectory: true)
        XCTAssertNil(
            OpenClawTokenResolver.resolveGatewayToken(
                apiKeyProvider: { nil },
                secretsDirectory: missing
            )
        )
    }

    // MARK: - Provider metadata

    func testOpenClawProviderMetadata() {
        let openClaw = VoiceProviderID.openClaw
        XCTAssertEqual(openClaw.rawValue, "openClaw")
        XCTAssertEqual(openClaw.displayName, "OpenClaw Talk")
        XCTAssertTrue(openClaw.isImplemented)
        XCTAssertFalse(openClaw.requiresAPIKey)
        XCTAssertEqual(openClaw.credentialLabel, "Gateway Token (optional)")
        XCTAssertTrue(openClaw.supportsEndpointSetting)
        XCTAssertEqual(openClaw.endpointPlaceholder, "ws://127.0.0.1:18790 (auto)")
        XCTAssertFalse(openClaw.usesRealtimeWebSocket)
        XCTAssertFalse(openClaw.supportsModelSetting)
        XCTAssertFalse(openClaw.supportsVoiceSetting)
        XCTAssertEqual(openClaw.defaultModel, "")
        XCTAssertEqual(openClaw.defaultVoice, "")
        XCTAssertTrue(openClaw.voiceOptions.isEmpty)
    }

    func testOpenClawProviderIsReadyWithOrWithoutStoredToken() {
        XCTAssertEqual(VoiceProviderID.openClaw.readiness(hasAPIKey: false), .ready)
        XCTAssertEqual(VoiceProviderID.openClaw.readiness(hasAPIKey: true), .ready)
    }

    func testOpenClawCredentialViewStateAcceptsOptionalToken() {
        let withoutKey = VoiceProviderCredentialViewState(provider: .openClaw, hasAPIKey: false)
        XCTAssertTrue(withoutKey.acceptsAPIKeyInput)
        XCTAssertFalse(withoutKey.canRemoveAPIKey)

        let withKey = VoiceProviderCredentialViewState(provider: .openClaw, hasAPIKey: true)
        XCTAssertTrue(withKey.acceptsAPIKeyInput)
        XCTAssertTrue(withKey.canRemoveAPIKey)
    }

    func testOpenClawProviderIDCodableRoundTrip() throws {
        let data = try JSONEncoder().encode(VoiceProviderID.openClaw)
        XCTAssertEqual(String(data: data, encoding: .utf8), "\"openClaw\"")
        XCTAssertEqual(try JSONDecoder().decode(VoiceProviderID.self, from: data), .openClaw)
    }

    func testFactoryReturnsOpenClawTalkProvider() {
        let provider = VoiceProviderFactory.makeProvider(
            for: VoiceProviderID.openClaw.defaultConfiguration,
            apiKeyStore: APIKeyStore()
        )

        XCTAssertTrue(provider is OpenClawTalkProvider)
        XCTAssertEqual(provider.id, .openClaw)
        XCTAssertTrue(provider.capabilities.supportsInterruptions)
        XCTAssertTrue(provider.capabilities.supportsProviderInterface)
        XCTAssertFalse(provider.capabilities.supportsConnectionCheck)
    }

    // MARK: - Provider behavior

    func testPrepareWithoutTokenEmitsNeedsAttention() {
        let provider = OpenClawTalkProvider(
            configuration: testConfiguration,
            tokenProvider: { nil },
            audioEngine: FakeOpenClawAudioEngine()
        )

        let attention = expectation(description: "needs attention")
        provider.onEvent = { event in
            guard case let .status(.needsAttention(message)) = event else { return }
            XCTAssertEqual(message, "OpenClaw gateway token not found — paste it in Settings")
            attention.fulfill()
        }

        provider.prepare()
        waitForExpectations(timeout: 1)
    }

    func testPrepareWithTokenEmitsReady() {
        let provider = OpenClawTalkProvider(
            configuration: testConfiguration,
            tokenProvider: { "token" },
            audioEngine: FakeOpenClawAudioEngine()
        )

        let ready = expectation(description: "ready")
        provider.onEvent = { event in
            guard case .status(.ready) = event else { return }
            ready.fulfill()
        }

        provider.prepare()
        waitForExpectations(timeout: 1)
    }

    func testToggleWithoutTokenEmitsNeedsAttentionAndSkipsMicrophone() {
        let audioEngine = FakeOpenClawAudioEngine()
        let provider = OpenClawTalkProvider(
            configuration: testConfiguration,
            tokenProvider: { nil },
            audioEngine: audioEngine
        )

        let attention = expectation(description: "needs attention")
        provider.onEvent = { event in
            guard case .status(.needsAttention) = event else { return }
            attention.fulfill()
        }

        provider.toggleVoice()
        waitForExpectations(timeout: 1)
        XCTAssertEqual(audioEngine.microphoneAccessRequestCount, 0)
    }

    func testToggleWhileStartIsPendingStopsInsteadOfStartingAgain() {
        let audioEngine = FakeOpenClawAudioEngine()
        let provider = OpenClawTalkProvider(
            configuration: testConfiguration,
            tokenProvider: { "token" },
            audioEngine: audioEngine
        )

        provider.toggleVoice()
        provider.toggleVoice()

        XCTAssertEqual(audioEngine.microphoneAccessRequestCount, 1)
        XCTAssertEqual(audioEngine.stopCount, 1)
    }

    // MARK: - Helpers

    private var testConfiguration: VoiceSessionConfiguration {
        VoiceSessionConfiguration(
            providerID: .openClaw,
            model: "",
            voice: "",
            instructions: "",
            endpointURL: ""
        )
    }

    private func talkEventFrame(_ envelope: String) -> String {
        #"{"type":"event","event":"talk.event","payload":\#(envelope)}"#
    }

    private func makeSecretsDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceKeyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func writeSecretsFile(_ name: String, contents: String, in directory: URL) throws {
        try contents.write(
            to: directory.appendingPathComponent(name),
            atomically: true,
            encoding: .utf8
        )
    }

    private func dictionary(_ value: Any?, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        try XCTUnwrap(value as? [String: Any], file: file, line: line)
    }
}

private final class FakeOpenClawAudioEngine: RealtimeAudioEngineProtocol {
    private(set) var microphoneAccessRequestCount = 0
    private(set) var stopCount = 0

    func requestMicrophoneAccess(_ completion: @escaping (Bool) -> Void) {
        microphoneAccessRequestCount += 1
    }

    func start(
        inputHandler: @escaping (Data) -> Void,
        activityHandler: @escaping (RealtimeAudioInputActivity) -> Void
    ) throws {}

    func stop() {
        stopCount += 1
    }

    func stopPlayback() {}

    func playPCM16(_ data: Data) {}
}
