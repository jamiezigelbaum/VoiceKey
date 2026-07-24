import AppKit
import CryptoKit
import Foundation

struct OpenClawTalkToolCall: Equatable {
    var name: String
    var callID: String
    var argumentsJSON: String

    func decodedArguments() -> Any? {
        try? JSONSerialization.jsonObject(
            with: Data(argumentsJSON.utf8),
            options: [.fragmentsAllowed]
        )
    }
}

enum OpenClawTalkEventAction: Equatable {
    case providerEvent(VoiceProviderEvent)
    case connectChallenge
    case connected
    case sessionCreated(sessionID: String, relaySessionID: String)
    case sessionReady
    case audio(Data)
    case assistantTurnEnded
    case stopPlayback
    case sessionClosed(reason: String?)
    case handshakeFailed(message: String)
    case toolCall(OpenClawTalkToolCall)
    case malformedToolCall(callID: String?, reason: String)
    case requestSucceeded(id: String, runID: String?)
    case requestFailed(id: String, message: String)
    case chatLifecycle(runID: String?, state: String?, text: String?, errorMessage: String?)
    case consultToolProgress(runID: String?, phase: String?, toolName: String?)
    /// The gateway rejected connect as NOT_PAIRED because the requested scopes
    /// exceed the device's approved set; it closes the socket (1008), so the
    /// provider must reconnect and retry with exactly these approved scopes.
    case connectRetryWithScopes(scopes: [String], message: String)
}

enum OpenClawTalkRequestBuilder {
    static let connectRequestID = "1"
    static let sessionCreateRequestID = "2"
    // Must be a chat session key the gateway can resolve (format
    // agent:<agent>:<session>); the consult runs against this session's
    // agent and memory. agent:main:voicekey is VoiceKey's DEDICATED lane on
    // the main agent (created 2026-07-24): same workspace/memory/tools, but
    // isolated from agent:main:main, which other operator threads keep busy —
    // consults sharing that session collided with concurrent runs and came
    // back as instant empty finals while the real answer landed later.
    static let sessionKey = "agent:main:voicekey"
    static let clientID = "openclaw-macos"
    static let clientMode = "backend"
    static let role = "operator"
    /// Each endpoint candidate gets a short window so fallback stays snappy.
    static let connectTimeout: TimeInterval = 3
    static let defaultEndpointCandidates = [
        "ws://127.0.0.1:18790", // always-on tunnel to the remote gateway
        "ws://127.0.0.1:18789" // OpenClaw default local gateway port
    ]

    static func endpointCandidates(endpointURL: String) -> [String] {
        var candidates: [String] = []
        let trimmed = endpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty == false {
            candidates.append(normalizedEndpoint(trimmed))
        }
        for endpoint in defaultEndpointCandidates where candidates.contains(endpoint) == false {
            candidates.append(endpoint)
        }
        return candidates
    }

    /// The gateway speaks plain WebSocket at the root path; only the scheme is
    /// normalized (http -> ws, https -> wss). No path is appended.
    static func normalizedEndpoint(_ endpoint: String) -> String {
        let lowercased = endpoint.lowercased()
        if lowercased.hasPrefix("https://") {
            return "wss://" + endpoint.dropFirst("https://".count)
        }
        if lowercased.hasPrefix("http://") {
            return "ws://" + endpoint.dropFirst("http://".count)
        }
        return endpoint
    }

    static func webSocketRequest(endpoint: String) -> URLRequest? {
        guard let url = URL(string: endpoint) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = connectTimeout
        return request
    }

    static func connectFrame(token: String, clientVersion: String) -> [String: Any] {
        [
            "type": "req",
            "id": connectRequestID,
            "method": "connect",
            "params": [
                "minProtocol": 1,
                "maxProtocol": 4,
                "client": [
                    "id": clientID,
                    "version": clientVersion,
                    "platform": "macos",
                    "mode": clientMode,
                    // tool-events: chat.send auto-registers this connection for
                    // per-tool agent events (stream:"tool") on consult runs.
                    "caps": ["tool-events"]
                ],
                "role": role,
                "scopes": ["operator.talk", "operator.write", "operator.read"],
                "auth": ["token": token]
            ]
        ]
    }

    /// Connect frame for a paired device: the gateway grants no scopes to the bare
    /// gateway token, so the device proves its identity by signing the challenge
    /// nonce (see OpenClawConnectSigner) and presents its issued operator token.
    /// `scopes` must not exceed the device's gateway-approved set, otherwise the
    /// gateway answers NOT_PAIRED ("metadata-upgrade") and drops the socket.
    static func connectFrame(
        token: String,
        clientVersion: String,
        scopes: [String],
        deviceToken: String,
        deviceProof: OpenClawDeviceProof
    ) -> [String: Any] {
        [
            "type": "req",
            "id": connectRequestID,
            "method": "connect",
            "params": [
                "minProtocol": 1,
                "maxProtocol": 4,
                "client": [
                    "id": clientID,
                    "version": clientVersion,
                    "platform": "macos",
                    "mode": clientMode,
                    "caps": ["tool-events"]
                ],
                "role": role,
                "scopes": scopes,
                "device": [
                    "id": deviceProof.deviceID,
                    "publicKey": deviceProof.publicKeyBase64URL,
                    "signature": deviceProof.signatureBase64URL,
                    "signedAt": deviceProof.signedAtMs,
                    "nonce": deviceProof.nonce
                ],
                "auth": ["token": token, "deviceToken": deviceToken]
            ]
        ]
    }

    static func sessionCreateFrame() -> [String: Any] {
        [
            "type": "req",
            "id": sessionCreateRequestID,
            "method": "talk.session.create",
            "params": [
                "sessionKey": sessionKey,
                "mode": "realtime",
                "transport": "gateway-relay",
                "brain": "agent-consult"
            ]
        ]
    }

    static func appendAudioFrame(id: String, sessionID: String, audio: Data) -> [String: Any] {
        [
            "type": "req",
            "id": id,
            "method": "talk.session.appendAudio",
            "params": [
                "sessionId": sessionID,
                "audioBase64": audio.base64EncodedString()
            ]
        ]
    }

    static func cancelOutputFrame(id: String, sessionID: String, reason: String = "user-interrupted") -> [String: Any] {
        [
            "type": "req",
            "id": id,
            "method": "talk.session.cancelOutput",
            "params": [
                "sessionId": sessionID,
                "reason": reason
            ]
        ]
    }

    static func clientToolCallFrame(
        id: String,
        relaySessionID: String,
        toolCall: OpenClawTalkToolCall
    ) -> [String: Any]? {
        guard let arguments = toolCall.decodedArguments() else { return nil }
        return [
            "type": "req",
            "id": id,
            "method": "talk.client.toolCall",
            // Schema (gateway channels.ts, additionalProperties:false):
            // sessionKey, callId, name, args?, relaySessionId? — no others.
            // An earlier voiceSessionId here was rejected as INVALID_REQUEST.
            "params": [
                "sessionKey": sessionKey,
                "relaySessionId": relaySessionID,
                "callId": toolCall.callID,
                "name": toolCall.name,
                "args": arguments
            ]
        ]
    }

    static func submitToolResultFrame(
        id: String,
        sessionID: String,
        callID: String,
        result: [String: Any],
        options: [String: Bool]? = nil
    ) -> [String: Any] {
        var params: [String: Any] = [
            "sessionId": sessionID,
            "callId": callID,
            "result": result
        ]
        if let options {
            params["options"] = options
        }
        return [
            "type": "req",
            "id": id,
            "method": "talk.session.submitToolResult",
            "params": params
        ]
    }

    static func closeFrame(id: String, sessionID: String) -> [String: Any] {
        [
            "type": "req",
            "id": id,
            "method": "talk.session.close",
            "params": ["sessionId": sessionID]
        ]
    }
}

