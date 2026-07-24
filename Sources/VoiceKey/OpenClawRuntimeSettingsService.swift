import Foundation

struct OpenClawRuntimeSettings: Equatable {
    enum Source: Equatable {
        case staticFallback
        case gateway
    }

    var sessionKey: String
    var model: String
    var voice: String
    var source: Source

    static let staticFallback = OpenClawRuntimeSettings(
        sessionKey: OpenClawTalkRequestBuilder.sessionKey,
        model: "gpt-5.6-luna",
        voice: "cedar",
        source: .staticFallback
    )

    static let staticValuesDate = "July 24, 2026"
    static let voiceOptions = [
        "alloy", "ash", "ballad", "coral", "echo",
        "sage", "shimmer", "verse", "marin", "cedar"
    ]
}

struct OpenClawRuntimePanelState: Equatable {
    var settings: OpenClawRuntimeSettings
    var approvedScopes: Set<String>
    var loadError: String?

    var isEditable: Bool {
        approvedScopes.contains("operator.admin")
    }

    var caption: String {
        if let loadError {
            return "Managed by the gateway. Couldn’t load current values (\(loadError)); showing static values as of \(OpenClawRuntimeSettings.staticValuesDate)."
        }
        if settings.source == .gateway {
            return isEditable
                ? "Managed by the gateway. Current values loaded through the paired device; operator.admin allows editing."
                : "Managed by the gateway. Current values loaded through the paired device and are read-only."
        }
        return isEditable
            ? "Managed by the gateway. Static values as of \(OpenClawRuntimeSettings.staticValuesDate); operator.admin allows editing."
            : "Managed by the gateway. Read-only static values as of \(OpenClawRuntimeSettings.staticValuesDate)."
    }
}

protocol OpenClawRuntimeSettingsServing: AnyObject {
    var approvedScopes: Set<String> { get }

    func load(
        endpointURL: String,
        completion: @escaping (Result<OpenClawRuntimeSettings, Error>) -> Void
    )

    func apply(
        model: String,
        voice: String,
        endpointURL: String,
        completion: @escaping (Result<OpenClawRuntimeSettings, Error>) -> Void
    )
}

enum OpenClawRuntimeSettingsError: LocalizedError {
    case unavailable(String)
    case gateway(String)

    var errorDescription: String? {
        switch self {
        case let .unavailable(message), let .gateway(message):
            return message
        }
    }
}

enum OpenClawRuntimeRequestBuilder {
    static let connectRequestID = "runtime-connect"
    static let sessionsListRequestID = "runtime-sessions-list"
    static let talkConfigRequestID = "runtime-talk-config"
    static let sessionsPatchRequestID = "runtime-sessions-patch"
    static let configGetRequestID = "runtime-config-get"
    static let configPatchRequestID = "runtime-config-patch"

    static func sessionsListFrame() -> [String: Any] {
        request(id: sessionsListRequestID, method: "sessions.list", params: [:])
    }

    static func talkConfigFrame() -> [String: Any] {
        request(id: talkConfigRequestID, method: "talk.config", params: [:])
    }

    static func sessionsPatchFrame(model: String) -> [String: Any] {
        request(
            id: sessionsPatchRequestID,
            method: "sessions.patch",
            params: [
                "key": OpenClawTalkRequestBuilder.sessionKey,
                "model": model
            ]
        )
    }

    static func configGetFrame() -> [String: Any] {
        request(id: configGetRequestID, method: "config.get", params: [:])
    }

    static func configPatchFrame(voice: String, baseHash: String) -> [String: Any]? {
        let patch: [String: Any] = [
            "talk": [
                "realtime": [
                    "providers": [
                        "openai": ["voice": voice]
                    ]
                ]
            ]
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: patch,
            options: [.sortedKeys]
        ),
        let raw = String(data: data, encoding: .utf8) else {
            return nil
        }
        return request(
            id: configPatchRequestID,
            method: "config.patch",
            params: [
                "raw": raw,
                "baseHash": baseHash,
                "note": "VoiceKey updated the OpenClaw gateway talk voice."
            ]
        )
    }

    private static func request(
        id: String,
        method: String,
        params: [String: Any]
    ) -> [String: Any] {
        [
            "type": "req",
            "id": id,
            "method": method,
            "params": params
        ]
    }
}

final class OpenClawRuntimeSettingsService: OpenClawRuntimeSettingsServing {
    private let tokenProvider: () -> String?
    private let credentialsProvider: () -> OpenClawDeviceCredentials?
    private let webSocketFactory: OpenClawTalkWebSocketFactory
    private var transactions: [UUID: OpenClawRuntimeGatewayTransaction] = [:]

