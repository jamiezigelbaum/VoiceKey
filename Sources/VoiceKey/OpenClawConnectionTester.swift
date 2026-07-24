import Foundation

enum OpenClawConnectionOutcome: Equatable {
    case ok(serverVersion: String, scopes: [String])
    case pairingRequired(
        reason: String?,
        requestID: String?,
        remediationHint: String?
    )
    case gatewayTokenMissing
    case gatewayTokenMismatch
    case deviceTokenMismatch
    case unreachable(endpointsTried: [String])
    case failed(code: String, message: String)
}

enum OpenClawConnectionOutcomeMapper {
    static func outcome(from text: String) -> OpenClawConnectionOutcome? {
        guard let data = text.data(using: .utf8),
              let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              response["type"] as? String == "res",
              response["id"] as? String == OpenClawTalkRequestBuilder.connectRequestID else {
            return nil
        }

        if (response["ok"] as? Bool) != false,
           response["error"] == nil {
            let result = (response["result"] as? [String: Any])
                ?? (response["payload"] as? [String: Any])
            guard result?["type"] as? String == "hello-ok" else {
                return .failed(
                    code: "INVALID_HELLO",
                    message: "OpenClaw gateway returned an invalid hello response."
                )
            }
            let server = result?["server"] as? [String: Any]
            let auth = result?["auth"] as? [String: Any]
            return .ok(
                serverVersion: server?["version"] as? String ?? "Unknown",
                scopes: auth?["scopes"] as? [String] ?? []
            )
        }

        let error = response["error"] as? [String: Any]
        let details = error?["details"] as? [String: Any]
        let code = error?["code"] as? String ?? "UNKNOWN"
        let detailCode = details?["code"] as? String
        let message = error?["message"] as? String ?? "OpenClaw gateway request failed."

        if code == "NOT_PAIRED" || detailCode == "PAIRING_REQUIRED" {
            return .pairingRequired(
                reason: details?["reason"] as? String,
                requestID: details?["requestId"] as? String,
                remediationHint: details?["remediationHint"] as? String
            )
        }
        switch detailCode {
        case "AUTH_TOKEN_MISSING":
            return .gatewayTokenMissing
        case "AUTH_TOKEN_MISMATCH":
            return .gatewayTokenMismatch
        case "AUTH_DEVICE_TOKEN_MISMATCH":
            return .deviceTokenMismatch
        default:
            return .failed(code: detailCode ?? code, message: message)
        }
    }
}

protocol OpenClawConnectionTestCancellation: AnyObject {
    func cancel()
}

protocol OpenClawConnectionTesting: AnyObject {
    @discardableResult
    func testConnection(
        endpointURL: String,
        completion: @escaping (OpenClawConnectionOutcome) -> Void
    ) -> OpenClawConnectionTestCancellation
}

final class OpenClawConnectionTester: OpenClawConnectionTesting {
    private let lock = NSLock()
    private var runs: [UUID: OpenClawConnectionTestRun] = [:]
    private let tokenProvider: () -> String?
    private let deviceCredentialsProvider: () -> OpenClawDeviceCredentials?
    private let webSocketFactory: OpenClawTalkWebSocketFactory
    private let watchdogScheduler: OpenClawTalkWatchdogScheduler
    private let now: () -> Date

    init(
        tokenProvider: @escaping () -> String? = {
            OpenClawTokenResolver.resolveGatewayToken(
                apiKeyProvider: { APIKeyStore.shared.apiKey(for: .openClaw) }
            )
        },
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
        now: @escaping () -> Date = Date.init
    ) {
        self.tokenProvider = tokenProvider
        self.deviceCredentialsProvider = deviceCredentialsProvider
        self.webSocketFactory = webSocketFactory
        self.watchdogScheduler = watchdogScheduler
        self.now = now
    }