/// Resolves the gateway token without ever logging it: a token pasted in Settings
/// (Keychain) wins; otherwise the first `*gateway-token*` file in the OpenClaw
/// secrets directory is used (this machine's sparta-gateway-token lives there).
enum OpenClawTokenResolver {
    static var defaultSecretsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".openclaw/secrets", isDirectory: true)
    }

    static func resolveGatewayToken(
        apiKeyProvider: () -> String?,
        secretsDirectory: URL = defaultSecretsDirectory
    ) -> String? {
        if let key = apiKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines),
           key.isEmpty == false {
            return key
        }
        return gatewayTokenFromSecretsDirectory(secretsDirectory)
    }

    static func gatewayTokenFromSecretsDirectory(_ directory: URL) -> String? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            return nil
        }

        let candidates = files
            .filter { $0.lastPathComponent.contains("gateway-token") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        for file in candidates {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let contents = try? String(contentsOf: file, encoding: .utf8) else {
                continue
            }
            let token = contents.trimmingCharacters(in: .whitespacesAndNewlines)
            if token.isEmpty == false {
                return token
            }
        }
        return nil
    }
}

/// A paired device's proof of identity for one connect attempt: the gateway's
/// challenge nonce signed with the device's Ed25519 private key.
struct OpenClawDeviceProof: Equatable {
    var deviceID: String
    var publicKeyBase64URL: String
    var signatureBase64URL: String
    var signedAtMs: Int64
    var nonce: String
}

/// Builds and signs the gateway's connect payload. The payload format mirrors the
/// OpenClaw client exactly — the gateway recomputes this string and verifies the
/// Ed25519 signature against the device's registered public key:
/// v2|deviceId|clientId|clientMode|role|scope1,scope2|signedAtMs|token|nonce
/// Secrets are inputs only; nothing here logs them.
enum OpenClawConnectSigner {
    static func signaturePayload(
        deviceID: String,
        clientID: String,
        clientMode: String,
        role: String,
        scopes: [String],
        signedAtMs: Int64,
        token: String,
        nonce: String
    ) -> String {
        [
            "v2",
            deviceID,
            clientID,
            clientMode,
            role,
            scopes.joined(separator: ","),
            String(signedAtMs),
            token,
            nonce
        ].joined(separator: "|")
    }

    static func sign(payload: String, privateKeySeed: Data) -> String? {
        guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: privateKeySeed),
              let signature = try? key.signature(for: Data(payload.utf8)) else {
            return nil
        }
        return base64URLEncode(signature)
    }

    /// Unpadded base64url, the encoding the gateway expects for keys/signatures.
    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// The paired-device material the gateway issues via the OpenClaw CLI/app:
/// the device identity plus the operator-scoped device token.
struct OpenClawDeviceCredentials: Equatable {
    var deviceID: String
    /// Raw 32-byte Ed25519 public key.
    var publicKey: Data
    /// Raw 32-byte Ed25519 private key seed.
    var privateKeySeed: Data
    var operatorToken: String
    var operatorScopes: [String]
}

/// Loads the OpenClaw device identity (`device.json`) and the gateway-issued
/// operator device token (`device-auth.json`) from the OpenClaw identity
/// directory. Returns nil when this Mac has not been paired with the gateway;
/// the provider then falls back to the legacy token-only connect.
enum OpenClawDeviceIdentityStore {
    /// DER prefix of an Ed25519 SubjectPublicKeyInfo (RFC 8410): 12 bytes + raw key.
    private static let spkiPrefix = Data([0x30, 0x2A, 0x30, 0x05, 0x06, 0x03, 0x2B, 0x65, 0x70, 0x03, 0x21, 0x00])
    /// DER prefix of an Ed25519 PKCS#8 private key (RFC 8410): 16 bytes + raw seed.
    private static let pkcs8Prefix = Data([0x30, 0x2E, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2B, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20])