    init(
        tokenProvider: @escaping () -> String? = {
            OpenClawTokenResolver.resolveGatewayToken(
                apiKeyProvider: { APIKeyStore.shared.apiKey(for: .openClaw) }
            )
        },
        credentialsProvider: @escaping () -> OpenClawDeviceCredentials? = {
            OpenClawDeviceIdentityStore.loadCredentials()
        },
        webSocketFactory: @escaping OpenClawTalkWebSocketFactory = {
            OpenClawTalkURLSessionWebSocket(request: $0)
        }
    ) {
        self.tokenProvider = tokenProvider
        self.credentialsProvider = credentialsProvider
        self.webSocketFactory = webSocketFactory
    }

    var approvedScopes: Set<String> {
        Set(credentialsProvider()?.operatorScopes ?? [])
    }

    func load(
        endpointURL: String,
        completion: @escaping (Result<OpenClawRuntimeSettings, Error>) -> Void
    ) {
        start(operation: .load, endpointURL: endpointURL, completion: completion)
    }

    func apply(
        model: String,
        voice: String,
        endpointURL: String,
        completion: @escaping (Result<OpenClawRuntimeSettings, Error>) -> Void
    ) {
        guard approvedScopes.contains("operator.admin") else {
            completion(.failure(OpenClawRuntimeSettingsError.gateway(
                "The paired device is not approved for operator.admin."
            )))
            return
        }
        start(
            operation: .apply(model: model, voice: voice),
            endpointURL: endpointURL,
            completion: completion
        )
    }

    private func start(
        operation: OpenClawRuntimeGatewayTransaction.Operation,
        endpointURL: String,
        completion: @escaping (Result<OpenClawRuntimeSettings, Error>) -> Void
    ) {
        guard let token = tokenProvider() else {
            completion(.failure(OpenClawRuntimeSettingsError.unavailable(
                "OpenClaw gateway token not found"
            )))
            return
        }
        guard let credentials = credentialsProvider() else {
            completion(.failure(OpenClawRuntimeSettingsError.unavailable(
                "this Mac is not paired with the OpenClaw gateway"
            )))
            return
        }

        let id = UUID()
        let transaction = OpenClawRuntimeGatewayTransaction(
            operation: operation,
            endpointCandidates: OpenClawTalkRequestBuilder.endpointCandidates(
                endpointURL: endpointURL
            ),
            token: token,
            credentials: credentials,
            webSocketFactory: webSocketFactory
        ) { [weak self] result in
            DispatchQueue.main.async {
                self?.transactions[id] = nil
                completion(result)
            }
        }
        transactions[id] = transaction
        transaction.start()
    }
}

private final class OpenClawRuntimeGatewayTransaction {
    enum Operation {
        case load
        case apply(model: String, voice: String)
    }

    private enum Phase: Equatable {
        case awaitingChallenge
        case awaitingConnect
        case awaitingSessionsList
        case awaitingTalkConfig
        case awaitingSessionsPatch
        case awaitingConfigGet
        case awaitingConfigPatch
        case finished
    }

    private let operation: Operation
    private let endpointCandidates: [String]
    private let token: String
    private let credentials: OpenClawDeviceCredentials
    private let webSocketFactory: OpenClawTalkWebSocketFactory
    private let completion: (Result<OpenClawRuntimeSettings, Error>) -> Void
    private let stateQueue = DispatchQueue(label: "VoiceKey.OpenClawRuntimeSettings")
    private var endpointIndex = 0
    private var socket: OpenClawTalkWebSocket?
    private var phase: Phase = .awaitingChallenge
    private var timeoutWorkItem: DispatchWorkItem?
    private var hasSentRuntimeRequest = false
    private var didApplyModel = false
    private var loadedModel: String?

    init(
        operation: Operation,
        endpointCandidates: [String],
        token: String,
        credentials: OpenClawDeviceCredentials,
        webSocketFactory: @escaping OpenClawTalkWebSocketFactory,
        completion: @escaping (Result<OpenClawRuntimeSettings, Error>) -> Void
    ) {
        self.operation = operation
        self.endpointCandidates = endpointCandidates
        self.token = token
        self.credentials = credentials
        self.webSocketFactory = webSocketFactory
        self.completion = completion
    }

    func start() {
        stateQueue.async { [weak self] in
            self?.connectToNextEndpoint()
        }
    }

    private func connectToNextEndpoint() {
        guard endpointIndex < endpointCandidates.count else {
            finish(.failure(OpenClawRuntimeSettingsError.unavailable(
                "OpenClaw gateway is unreachable"
            )))
            return
        }
        let endpoint = endpointCandidates[endpointIndex]
        endpointIndex += 1
        guard let request = OpenClawTalkRequestBuilder.webSocketRequest(endpoint: endpoint) else {
            connectToNextEndpoint()
            return
        }

        phase = .awaitingChallenge
        let socket = webSocketFactory(request)
        self.socket = socket
        socket.onClose = { [weak self, weak socket] _ in
            guard let self, let socket else { return }
            self.stateQueue.async {
                guard self.socket === socket, self.phase != .finished else { return }
                self.handleConnectionFailure("the gateway closed the connection")
            }
        }
        socket.resume()
        receiveLoop(socket)
        scheduleTimeout()
    }