    @discardableResult
    func testConnection(
        endpointURL: String,
        completion: @escaping (OpenClawConnectionOutcome) -> Void
    ) -> OpenClawConnectionTestCancellation {
        guard let token = tokenProvider()?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            token.isEmpty == false else {
            let cancellation = OpenClawCompletedConnectionTest()
            DispatchQueue.main.async {
                completion(.gatewayTokenMissing)
            }
            return cancellation
        }

        let id = UUID()
        let run = OpenClawConnectionTestRun(
            endpoints: OpenClawTalkRequestBuilder.endpointCandidates(endpointURL: endpointURL),
            token: token,
            deviceCredentials: deviceCredentialsProvider(),
            webSocketFactory: webSocketFactory,
            watchdogScheduler: watchdogScheduler,
            now: now
        ) { [weak self] outcome in
            self?.lock.withLock {
                self?.runs[id] = nil
            }
            DispatchQueue.main.async {
                completion(outcome)
            }
        }
        lock.withLock {
            runs[id] = run
        }
        run.start()
        return run
    }
}

private final class OpenClawCompletedConnectionTest: OpenClawConnectionTestCancellation {
    func cancel() {}
}

private final class OpenClawConnectionTestRun: OpenClawConnectionTestCancellation {
    private let queue = DispatchQueue(label: "VoiceKey.OpenClawConnectionTester")
    private let endpoints: [String]
    private let token: String
    private let deviceCredentials: OpenClawDeviceCredentials?
    private let webSocketFactory: OpenClawTalkWebSocketFactory
    private let watchdogScheduler: OpenClawTalkWatchdogScheduler
    private let now: () -> Date
    private var completion: ((OpenClawConnectionOutcome) -> Void)?
    private var endpointIndex = 0
    private var endpointsTried: [String] = []
    private var socket: OpenClawTalkWebSocket?
    private var watchdog: OpenClawTalkWatchdogCancellation?
    private var isFinished = false
    private var omitDeviceTokenForConnect = false
    private var hasRetriedWithoutDeviceToken = false

    init(
        endpoints: [String],
        token: String,
        deviceCredentials: OpenClawDeviceCredentials?,
        webSocketFactory: @escaping OpenClawTalkWebSocketFactory,
        watchdogScheduler: @escaping OpenClawTalkWatchdogScheduler,
        now: @escaping () -> Date,
        completion: @escaping (OpenClawConnectionOutcome) -> Void
    ) {
        self.endpoints = endpoints
        self.token = token
        self.deviceCredentials = deviceCredentials
        self.webSocketFactory = webSocketFactory
        self.watchdogScheduler = watchdogScheduler
        self.now = now
        self.completion = completion
    }

    func start() {
        queue.async { [weak self] in
            self?.connectToNextEndpoint()
        }
    }

    func cancel() {
        queue.async { [weak self] in
            self?.finishWithoutCallback()
        }
    }

    private func connectToNextEndpoint() {
        guard isFinished == false else { return }
        disposeSocket()
        guard endpointIndex < endpoints.count else {
            finish(.unreachable(endpointsTried: endpointsTried))
            return
        }

        let endpoint = endpoints[endpointIndex]
        endpointIndex += 1
        endpointsTried.append(endpoint)
        guard let request = OpenClawTalkRequestBuilder.webSocketRequest(endpoint: endpoint) else {
            connectToNextEndpoint()
            return
        }

        let newSocket = webSocketFactory(request)
        socket = newSocket
        newSocket.onOpen = { [weak self, weak newSocket] in
            self?.queue.async {
                guard let self, let newSocket, self.socket === newSocket else { return }
                self.receiveNext(from: newSocket)
            }
        }
        newSocket.onClose = { [weak self, weak newSocket] _ in
            self?.queue.async {
                guard let self, let newSocket, self.socket === newSocket else { return }
                self.connectToNextEndpoint()
            }
        }
        watchdog = watchdogScheduler(OpenClawTalkRequestBuilder.connectTimeout) { [weak self] in
            self?.queue.async {
                self?.connectToNextEndpoint()
            }
        }
        newSocket.resume()
    }