    static var defaultIdentityDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".openclaw/identity", isDirectory: true)
    }

    static func loadCredentials(
        identityDirectory: URL = defaultIdentityDirectory
    ) -> OpenClawDeviceCredentials? {
        let deviceURL = identityDirectory.appendingPathComponent("device.json")
        guard let deviceData = try? Data(contentsOf: deviceURL),
              let device = try? JSONSerialization.jsonObject(with: deviceData) as? [String: Any],
              let deviceID = device["deviceId"] as? String,
              deviceID.isEmpty == false,
              let publicKeyPEM = device["publicKeyPem"] as? String,
              let privateKeyPEM = device["privateKeyPem"] as? String,
              let publicKey = ed25519PublicKey(fromPEM: publicKeyPEM),
              let privateKeySeed = ed25519PrivateSeed(fromPEM: privateKeyPEM) else {
            return nil
        }

        // The device-auth store is keyed to one device; a token issued to a
        // different (e.g. rotated) identity must not be presented.
        let authURL = identityDirectory.appendingPathComponent("device-auth.json")
        guard let authData = try? Data(contentsOf: authURL),
              let auth = try? JSONSerialization.jsonObject(with: authData) as? [String: Any],
              (auth["deviceId"] as? String) == deviceID,
              let tokens = auth["tokens"] as? [String: Any],
              let operatorEntry = tokens[OpenClawTalkRequestBuilder.role] as? [String: Any],
              let operatorToken = (operatorEntry["token"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              operatorToken.isEmpty == false else {
            return nil
        }

        let scopes = (operatorEntry["scopes"] as? [String]) ?? []
        return OpenClawDeviceCredentials(
            deviceID: deviceID,
            publicKey: publicKey,
            privateKeySeed: privateKeySeed,
            operatorToken: operatorToken,
            operatorScopes: scopes
        )
    }

    static func ed25519PublicKey(fromPEM pem: String) -> Data? {
        rawKey(fromPEM: pem, derPrefix: spkiPrefix)
    }

    static func ed25519PrivateSeed(fromPEM pem: String) -> Data? {
        rawKey(fromPEM: pem, derPrefix: pkcs8Prefix)
    }

    private static func rawKey(fromPEM pem: String, derPrefix: Data) -> Data? {
        let body = pem
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { $0.hasPrefix("-----") == false }
            .joined()
        guard let der = Data(base64Encoded: body),
              der.count == derPrefix.count + 32,
              der.prefix(derPrefix.count) == derPrefix else {
            return nil
        }
        return der.suffix(32)
    }
}

enum OpenClawTalkEventMapper {
    static func actions(from text: String, sessionID: String?) -> [OpenClawTalkEventAction] {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            return []
        }

        switch type {
        case "res":
            return responseActions(object)
        case "event":
            guard let event = object["event"] as? String else { return [] }
            switch event {
            case "connect.challenge":
                return [
                    .connectChallenge,
                    .providerEvent(.diagnostic("OpenClaw gateway connect challenge received."))
                ]
            case "talk.event":
                guard let envelope = object["payload"] as? [String: Any] else { return [] }
                return talkEnvelopeActions(envelope, sessionID: sessionID)
            case "chat":
                let payload = object["payload"] as? [String: Any]
                return [
                    .chatLifecycle(
                        runID: payload?["runId"] as? String,
                        state: payload?["state"] as? String,
                        text: chatMessageText(payload?["message"]),
                        errorMessage: payload?["errorMessage"] as? String
                    )
                ]
            case "agent":
                // Per-tool progress for consult runs (requires the
                // "tool-events" connect cap). Wire shape verified against
                // gateway source v2026.7.1: payload {runId, stream:"tool",
                // data:{phase, name, toolCallId}}.
                guard let payload = object["payload"] as? [String: Any],
                      payload["stream"] as? String == "tool" else { return [] }
                let data = payload["data"] as? [String: Any]
                return [
                    .consultToolProgress(
                        runID: payload["runId"] as? String,
                        phase: data?["phase"] as? String,
                        toolName: data?["name"] as? String
                    )
                ]
            default:
                // health/tick/heartbeat frames are not talk traffic.
                return []
            }
        default:
            return []
        }
    }

    /// Extracts the challenge nonce the connect signature is computed over.
    /// Separate from `actions(from:sessionID:)` so the `.connectChallenge`
    /// action shape (and existing callers) stay unchanged.
    static func connectChallengeNonce(from text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "event",
              object["event"] as? String == "connect.challenge",
              let payload = object["payload"] as? [String: Any] else {
            return nil
        }
        return payload["nonce"] as? String
    }

    private static func responseActions(_ object: [String: Any]) -> [OpenClawTalkEventAction] {
        guard let id = object["id"] as? String else {
            return [.providerEvent(.diagnostic("OpenClaw response omitted a request id."))]
        }

        guard (object["ok"] as? Bool) == true else {
            let error = object["error"] as? [String: Any]
            let message = error?["message"] as? String ?? "OpenClaw gateway request failed."
            switch id {
            case OpenClawTalkRequestBuilder.connectRequestID:
                // The gateway rejects over-broad scope requests as NOT_PAIRED and
                // reports the device's approved scope set; the provider reconnects
                // and retries with exactly those scopes.
                if let approvedScopes = approvedScopesForPairingRetry(error: error) {
                    return [.connectRetryWithScopes(scopes: approvedScopes, message: message)]
                }
                return [.handshakeFailed(message: message)]
            case OpenClawTalkRequestBuilder.sessionCreateRequestID:
                if message.hasPrefix("missing scope") {
                    // Reached only via the legacy token-only connect (no paired
                    // device credentials): the bare gateway token carries no scopes.
                    return [.handshakeFailed(message: """
                        \(message) — the gateway token alone has no talk scopes; \
                        pair this Mac with OpenClaw (CLI/app) or use a scoped token
                        """)]
                }
                return [.handshakeFailed(message: message)]
            default:
                return [.requestFailed(id: id, message: message)]
            }
        }

        switch id {
        case OpenClawTalkRequestBuilder.connectRequestID:
            return [
                .connected,
                .providerEvent(.diagnostic("Connected to OpenClaw gateway."))
            ]
        case OpenClawTalkRequestBuilder.sessionCreateRequestID:
            let payload = object["payload"] as? [String: Any]
            guard let sessionID = (payload?["sessionId"] as? String) ?? (payload?["relaySessionId"] as? String) else {
                return [.handshakeFailed(message: "OpenClaw gateway did not return a talk session id.")]
            }
            let relaySessionID = (payload?["relaySessionId"] as? String) ?? sessionID
            return [
                .sessionCreated(sessionID: sessionID, relaySessionID: relaySessionID),
                .providerEvent(.diagnostic("OpenClaw talk session created."))
            ]
        default:
            let payload = object["payload"] as? [String: Any]
            let runID = (payload?["runId"] as? String) ?? (payload?["idempotencyKey"] as? String)
            return [.requestSucceeded(id: id, runID: runID)]
        }
    }

    /// NOT_PAIRED (details.code PAIRING_REQUIRED) carries the device's
    /// gateway-approved scopes in details.approvedScopes; retrying connect with
    /// exactly that set pairs without user action. Anything else (e.g. unknown
    /// device) needs manual approval, so no retry is offered.
    private static func approvedScopesForPairingRetry(error: [String: Any]?) -> [String]? {
        guard let error else { return nil }
        let details = error["details"] as? [String: Any]
        let isPairingRetry = (error["code"] as? String) == "NOT_PAIRED"
            || (details?["code"] as? String) == "PAIRING_REQUIRED"
        guard isPairingRetry,
              let approvedScopes = details?["approvedScopes"] as? [String],
              approvedScopes.isEmpty == false else {
            return nil
        }
        return approvedScopes
    }

    private static func talkEnvelopeActions(_ envelope: [String: Any], sessionID: String?) -> [OpenClawTalkEventAction] {
        guard let sessionID else {
            return []
        }
        guard let relaySessionID = envelope["relaySessionId"] as? String else {
            return [.providerEvent(.diagnostic("OpenClaw talk event omitted a relay session id."))]
        }
        guard relaySessionID == sessionID else { return [] }
        guard let envelopeType = envelope["type"] as? String else {
            return [.providerEvent(.diagnostic("OpenClaw talk event omitted its type."))]
        }

        let talkEvent = envelope["talkEvent"] as? [String: Any]
        let talkEventType = talkEvent?["type"] as? String
        let talkEventPayload = talkEvent?["payload"] as? [String: Any]

        switch envelopeType {
        case "ready":
            return [
                .sessionReady,
                .providerEvent(.diagnostic("OpenClaw talk session ready."))
            ]
        case "inputAudio":
            return []
        case "audio":
            // Assistant audio bytes live on the relay envelope itself; the nested
            // talkEvent payload only carries {byteLength}.
            guard let base64 = envelope["audioBase64"] as? String,
                  let audio = Data(base64Encoded: base64) else {
                return []
            }
            return [
                .audio(audio),
                .providerEvent(.status(.speaking))
            ]
        case "audioDone":
            return [
                .assistantTurnEnded,
                .providerEvent(.status(.listening))
            ]
        case "clear":
            // Barge-in side-effect: flush queued playback immediately.
            return [
                .stopPlayback,
                .providerEvent(.status(.listening))
            ]
        case "transcript":
            return transcriptActions(
                envelope: envelope,
                talkEventType: talkEventType,
                talkEventPayload: talkEventPayload
            )
        case "toolCall":
            return toolCallActions(envelope: envelope, talkEventPayload: talkEventPayload)
        case "close":
            let reason = (envelope["reason"] as? String) ?? (talkEventPayload?["reason"] as? String)
            return [.sessionClosed(reason: reason)]
        case "error":
            let message = envelope["message"] as? String ?? "OpenClaw talk session error."
            return [.providerEvent(.status(.needsAttention(message)))]
        default:
            return [.providerEvent(.diagnostic("talk.event.\(envelopeType)"))]
        }
    }

    private static func toolCallActions(
        envelope: [String: Any],
        talkEventPayload: [String: Any]?
    ) -> [OpenClawTalkEventAction] {
        let callID = ((envelope["callId"] as? String) ?? (talkEventPayload?["callId"] as? String))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = ((envelope["name"] as? String) ?? (talkEventPayload?["name"] as? String))?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let name, name.isEmpty == false else {
            return [
                .malformedToolCall(
                    callID: callID?.isEmpty == false ? callID : nil,
                    reason: "OpenClaw tool call omitted its tool name."
                )
            ]
        }
        guard let callID, callID.isEmpty == false else {
            return [
                .malformedToolCall(
                    callID: nil,
                    reason: "OpenClaw tool call \(diagnosticToolName(name)) omitted its call id."
                )
            ]
        }

        let rawArguments = envelope["args"] ?? talkEventPayload?["args"] ?? [String: Any]()
        guard let argumentsJSON = normalizedArgumentsJSON(rawArguments) else {
            return [
                .malformedToolCall(
                    callID: callID,
                    reason: "OpenClaw tool call \(diagnosticToolName(name)) had malformed arguments."
                )
            ]
        }

        return [
            .toolCall(OpenClawTalkToolCall(
                name: name,
                callID: callID,
                argumentsJSON: argumentsJSON
            )),
            .providerEvent(.diagnostic(
                "OpenClaw tool call \(diagnosticToolName(name)) received."
            ))
        ]
    }

    private static func normalizedArgumentsJSON(_ rawArguments: Any) -> String? {
        let object: Any
        if let string = rawArguments as? String {
            guard let data = string.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(
                    with: data,
                    options: [.fragmentsAllowed]
                  ) else {
                return nil
            }
            object = parsed
        } else {
            object = rawArguments
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .fragmentsAllowed]
        ) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func diagnosticToolName(_ name: String) -> String {
        let withoutControls = name
            .components(separatedBy: .controlCharacters)
            .joined(separator: "?")
        return "'\(withoutControls.prefix(80))'"
    }

    private static func chatMessageText(_ message: Any?) -> String? {
        guard let message = message as? [String: Any] else { return nil }
        if let text = message["text"] as? String,
           text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return text
        }
        guard let content = message["content"] as? [Any] else { return nil }
        let text = content.compactMap { entry -> String? in
            guard let block = entry as? [String: Any] else { return nil }
            guard block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }.joined(separator: "\n\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    private static func transcriptActions(
        envelope: [String: Any],
        talkEventType: String?,
        talkEventPayload: [String: Any]?
    ) -> [OpenClawTalkEventAction] {
        // Assistant text arrives as output.text.delta/done with {text} and no role.
        // Only deltas are surfaced; done repeats the full text.
        if let talkEventType, talkEventType.hasPrefix("output.text") {
            guard talkEventType == "output.text.delta",
                  let text = (envelope["text"] as? String) ?? (talkEventPayload?["text"] as? String),
                  text.isEmpty == false else {
                return []
            }
            return [.providerEvent(.transcript(text))]
        }

        // User transcripts carry {role: "user", text, final} on the envelope, with the
        // nested talkEvent typed transcript.delta/done.
        let isFinal = (envelope["final"] as? Bool) ?? (talkEventType == "transcript.done")
        guard isFinal,
              let text = (envelope["text"] as? String) ?? (talkEventPayload?["text"] as? String),
              text.isEmpty == false else {
            return [.providerEvent(.status(.listening))]
        }
        let role = (envelope["role"] as? String) ?? (talkEventPayload?["role"] as? String)
        let prefix = role == "user" ? "You: " : ""
        return [
            .providerEvent(.status(.listening)),
            .providerEvent(.transcript(prefix + text))
        ]
    }
}