    private func receiveLoop(_ socket: OpenClawTalkWebSocket) {
        socket.receive { [weak self, weak socket] result in
            guard let self, let socket else { return }
            self.stateQueue.async {
                guard self.socket === socket, self.phase != .finished else { return }
                switch result {
                case let .success(message):
                    self.handle(message)
                    if self.socket === socket, self.phase != .finished {
                        self.receiveLoop(socket)
                    }
                case let .failure(error):
                    self.handleConnectionFailure(error.localizedDescription)
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let text: String?
        switch message {
        case let .string(value):
            text = value
        case let .data(data):
            text = String(data: data, encoding: .utf8)
        @unknown default:
            text = nil
        }
        guard let text,
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        if object["type"] as? String == "event",
           object["event"] as? String == "connect.challenge",
           let payload = object["payload"] as? [String: Any],
           let nonce = payload["nonce"] as? String {
            sendConnect(nonce: nonce)
            return
        }
        guard object["type"] as? String == "res",
              let id = object["id"] as? String else {
            return
        }
        guard object["ok"] as? Bool == true else {
            finish(.failure(OpenClawRuntimeSettingsError.gateway(
                mutationAwareErrorMessage(gatewayErrorMessage(from: object))
            )))
            return
        }

        let payload = object["payload"] as? [String: Any] ?? [:]
        switch (phase, id) {
        case (.awaitingConnect, OpenClawRuntimeRequestBuilder.connectRequestID):
            beginOperation()
        case (.awaitingSessionsList, OpenClawRuntimeRequestBuilder.sessionsListRequestID):
            guard let model = Self.model(
                fromSessionsListPayload: payload,
                sessionKey: OpenClawTalkRequestBuilder.sessionKey
            ) else {
                finish(.failure(OpenClawRuntimeSettingsError.gateway(
                    "The gateway did not return the VoiceKey consult session model."
                )))
                return
            }
            loadedModel = model
            phase = .awaitingTalkConfig
            send(OpenClawRuntimeRequestBuilder.talkConfigFrame())
        case (.awaitingTalkConfig, OpenClawRuntimeRequestBuilder.talkConfigRequestID):
            guard let model = loadedModel,
                  let voice = Self.voice(fromTalkConfigPayload: payload) else {
                finish(.failure(OpenClawRuntimeSettingsError.gateway(
                    "The gateway did not return its OpenAI talk voice."
                )))
                return
            }
            finish(.success(OpenClawRuntimeSettings(
                sessionKey: OpenClawTalkRequestBuilder.sessionKey,
                model: model,
                voice: voice,
                source: .gateway
            )))
        case (.awaitingSessionsPatch, OpenClawRuntimeRequestBuilder.sessionsPatchRequestID):
            didApplyModel = true
            phase = .awaitingConfigGet
            send(OpenClawRuntimeRequestBuilder.configGetFrame())
        case (.awaitingConfigGet, OpenClawRuntimeRequestBuilder.configGetRequestID):
            guard let hash = (payload["hash"] as? String)
                ?? (payload["configHash"] as? String),
                  case let .apply(_, voice) = operation,
                  let frame = OpenClawRuntimeRequestBuilder.configPatchFrame(
                      voice: voice,
                      baseHash: hash
                  ) else {
                finish(.failure(OpenClawRuntimeSettingsError.gateway(
                    mutationAwareErrorMessage(
                        "The gateway did not return the config hash required for a safe voice update."
                    )
                )))
                return
            }
            phase = .awaitingConfigPatch
            send(frame)
        case (.awaitingConfigPatch, OpenClawRuntimeRequestBuilder.configPatchRequestID):
            guard case let .apply(model, voice) = operation else { return }
            finish(.success(OpenClawRuntimeSettings(
                sessionKey: OpenClawTalkRequestBuilder.sessionKey,
                model: model,
                voice: voice,
                source: .gateway
            )))
        default:
            break
        }
    }

    private func sendConnect(nonce: String) {
        guard phase == .awaitingChallenge else { return }
        let scopes = credentials.operatorScopes
        let signedAtMs = Int64(Date().timeIntervalSince1970 * 1_000)
        let payload = OpenClawConnectSigner.signaturePayload(
            deviceID: credentials.deviceID,
            clientID: OpenClawTalkRequestBuilder.clientID,
            clientMode: OpenClawTalkRequestBuilder.clientMode,
            role: OpenClawTalkRequestBuilder.role,
            scopes: scopes,
            signedAtMs: signedAtMs,
            token: token,
            nonce: nonce
        )
        guard let signature = OpenClawConnectSigner.sign(
            payload: payload,
            privateKeySeed: credentials.privateKeySeed
        ) else {
            finish(.failure(OpenClawRuntimeSettingsError.unavailable(
                "the paired-device proof could not be signed"
            )))
            return
        }
        let proof = OpenClawDeviceProof(
            deviceID: credentials.deviceID,
            publicKeyBase64URL: OpenClawConnectSigner.base64URLEncode(
                credentials.publicKey
            ),
            signatureBase64URL: signature,
            signedAtMs: signedAtMs,
            nonce: nonce
        )
        var frame = OpenClawTalkRequestBuilder.connectFrame(
            token: token,
            clientVersion: Self.clientVersion,
            scopes: scopes,
            deviceToken: credentials.operatorToken,
            deviceProof: proof
        )
        frame["id"] = OpenClawRuntimeRequestBuilder.connectRequestID
        phase = .awaitingConnect
        send(frame)
    }

    private func beginOperation() {
        hasSentRuntimeRequest = true
        switch operation {
        case .load:
            phase = .awaitingSessionsList
            send(OpenClawRuntimeRequestBuilder.sessionsListFrame())
        case let .apply(model, _):
            guard credentials.operatorScopes.contains("operator.admin") else {
                finish(.failure(OpenClawRuntimeSettingsError.gateway(
                    "The paired device is not approved for operator.admin."
                )))
                return
            }
            phase = .awaitingSessionsPatch
            send(OpenClawRuntimeRequestBuilder.sessionsPatchFrame(model: model))
        }
    }

    private func send(_ object: [String: Any]) {
        guard let socket,
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else {
            finish(.failure(OpenClawRuntimeSettingsError.gateway(
                "The gateway request could not be encoded."
            )))
            return
        }
        scheduleTimeout()
        socket.send(.string(text)) { [weak self, weak socket] error in
            guard let self, let socket, let error else { return }
            self.stateQueue.async {
                guard self.socket === socket, self.phase != .finished else { return }
                self.handleConnectionFailure(error.localizedDescription)
            }
        }
    }

    private func scheduleTimeout() {
        timeoutWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.stateQueue.async {
                guard let self, self.phase != .finished else { return }
                self.handleConnectionFailure("the gateway request timed out")
            }
        }
        timeoutWorkItem = item
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + 5,
            execute: item
        )
    }

    private func handleConnectionFailure(_ message: String) {
        if hasSentRuntimeRequest == false {
            disposeSocket()
            connectToNextEndpoint()
            return
        }
        finish(.failure(OpenClawRuntimeSettingsError.gateway(
            mutationAwareErrorMessage(message)
        )))
    }

    private func gatewayErrorMessage(from object: [String: Any]) -> String {
        let error = object["error"] as? [String: Any]
        return error?["message"] as? String ?? "The OpenClaw gateway denied the request."
    }

    private func mutationAwareErrorMessage(_ message: String) -> String {
        guard didApplyModel else { return message }
        return "The consult model was updated, but the gateway talk voice was not: \(message)"
    }

    private func finish(_ result: Result<OpenClawRuntimeSettings, Error>) {
        guard phase != .finished else { return }
        phase = .finished
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        disposeSocket()
        completion(result)
    }

    private func disposeSocket() {
        guard let socket else { return }
        self.socket = nil
        socket.onOpen = nil
        socket.onClose = nil
        socket.cancel(with: .normalClosure, reason: nil)
        socket.invalidateAndCancel()
    }

    private static func model(
        fromSessionsListPayload payload: [String: Any],
        sessionKey: String
    ) -> String? {
        guard let sessions = payload["sessions"] as? [[String: Any]],
              let session = sessions.first(where: {
                  ($0["key"] as? String) == sessionKey
              }) else {
            return nil
        }
        if let model = session["model"] as? String, model.isEmpty == false {
            if model.contains("/") {
                return model
            }
            if let provider = session["modelProvider"] as? String,
               provider.isEmpty == false {
                return "\(provider)/\(model)"
            }
            return model
        }
        return session["modelOverride"] as? String
    }

    private static func voice(fromTalkConfigPayload payload: [String: Any]) -> String? {
        let config = payload["config"] as? [String: Any] ?? payload
        let talk = config["talk"] as? [String: Any] ?? config
        guard let realtime = talk["realtime"] as? [String: Any],
              let providers = realtime["providers"] as? [String: Any],
              let openAI = providers["openai"] as? [String: Any] else {
            return nil
        }
        return openAI["voice"] as? String
    }

    private static var clientVersion: String {
        Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "dev"
    }
}