    private func receiveNext(from socket: OpenClawTalkWebSocket) {
        socket.receive { [weak self, weak socket] result in
            self?.queue.async {
                guard let self, let socket, self.socket === socket else { return }
                switch result {
                case let .success(message):
                    self.handle(message, from: socket)
                case .failure:
                    self.connectToNextEndpoint()
                }
            }
        }
    }

    private func handle(
        _ message: URLSessionWebSocketTask.Message,
        from socket: OpenClawTalkWebSocket
    ) {
        let text: String?
        switch message {
        case let .string(value):
            text = value
        case let .data(data):
            text = String(data: data, encoding: .utf8)
        @unknown default:
            text = nil
        }
        guard let text else {
            receiveNext(from: socket)
            return
        }

        if let outcome = OpenClawConnectionOutcomeMapper.outcome(from: text) {
            if outcome == .deviceTokenMismatch,
               retryConnectWithoutDeviceToken() {
                return
            }
            finish(outcome)
            return
        }
        if let nonce = OpenClawTalkEventMapper.connectChallengeNonce(from: text) {
            sendConnectFrame(nonce: nonce, over: socket)
        }
        receiveNext(from: socket)
    }

    private func sendConnectFrame(nonce: String, over socket: OpenClawTalkWebSocket) {
        let frame: [String: Any]
        if let credentials = deviceCredentials,
           let proof = makeDeviceProof(credentials: credentials, nonce: nonce) {
            frame = OpenClawTalkRequestBuilder.connectFrame(
                token: token,
                clientVersion: clientVersion,
                scopes: credentials.operatorScopes,
                deviceToken: omitDeviceTokenForConnect
                    ? nil
                    : credentials.operatorToken,
                deviceProof: proof
            )
        } else {
            frame = OpenClawTalkRequestBuilder.connectFrame(
                token: token,
                clientVersion: clientVersion
            )
        }
        guard let data = try? JSONSerialization.data(withJSONObject: frame),
              let text = String(data: data, encoding: .utf8) else {
            finish(.failed(
                code: "INVALID_CONNECT_FRAME",
                message: "VoiceKey could not create the OpenClaw connection request."
            ))
            return
        }
        socket.send(.string(text)) { [weak self, weak socket] error in
            guard error != nil else { return }
            self?.queue.async {
                guard let self, let socket, self.socket === socket else { return }
                self.connectToNextEndpoint()
            }
        }
    }

    private func retryConnectWithoutDeviceToken() -> Bool {
        guard deviceCredentials != nil,
              hasRetriedWithoutDeviceToken == false else {
            return false
        }
        hasRetriedWithoutDeviceToken = true
        omitDeviceTokenForConnect = true
        endpointIndex = max(0, endpointIndex - 1)
        connectToNextEndpoint()
        return true
    }

    private func makeDeviceProof(
        credentials: OpenClawDeviceCredentials,
        nonce: String
    ) -> OpenClawDeviceProof? {
        let signedAtMs = Int64(now().timeIntervalSince1970 * 1_000)
        let payload = OpenClawConnectSigner.signaturePayload(
            deviceID: credentials.deviceID,
            clientID: OpenClawTalkRequestBuilder.clientID,
            clientMode: OpenClawTalkRequestBuilder.clientMode,
            role: OpenClawTalkRequestBuilder.role,
            scopes: credentials.operatorScopes,
            signedAtMs: signedAtMs,
            token: token,
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

    private var clientVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    private func finish(_ outcome: OpenClawConnectionOutcome) {
        guard isFinished == false else { return }
        isFinished = true
        watchdog?.cancel()
        watchdog = nil
        disposeSocket()
        let callback = completion
        completion = nil
        callback?(outcome)
    }

    private func finishWithoutCallback() {
        guard isFinished == false else { return }
        isFinished = true
        watchdog?.cancel()
        watchdog = nil
        disposeSocket()
        completion = nil
    }

    private func disposeSocket() {
        watchdog?.cancel()
        watchdog = nil
        guard let socket else { return }
        self.socket = nil
        socket.onOpen = nil
        socket.onClose = nil
        socket.cancel(with: .normalClosure, reason: nil)
        socket.invalidateAndCancel()
    }
}