protocol OpenClawTalkWebSocket: AnyObject {
    var onOpen: (() -> Void)? { get set }
    var onClose: ((URLSessionWebSocketTask.CloseCode) -> Void)? { get set }

    func resume()
    func receive(
        completionHandler: @escaping (Result<URLSessionWebSocketTask.Message, Error>) -> Void
    )
    func send(
        _ message: URLSessionWebSocketTask.Message,
        completionHandler: @escaping (Error?) -> Void
    )
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
    func invalidateAndCancel()
}

final class OpenClawTalkURLSessionWebSocket: NSObject, OpenClawTalkWebSocket {
    var onOpen: (() -> Void)? {
        get {
            handlerLock.lock()
            defer { handlerLock.unlock() }
            return openHandler
        }
        set {
            handlerLock.lock()
            openHandler = newValue
            handlerLock.unlock()
        }
    }
    var onClose: ((URLSessionWebSocketTask.CloseCode) -> Void)? {
        get {
            handlerLock.lock()
            defer { handlerLock.unlock() }
            return closeHandler
        }
        set {
            handlerLock.lock()
            closeHandler = newValue
            handlerLock.unlock()
        }
    }

    private let request: URLRequest
    private let handlerLock = NSLock()
    private var openHandler: (() -> Void)?
    private var closeHandler: ((URLSessionWebSocketTask.CloseCode) -> Void)?
    private lazy var session = URLSession(
        configuration: .default,
        delegate: self,
        delegateQueue: nil
    )
    private lazy var task = session.webSocketTask(with: request)

    init(request: URLRequest) {
        self.request = request
    }

    func resume() {
        task.resume()
    }

    func receive(
        completionHandler: @escaping (Result<URLSessionWebSocketTask.Message, Error>) -> Void
    ) {
        task.receive(completionHandler: completionHandler)
    }

    func send(
        _ message: URLSessionWebSocketTask.Message,
        completionHandler: @escaping (Error?) -> Void
    ) {
        task.send(message, completionHandler: completionHandler)
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        task.cancel(with: closeCode, reason: reason)
    }

    func invalidateAndCancel() {
        session.invalidateAndCancel()
    }
}

extension OpenClawTalkURLSessionWebSocket: URLSessionWebSocketDelegate {
    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        guard webSocketTask === task else { return }
        onOpen?()
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        guard webSocketTask === task else { return }
        onClose?(closeCode)
    }
}

protocol OpenClawTalkWatchdogCancellation: AnyObject {
    func cancel()
}

extension DispatchWorkItem: OpenClawTalkWatchdogCancellation {}

typealias OpenClawTalkWebSocketFactory = (URLRequest) -> OpenClawTalkWebSocket
typealias OpenClawTalkWatchdogScheduler = (
    TimeInterval,
    @escaping () -> Void
) -> OpenClawTalkWatchdogCancellation

final class OpenClawTalkProvider: NSObject, RealtimeVoiceProvider {
    let id: VoiceProviderID = .openClaw
    let capabilities = VoiceProviderCapabilities(
        supportsSpeechToSpeech: true,
        supportsTextInput: false,
        supportsInterruptions: true,
        supportsFunctionCalling: true,
        supportsVisionInput: false,
        supportsProviderInterface: true,
        supportsConnectionCheck: false
    )

    var onEvent: ((VoiceProviderEvent) -> Void)? {
        get {
            withStateSync { eventHandler }
        }
        set {
            withStateSync { eventHandler = newValue }
        }
    }

    private static let openClawBundleID = "ai.openclaw.mac"
    private static let missingTokenMessage = "OpenClaw gateway token not found — paste it in Settings"
    private static let unreachableMessage = "OpenClaw gateway unreachable — is the tunnel/OpenClaw running?"
    /// ~200 ms of PCM16 mono 24 kHz, the chunk size the gateway relay expects.
    private static let audioChunkByteCount = 9_600
    private static let handshakeTimeout: TimeInterval = 3
    /// Heavy agent tools (source_answer over the Olympus plugin, deep web
    /// research) routinely exceed 60s; a 60s ceiling killed a Telegram query
    /// on 2026-07-23 while the agent was still working. The watchdog exists
    /// to unstick a dead gateway, not to cap honest work, so it sits well
    /// above the slowest observed real consult.
    private static let consultTimeout: TimeInterval = 180
    /// Emit a reassurance diagnostic when a consult is still running at this
    /// point, so a long wait is visibly progress rather than a hang.
    private static let consultProgressInterval: TimeInterval = 45
    private static let agentConsultToolName = "openclaw_agent_consult"
    private static let confirmationMarker = "VOICE_CONFIRMATION_REQUIRED:"

    private enum HandshakePhase: Equatable {
        case awaitingSocketOpen
        case awaitingChallenge
        case awaitingHello
        case awaitingSessionCreated

        var diagnosticDescription: String {
            switch self {
            case .awaitingSocketOpen:
                return "the WebSocket to open"
            case .awaitingChallenge:
                return "connect.challenge"
            case .awaitingHello:
                return "hello-ok"
            case .awaitingSessionCreated:
                return "talk.session.create"
            }
        }
    }

    private struct ConsultState {
        var callID: String
        var startRequestID: String
        var runID: String?
        var submitRequestID: String?
    }

    private let stateQueue = DispatchQueue(label: "VoiceKey.OpenClawTalkProvider.state")
    private let stateQueueKey = DispatchSpecificKey<Void>()
    private var eventHandler: ((VoiceProviderEvent) -> Void)?
    private var configuration: VoiceSessionConfiguration
    private let tokenProvider: () -> String?
    private let audioEngineFactory: () -> RealtimeAudioEngineProtocol
    private var instantiatedAudioEngine: RealtimeAudioEngineProtocol?
    private var audioEngine: RealtimeAudioEngineProtocol {
        if let instantiatedAudioEngine {
            return instantiatedAudioEngine
        }
        let engine = audioEngineFactory()
        engine.setFatalFailureHandler { [weak self] in
            self?.performOnStateQueue { [weak self] in
                self?.handleFatalAudioFailure()
            }
        }
        engine.setStateChangeHandler { [weak self] state in
            self?.performOnStateQueue { [weak self] in
                self?.adoptAudioEngineState(state)
            }
        }
        audioEngineState = engine.stateSnapshot()
        instantiatedAudioEngine = engine
        return engine
    }
    private let webSocketFactory: OpenClawTalkWebSocketFactory
    private let watchdogScheduler: OpenClawTalkWatchdogScheduler
    private let gateNow: () -> Date
    private var webSocket: OpenClawTalkWebSocket?
    private var handshakeWatchdog: OpenClawTalkWatchdogCancellation?
    private var handshakeWatchdogGeneration = 0
    private var handshakePhase: HandshakePhase?
    private var consultWatchdog: OpenClawTalkWatchdogCancellation?
    private var consultWatchdogGeneration = 0
    private var consultState: ConsultState?
    private var startGeneration = 0
    private var isStarting = false
    private var isConnecting = false
    private var isConnected = false
    private var hasConnectedToGateway = false
    private var isAudioStreaming = false
    private var isStopping = false
    private var isSpeaking = false
    private var hasCancelledOutput = false
    private var audioEngineState: RealtimeAudioEngineState?
    private var speakerGate = OpenAIRealtimeSpeakerGate()
    private var hasReportedAECFallback = false
    private var hasReportedMicrophoneAudio = false
    private var hasReportedMicrophoneSignal = false
    private var endpointCandidates: [String] = []
    private var endpointCandidateIndex = 0
    private var currentEndpoint: String?
    private var sessionID: String?
    private var relaySessionID: String?
    private var nextRequestIDValue = 3
    private var pendingAudio = Data()
    private var gatewayToken: String?
    private let deviceCredentialsProvider: () -> OpenClawDeviceCredentials?
    private var deviceCredentials: OpenClawDeviceCredentials?
    /// Set after a NOT_PAIRED rejection: the gateway-approved scope set to use
    /// for the reconnect (requesting more re-triggers the pairing prompt).
    private var requestedScopesOverride: [String]?
    private var hasRetriedWithApprovedScopes = false

    private static let fatalAudioFailureMessage =
        "Microphone audio stopped after repeated audio device failures. Start the voice session again."

    init(
        configuration: VoiceSessionConfiguration,
        tokenProvider: @escaping () -> String?,
        audioEngine: @autoclosure @escaping () -> RealtimeAudioEngineProtocol = RealtimeAudioEngine(),
        deviceCredentialsProvider: @escaping () -> OpenClawDeviceCredentials? = {
            OpenClawDeviceIdentityStore.loadCredentials()
        },
        webSocketFactory: @escaping OpenClawTalkWebSocketFactory = {
            OpenClawTalkURLSessionWebSocket(request: $0)
        },
        watchdogScheduler: @escaping OpenClawTalkWatchdogScheduler = { delay, action in
            let workItem = DispatchWorkItem(block: action)
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + delay,
                execute: workItem
            )
            return workItem
        },
        gateNow: @escaping () -> Date = Date.init
    ) {
        self.configuration = configuration
        self.tokenProvider = tokenProvider
        self.audioEngineFactory = audioEngine
        self.deviceCredentialsProvider = deviceCredentialsProvider
        self.webSocketFactory = webSocketFactory
        self.watchdogScheduler = watchdogScheduler
        self.gateNow = gateNow
        super.init()
        stateQueue.setSpecific(key: stateQueueKey, value: ())
    }

    deinit {
        withStateSync {
            cancelHandshakeWatchdog()
            cancelConsultWatchdog()
            instantiatedAudioEngine?.stop()
            disposeCurrentSocket()
        }
    }

    func prepare() {
        withStateSync {
            prepareOnStateQueue()
        }
    }

    private func prepareOnStateQueue() {
        guard tokenProvider() != nil else {
            emit(.status(.needsAttention(Self.missingTokenMessage)))
            return
        }
        emit(.status(.ready))
    }

    func update(configuration: VoiceSessionConfiguration) {
        withStateSync {
            self.configuration = configuration
            // The gateway owns the live session; endpoint changes apply next session.
            guard isConnected == false else {
                refreshAudioEngineState()
                return
            }
            if isStarting || isConnecting {
                emit(.status(.starting))
            } else {
                prepareOnStateQueue()
            }
        }
    }

    func toggleVoice() {
        withStateSync {
            switch VoiceToggleDecision.decide(
                isStarting: isStarting,
                isConnecting: isConnecting,
                isConnected: isConnected,
                isAudioStreaming: isAudioStreaming
            ) {
            case .stop:
                stopVoiceOnStateQueue()
            case .start:
                startVoice()
            }
        }
    }

    func stopVoice() {
        withStateSync {
            stopVoiceOnStateQueue()
        }
    }

    private func stopVoiceOnStateQueue() {
        startGeneration += 1
        isStopping = true
        emit(.status(.stopping))
        if let sessionID, hasConnectedToGateway {
            sendJSON(OpenClawTalkRequestBuilder.closeFrame(id: nextRequestID(), sessionID: sessionID))
        }
        teardownConnection()
        isStopping = false
        emit(.status(.ready))
    }

    func showProviderInterface() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let appURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: Self.openClawBundleID
            ) else {
                self.performOnStateQueue { [weak self] in
                    self?.emit(.diagnostic("The OpenClaw app is not installed."))
                }
                return
            }
            NSWorkspace.shared.openApplication(
                at: appURL,
                configuration: NSWorkspace.OpenConfiguration()
            ) { [weak self] _, error in
                guard let error else { return }
                self?.performOnStateQueue { [weak self] in
                    self?.emit(.diagnostic(
                        "Could not open the OpenClaw app: \(error.localizedDescription)"
                    ))
                }
            }
        }
    }

    func reloadProviderInterface() {
        showProviderInterface()
    }

    // MARK: - Starting

    private func startVoice() {
        guard let token = tokenProvider() else {
            emit(.status(.needsAttention(Self.missingTokenMessage)))
            return
        }

        startGeneration += 1
        let generation = startGeneration
        isStarting = true
        hasReportedMicrophoneAudio = false
        hasReportedMicrophoneSignal = false
        emit(.status(.starting))
        audioEngine.requestMicrophoneAccess { [weak self] granted in
            self?.performOnStateQueue { [weak self] in
                guard let self,
                      self.startGeneration == generation,
                      self.isStarting,
                      self.isStopping == false else { return }
                guard granted else {
                    self.isStarting = false
                    self.emit(.status(.needsAttention(
                        RealtimeAudioEngineError.microphoneDenied.localizedDescription
                    )))
                    return
                }
                self.connect(token: token, generation: generation)
            }
        }
    }

    private func connect(token: String, generation: Int) {
        guard startGeneration == generation,
              isStarting,
              isStopping == false else { return }

        resetSpeakerModeState()
        gatewayToken = token
        deviceCredentials = deviceCredentialsProvider()
        requestedScopesOverride = nil
        hasRetriedWithApprovedScopes = false
        endpointCandidates = OpenClawTalkRequestBuilder.endpointCandidates(endpointURL: configuration.endpointURL)
        endpointCandidateIndex = 0
        currentEndpoint = nil
        nextRequestIDValue = 3
        isStarting = false
        isConnecting = true
        connectToNextEndpointCandidate(generation: generation)
    }

    private func connectToNextEndpointCandidate(generation: Int) {
        guard startGeneration == generation,
              isStopping == false,
              hasConnectedToGateway == false else { return }

        guard endpointCandidateIndex < endpointCandidates.count else {
            teardownConnection()
            emit(.status(.needsAttention(Self.unreachableMessage)))
            return
        }

        let endpoint = endpointCandidates[endpointCandidateIndex]
        endpointCandidateIndex += 1
        guard let request = OpenClawTalkRequestBuilder.webSocketRequest(endpoint: endpoint) else {
            connectToNextEndpointCandidate(generation: generation)
            return
        }

        isConnecting = true
        isConnected = false
        hasConnectedToGateway = false
        sessionID = nil
        relaySessionID = nil
        currentEndpoint = endpoint
        handshakePhase = .awaitingSocketOpen
        emit(.diagnostic("Connecting to OpenClaw gateway at \(endpoint)."))
        let socket = webSocketFactory(request)
        socket.onOpen = { [weak self, weak socket] in
            guard let socket else { return }
            self?.performOnStateQueue { [weak self, weak socket] in
                guard let self, let socket else { return }
                self.handleSocketOpened(socket, generation: generation)
            }
        }
        socket.onClose = { [weak self, weak socket] closeCode in
            guard let socket else { return }
            self?.performOnStateQueue { [weak self, weak socket] in
                guard let self, let socket else { return }
                self.handleSocketClosed(socket, closeCode: closeCode, generation: generation)
            }
        }
        webSocket = socket
        socket.resume()
        receiveLoop(socket: socket, generation: generation)
    }

    private func startAudioStreaming() {
        guard isAudioStreaming == false else { return }
        isAudioStreaming = true
        pendingAudio = Data()
        audioEngine.refreshOutputRoute()
        refreshAudioEngineState()
        do {
            try audioEngine.start(
                inputHandler: { [weak self] audio in
                    self?.performOnStateQueue { [weak self] in
                        self?.queueMicrophoneAudio(audio)
                    }
                },
                activityHandler: { [weak self] activity in
                    self?.performOnStateQueue { [weak self] in
                        self?.handleInputActivity(activity)
                    }
                }
            )
            guard webSocket != nil, sessionID != nil, isStopping == false else {
                isAudioStreaming = false
                audioEngine.stop()
                return
            }
            emit(.status(.listening))
        } catch {
            teardownConnection()
            emit(.status(.needsAttention(error.localizedDescription)))
        }
    }

    private func queueMicrophoneAudio(_ audio: Data) {
        guard let sessionID, hasConnectedToGateway else { return }
        refreshAudioEngineState()
        guard speakerGate.isGateClosed(at: gateNow()) == false else { return }
        pendingAudio.append(audio)
        while pendingAudio.count >= Self.audioChunkByteCount {
            let chunk = pendingAudio.prefix(Self.audioChunkByteCount)
            sendJSON(OpenClawTalkRequestBuilder.appendAudioFrame(
                id: nextRequestID(),
                sessionID: sessionID,
                audio: Data(chunk)
            ))
            pendingAudio.removeFirst(Self.audioChunkByteCount)
        }
    }

    private func handleInputActivity(_ activity: RealtimeAudioInputActivity) {
        if hasReportedMicrophoneAudio == false {
            hasReportedMicrophoneAudio = true
            emit(.diagnostic("Microphone audio streaming."))
        }

        if hasReportedMicrophoneSignal == false, activity.peak >= 0.02 {
            hasReportedMicrophoneSignal = true
            emit(.diagnostic(String(format: "Microphone input detected (peak %.3f).", activity.peak)))
        }

        refreshAudioEngineState()
        if speakerGate.isSpeakerMode {
            guard speakerGate.observe(activity, at: gateNow()) else { return }
            interruptSpeakerModePlaybackIfNeeded()
        } else {
            speakerGate.resetActivity()
            // Headphones keep the existing immediate barge-in behavior.
            if isSpeaking,
               hasCancelledOutput == false,
               activity.peak >= 0.02,
               let sessionID {
                hasCancelledOutput = true
                sendJSON(OpenClawTalkRequestBuilder.cancelOutputFrame(
                    id: nextRequestID(),
                    sessionID: sessionID
                ))
                emit(.diagnostic("User interrupted; cancelling OpenClaw output."))
            }
        }
    }

    private func handleFatalAudioFailure() {
        guard isAudioStreaming else { return }
        isAudioStreaming = false
        teardownConnection()
        emit(.status(.needsAttention(Self.fatalAudioFailureMessage)))
    }

    // MARK: - Receiving

    private func receiveLoop(socket: OpenClawTalkWebSocket, generation: Int) {
        socket.receive { [weak self, weak socket] result in
            guard let socket else { return }
            self?.performOnStateQueue { [weak self, weak socket] in
                guard let self,
                      let socket,
                      self.webSocket === socket,
                      self.startGeneration == generation,
                      self.isStopping == false else { return }
                switch result {
                case let .success(message):
                    self.handle(message)
                    if self.webSocket === socket {
                        self.receiveLoop(socket: socket, generation: generation)
                    }
                case let .failure(error):
                    if self.sessionID == nil {
                        self.advanceToNextEndpointCandidate(
                            generation: generation,
                            diagnostic: "OpenClaw gateway handshake failed: \(error.localizedDescription)"
                        )
                    } else {
                        self.teardownConnection()
                        self.emit(.diagnostic(
                            "OpenClaw gateway connection lost: \(error.localizedDescription)"
                        ))
                        self.emit(.status(.ready))
                    }
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case let .string(text):
            handleEventText(text)
        case let .data(data):
            if let text = String(data: data, encoding: .utf8) {
                handleEventText(text)
            }
        @unknown default:
            break
        }
    }

    private func handleEventText(_ text: String) {
        for action in OpenClawTalkEventMapper.actions(from: text, sessionID: relaySessionID) {
            switch action {
            case .connectChallenge:
                cancelHandshakeWatchdog()
                sendConnectFrame(nonce: OpenClawTalkEventMapper.connectChallengeNonce(from: text))
                scheduleHandshakeWatchdog(.awaitingHello)
            case .connected:
                handleGatewayConnected()
            case let .sessionCreated(newSessionID, newRelaySessionID):
                cancelHandshakeWatchdog()
                sessionID = newSessionID
                relaySessionID = newRelaySessionID
                gatewayToken = nil
            case .sessionReady:
                startAudioStreaming()
            case let .audio(audio):
                if isSpeaking == false {
                    hasCancelledOutput = false
                    speakerGate.beginAssistantTurn()
                    audioEngine.beginAssistantAudioTurn()
                }
                isSpeaking = true
                audioEngine.playPCM16(audio)
            case .assistantTurnEnded:
                isSpeaking = false
                hasCancelledOutput = false
            case .stopPlayback:
                isSpeaking = false
                hasCancelledOutput = false
                audioEngine.stopPlayback()
            case let .sessionClosed(reason):
                handleSessionClosed(reason: reason)
            case let .handshakeFailed(message):
                handleHandshakeFailed(message: message)
            case let .connectRetryWithScopes(scopes, message):
                retryConnectWithApprovedScopes(scopes, failureMessage: message)
            case let .toolCall(toolCall):
                handleToolCall(toolCall)
            case let .malformedToolCall(callID, reason):
                handleMalformedToolCall(callID: callID, reason: reason)
            case let .requestSucceeded(id, runID):
                handleRequestSucceeded(id: id, runID: runID)
            case let .requestFailed(id, message):
                handleRequestFailed(id: id, message: message)
            case let .chatLifecycle(runID, state, text, errorMessage):
                handleChatLifecycle(
                    runID: runID,
                    state: state,
                    text: text,
                    errorMessage: errorMessage
                )
            case let .consultToolProgress(runID, phase, toolName):
                handleConsultToolProgress(runID: runID, phase: phase, toolName: toolName)
            case let .providerEvent(event):
                if case .status(.listening) = event, consultState != nil {
                    emit(.status(.thinking))
                } else {
                    emit(event)
                }
            }
        }
    }

    // MARK: - Agent consult tool calls

    private func handleToolCall(_ toolCall: OpenClawTalkToolCall) {
        guard toolCall.name == Self.agentConsultToolName else {
            emit(.diagnostic("OpenClaw Talk rejected unsupported tool '\(safeToolName(toolCall.name))'."))
            submitUntrackedToolResult(
                callID: toolCall.callID,
                result: ["error": "Unsupported OpenClaw Talk tool."]
            )
            return
        }
        guard consultState == nil else {
            emit(.diagnostic(
                "OpenClaw Talk rejected overlapping tool '\(safeToolName(toolCall.name))'; a consult is already in progress."
            ))
            submitUntrackedToolResult(
                callID: toolCall.callID,
                result: ["error": "Another OpenClaw consult is already in progress."]
            )
            emit(.status(.thinking))
            return
        }
        guard let relaySessionID else {
            emit(.diagnostic("OpenClaw consult could not start because the relay session id is unavailable."))
            return
        }

        let requestID = nextRequestID()
        consultState = ConsultState(
            callID: toolCall.callID,
            startRequestID: requestID
        )
        emit(.status(.thinking))

        guard let frame = OpenClawTalkRequestBuilder.clientToolCallFrame(
            id: requestID,
            relaySessionID: relaySessionID,
            toolCall: toolCall
        ) else {
            emit(.diagnostic("OpenClaw consult arguments could not be encoded."))
            submitConsultResult(["error": "OpenClaw consult arguments were invalid."])
            return
        }
        sendJSON(frame) { [weak self] _ in
            guard let self,
                  self.consultState?.startRequestID == requestID else { return }
            self.emit(.diagnostic("OpenClaw consult request could not be sent."))
            self.finishConsult()
        }
    }

    private func handleMalformedToolCall(callID: String?, reason: String) {
        emit(.diagnostic(reason))
        guard let callID else { return }
        submitUntrackedToolResult(
            callID: callID,
            result: ["error": "Malformed OpenClaw Talk tool call."]
        )
    }

    private func handleRequestSucceeded(id: String, runID: String?) {
        guard var consultState else { return }
        if id == consultState.startRequestID {
            guard let runID = runID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  runID.isEmpty == false else {
                emit(.diagnostic("OpenClaw consult response omitted its run id."))
                submitConsultResult(["error": "OpenClaw consult did not return a run id."])
                return
            }
            consultState.runID = runID
            self.consultState = consultState
            scheduleConsultWatchdog(runID: runID)
            return
        }
        if id == consultState.submitRequestID {
            finishConsult()
        }
    }

    private func handleRequestFailed(id: String, message: String) {
        guard let consultState else {
            emit(.diagnostic("OpenClaw request \(id) failed: \(message)"))
            return
        }
        if id == consultState.startRequestID {
            emit(.diagnostic("OpenClaw consult request was rejected by the gateway."))
            submitConsultResult(["error": "OpenClaw consult request failed."])
            return
        }
        if id == consultState.submitRequestID {
            emit(.diagnostic("OpenClaw consult tool result was rejected by the gateway."))
            finishConsult()
            return
        }
        emit(.diagnostic("OpenClaw request \(id) failed: \(message)"))
    }

    private func handleChatLifecycle(
        runID: String?,
        state: String?,
        text: String?,
        errorMessage: String?
    ) {
        guard let consultState else { return }
        guard let runID = runID?.trimmingCharacters(in: .whitespacesAndNewlines),
              runID.isEmpty == false else {
            emit(.diagnostic("OpenClaw chat lifecycle event omitted its run id."))
            return
        }
        guard runID == consultState.runID else { return }
        guard let state = state?.trimmingCharacters(in: .whitespacesAndNewlines),
              state.isEmpty == false else {
            emit(.diagnostic("OpenClaw consult lifecycle event omitted its state."))
            return
        }

        switch state {
        case "status", "delta":
            emit(.status(.thinking))
        case "final":
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  text.isEmpty == false else {
                emit(.diagnostic("OpenClaw consult completed without a text result."))
                submitConsultResult(["error": "OpenClaw consult completed without a text result."])
                return
            }
            if text.contains(Self.confirmationMarker) {
                emit(.transcript(text))
                emit(.diagnostic("OpenClaw consult requires voice confirmation."))
            }
            submitConsultResult(["result": text])
        case "aborted":
            submitConsultResult([
                "status": "cancelled",
                "message": "Cancelled the active OpenClaw run."
            ])
        case "error":
            emit(.diagnostic("OpenClaw consult run failed."))
            let resultMessage = errorMessage?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            submitConsultResult([
                "error": resultMessage?.isEmpty == false
                    ? resultMessage ?? "OpenClaw consult failed."
                    : "OpenClaw consult failed."
            ])
        default:
            emit(.diagnostic("OpenClaw consult lifecycle event had unknown state '\(safeToolName(state))'."))
        }
    }

    private func submitConsultResult(_ result: [String: Any]) {
        guard var consultState,
              consultState.submitRequestID == nil,
              let sessionID else { return }
        cancelConsultWatchdog()
        let requestID = nextRequestID()
        consultState.submitRequestID = requestID
        self.consultState = consultState
        sendJSON(OpenClawTalkRequestBuilder.submitToolResultFrame(
            id: requestID,
            sessionID: sessionID,
            callID: consultState.callID,
            result: result
        )) { [weak self] _ in
            guard let self,
                  self.consultState?.submitRequestID == requestID else { return }
            self.emit(.diagnostic("OpenClaw consult tool result could not be sent."))
            self.finishConsult()
        }
    }

    private func submitUntrackedToolResult(callID: String, result: [String: Any]) {
        guard let sessionID else { return }
        sendJSON(OpenClawTalkRequestBuilder.submitToolResultFrame(
            id: nextRequestID(),
            sessionID: sessionID,
            callID: callID,
            result: result
        )) { [weak self] _ in
            self?.emit(.diagnostic("OpenClaw Talk rejection result could not be sent."))
        }
    }

    private func scheduleConsultWatchdog(runID: String) {
        cancelConsultWatchdog()
        consultWatchdogGeneration += 1
        let watchdogGeneration = consultWatchdogGeneration
        _ = watchdogScheduler(Self.consultProgressInterval) { [weak self] in
            self?.performOnStateQueue { [weak self] in
                guard let self,
                      self.consultWatchdogGeneration == watchdogGeneration,
                      self.consultState?.runID == runID,
                      self.consultState?.submitRequestID == nil,
                      self.isStopping == false else { return }
                self.emit(.diagnostic(
                    "OpenClaw consult still running; waiting up to "
                        + "\(Int(Self.consultTimeout))s for the agent."
                ))
            }
        }
        consultWatchdog = watchdogScheduler(Self.consultTimeout) { [weak self] in
            self?.performOnStateQueue { [weak self] in
                guard let self,
                      self.consultWatchdogGeneration == watchdogGeneration,
                      self.consultState?.runID == runID,
                      self.consultState?.submitRequestID == nil,
                      self.isStopping == false else { return }
                self.consultWatchdog = nil
                self.emit(.diagnostic(
                    "OpenClaw consult timed out; submitting an expired tool result."
                ))
                self.submitConsultResult(["error": "OpenClaw consult timed out."])
            }
        }
    }

    private func cancelConsultWatchdog() {
        consultWatchdogGeneration += 1
        consultWatchdog?.cancel()
        consultWatchdog = nil
    }

    /// Per-tool progress from the consult run (gateway "agent" events with
    /// stream "tool", delivered because we connect with the tool-events cap).
    /// Progress proves the agent is working, so the timeout watchdog resets:
    /// it exists to unstick a DEAD run, and must never kill a progressing one.
    private func handleConsultToolProgress(
        runID: String?,
        phase: String?,
        toolName: String?
    ) {
        guard let consultState,
              let runID,
              runID == consultState.runID,
              consultState.submitRequestID == nil,
              isStopping == false else { return }
        if phase == "start", let toolName, toolName.isEmpty == false {
            emit(.diagnostic("OpenClaw consult running tool '\(safeToolName(toolName))'."))
        }
        emit(.status(.thinking))
        scheduleConsultWatchdog(runID: runID)
    }

    private func finishConsult() {
        cancelConsultWatchdog()
        consultState = nil
        if sessionID != nil, isStopping == false {
            emit(.status(.listening))
        }
    }

    private func safeToolName(_ name: String) -> String {
        String(name.components(separatedBy: .controlCharacters)
            .joined(separator: "?")
            .prefix(80))
    }

    private func sendConnectFrame(nonce: String?) {
        guard let gatewayToken else { return }
        if let deviceCredentials {
            if let nonce,
               let proof = makeDeviceProof(credentials: deviceCredentials, nonce: nonce) {
                sendJSON(OpenClawTalkRequestBuilder.connectFrame(
                    token: gatewayToken,
                    clientVersion: Self.clientVersion,
                    scopes: requestedScopesOverride ?? deviceCredentials.operatorScopes,
                    deviceToken: deviceCredentials.operatorToken,
                    deviceProof: proof
                ))
                return
            }
            if nonce == nil {
                emit(.diagnostic(
                    "OpenClaw gateway challenge omitted a nonce; paired-device authentication is unavailable."
                ))
            }
        }

        // Without usable paired-device proof, the bare gateway token connects but
        // carries no scopes; talk setup surfaces the gateway's pairing guidance.
        sendJSON(OpenClawTalkRequestBuilder.connectFrame(
            token: gatewayToken,
            clientVersion: Self.clientVersion
        ))
    }

    private func makeDeviceProof(credentials: OpenClawDeviceCredentials, nonce: String) -> OpenClawDeviceProof? {
        guard let gatewayToken else { return nil }
        let signedAtMs = Int64(Date().timeIntervalSince1970 * 1_000)
        let scopes = requestedScopesOverride ?? credentials.operatorScopes
        let payload = OpenClawConnectSigner.signaturePayload(
            deviceID: credentials.deviceID,
            clientID: OpenClawTalkRequestBuilder.clientID,
            clientMode: OpenClawTalkRequestBuilder.clientMode,
            role: OpenClawTalkRequestBuilder.role,
            scopes: scopes,
            signedAtMs: signedAtMs,
            token: gatewayToken,
            nonce: nonce
        )
        guard let signature = OpenClawConnectSigner.sign(
            payload: payload,
            privateKeySeed: credentials.privateKeySeed
        ) else {
            return nil
        }
        return OpenClawDeviceProof(
            deviceID: credentials.deviceID,
            publicKeyBase64URL: OpenClawConnectSigner.base64URLEncode(credentials.publicKey),
            signatureBase64URL: signature,
            signedAtMs: signedAtMs,
            nonce: nonce
        )
    }

    /// The gateway closes the socket after a NOT_PAIRED rejection (close code
    /// 1008), so the scope-adjusted retry needs a fresh connection — and a fresh
    /// challenge nonce — against the same endpoint.
    private func retryConnectWithApprovedScopes(_ scopes: [String], failureMessage: String) {
        guard deviceCredentials != nil,
              hasConnectedToGateway == false,
              hasRetriedWithApprovedScopes == false,
              scopes.isEmpty == false else {
            handleHandshakeFailed(message: failureMessage)
            return
        }
        hasRetriedWithApprovedScopes = true
        requestedScopesOverride = scopes
        emit(.diagnostic("OpenClaw gateway approved scopes differ; reconnecting with adjusted scopes."))
        cancelHandshakeWatchdog()
        disposeCurrentSocket()
        isConnected = false
        hasConnectedToGateway = false
        endpointCandidateIndex = max(0, endpointCandidateIndex - 1)
        connectToNextEndpointCandidate(generation: startGeneration)
    }

    private func handleGatewayConnected() {
        cancelHandshakeWatchdog()
        hasConnectedToGateway = true
        sendJSON(OpenClawTalkRequestBuilder.sessionCreateFrame())
        scheduleHandshakeWatchdog(.awaitingSessionCreated)
    }

    private func handleSessionClosed(reason: String?) {
        if let reason, reason.isEmpty == false {
            emit(.diagnostic("OpenClaw talk session closed (\(reason))."))
        } else {
            emit(.diagnostic("OpenClaw talk session closed."))
        }
        teardownConnection()
        emit(.status(.ready))
    }

    private func handleHandshakeFailed(message: String) {
        teardownConnection()
        emit(.status(.needsAttention(message)))
    }

    private func handleSocketOpened(
        _ socket: OpenClawTalkWebSocket,
        generation: Int
    ) {
        guard webSocket === socket,
              startGeneration == generation,
              isStopping == false else { return }
        isConnecting = false
        isConnected = true
        emit(.diagnostic("OpenClaw gateway WebSocket opened."))
        if handshakePhase == .awaitingSocketOpen {
            scheduleHandshakeWatchdog(.awaitingChallenge)
        }
    }

    private func handleSocketClosed(
        _ socket: OpenClawTalkWebSocket,
        closeCode: URLSessionWebSocketTask.CloseCode,
        generation: Int
    ) {
        guard webSocket === socket,
              startGeneration == generation,
              isStopping == false else { return }
        if sessionID == nil {
            advanceToNextEndpointCandidate(
                generation: generation,
                diagnostic: "OpenClaw gateway closed during handshake (code \(closeCode.rawValue))."
            )
        } else {
            teardownConnection()
            emit(.diagnostic(
                "OpenClaw gateway connection closed (code \(closeCode.rawValue))."
            ))
            emit(.status(.ready))
        }
    }

    private func scheduleHandshakeWatchdog(_ phase: HandshakePhase) {
        cancelHandshakeWatchdog()
        handshakePhase = phase
        handshakeWatchdogGeneration += 1
        let watchdogGeneration = handshakeWatchdogGeneration
        handshakeWatchdog = watchdogScheduler(Self.handshakeTimeout) { [weak self] in
            self?.performOnStateQueue { [weak self] in
                guard let self,
                      self.handshakeWatchdogGeneration == watchdogGeneration,
                      self.handshakePhase == phase,
                      self.webSocket != nil,
                      self.isStopping == false else { return }
                self.handshakeWatchdog = nil
                self.handshakePhase = nil
                let endpoint = self.currentEndpoint ?? "the current endpoint"
                self.advanceToNextEndpointCandidate(
                    generation: self.startGeneration,
                    diagnostic: """
                        OpenClaw gateway at \(endpoint) timed out waiting for \
                        \(phase.diagnosticDescription).
                        """
                )
            }
        }
    }

    private func cancelHandshakeWatchdog() {
        handshakeWatchdogGeneration += 1
        handshakeWatchdog?.cancel()
        handshakeWatchdog = nil
        handshakePhase = nil
    }

    private func advanceToNextEndpointCandidate(
        generation: Int,
        diagnostic: String
    ) {
        guard startGeneration == generation, isStopping == false else { return }
        emit(.diagnostic(diagnostic))
        cancelHandshakeWatchdog()
        disposeCurrentSocket()
        isConnecting = true
        isConnected = false
        hasConnectedToGateway = false
        sessionID = nil
        relaySessionID = nil
        currentEndpoint = nil
        connectToNextEndpointCandidate(generation: generation)
    }

    private func disposeCurrentSocket() {
        guard let socket = webSocket else { return }
        webSocket = nil
        socket.onOpen = nil
        socket.onClose = nil
        socket.cancel(with: .normalClosure, reason: nil)
        socket.invalidateAndCancel()
    }

    private func teardownConnection() {
        cancelHandshakeWatchdog()
        cancelConsultWatchdog()
        consultState = nil
        audioEngine.stop()
        disposeCurrentSocket()
        isStarting = false
        isConnecting = false
        isConnected = false
        hasConnectedToGateway = false
        isAudioStreaming = false
        isSpeaking = false
        hasCancelledOutput = false
        hasReportedMicrophoneAudio = false
        hasReportedMicrophoneSignal = false
        sessionID = nil
        relaySessionID = nil
        currentEndpoint = nil
        pendingAudio = Data()
        gatewayToken = nil
        deviceCredentials = nil
        requestedScopesOverride = nil
        hasRetriedWithApprovedScopes = false
        resetSpeakerModeState()
    }

    private func refreshAudioEngineState() {
        adoptAudioEngineState(audioEngine.stateSnapshot())
    }

    private func adoptAudioEngineState(_ state: RealtimeAudioEngineState) {
        audioEngineState = state
        speakerGate.setSpeakerMode(effectiveSpeakerMode())
        speakerGate.updatePlayback(isActive: state.isPlaybackActive, at: gateNow())

        if state.isEchoCancellationActive {
            hasReportedAECFallback = false
        } else if hasReportedAECFallback == false {
            hasReportedAECFallback = true
            emit(.diagnostic(
                "Echo cancellation is inactive; forcing speaker-mode microphone gating."
            ))
        }
    }

    private func effectiveSpeakerMode() -> Bool {
        let state = audioEngineState ?? audioEngine.stateSnapshot()
        return OpenAIRealtimeSpeakerModePolicy.isSpeakerMode(
            route: state.outputRoute,
            preference: configuration.speakerModePreference,
            isEchoCancellationActive: state.isEchoCancellationActive
        )
    }

    private func interruptSpeakerModePlaybackIfNeeded() {
        // The gate also trips on assertive speech during the post-playback
        // hangover. Once playback has drained, opening the mic is sufficient;
        // asking the gateway to cancel would target output the user already heard.
        guard audioEngineState?.isPlaybackActive == true,
              hasCancelledOutput == false,
              let sessionID else {
            return
        }
        hasCancelledOutput = true
        audioEngine.stopPlayback()
        sendJSON(OpenClawTalkRequestBuilder.cancelOutputFrame(
            id: nextRequestID(),
            sessionID: sessionID
        ))
        emit(.diagnostic("User interrupted; cancelling OpenClaw output."))
    }

    private func resetSpeakerModeState() {
        audioEngineState = nil
        speakerGate = OpenAIRealtimeSpeakerGate()
        hasReportedAECFallback = false
    }

    private func nextRequestID() -> String {
        defer { nextRequestIDValue += 1 }
        return String(nextRequestIDValue)
    }

    private static var clientVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    private func sendJSON(
        _ object: [String: Any],
        onError: ((Error) -> Void)? = nil
    ) {
        guard let socket = webSocket,
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else {
            return
        }
        socket.send(.string(text)) { [weak self, weak socket] error in
            guard let error, let socket else { return }
            self?.performOnStateQueue { [weak self, weak socket] in
                guard let self,
                      let socket,
                      self.webSocket === socket,
                      self.isStopping == false else { return }
                if let onError {
                    onError(error)
                } else {
                    self.emit(.status(.needsAttention(error.localizedDescription)))
                }
            }
        }
    }

    private func emit(_ event: VoiceProviderEvent) {
        let handler = eventHandler
        DispatchQueue.main.async {
            handler?(event)
        }
    }

    private func withStateSync<T>(_ action: () -> T) -> T {
        if DispatchQueue.getSpecific(key: stateQueueKey) != nil {
            return action()
        }
        return stateQueue.sync(execute: action)
    }

    private func performOnStateQueue(_ action: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: stateQueueKey) != nil {
            action()
        } else {
            stateQueue.async(execute: action)
        }
    }
}
