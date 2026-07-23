import Foundation

/// Pure decision behind `toggleVoice()`: any live session state — including a
/// session that is only streaming audio — must toggle to a full stop, never to
/// a second start that would abandon the running audio engine.
enum VoiceToggleDecision: Equatable {
    case start
    case stop

    static func decide(isStarting: Bool, isConnecting: Bool, isConnected: Bool, isAudioStreaming: Bool) -> VoiceToggleDecision {
        isStarting || isConnecting || isConnected || isAudioStreaming ? .stop : .start
    }
}

final class OpenAIRealtimeProvider: NSObject, RealtimeVoiceProvider {
    var id: VoiceProviderID { configuration.providerID }
    let capabilities = VoiceProviderCapabilities(
        supportsSpeechToSpeech: true,
        supportsTextInput: true,
        supportsInterruptions: true,
        supportsFunctionCalling: true,
        supportsVisionInput: true,
        supportsProviderInterface: false,
        supportsConnectionCheck: true
    )

    var onEvent: ((VoiceProviderEvent) -> Void)?

    private var configuration: VoiceSessionConfiguration
    private let apiKeyProvider: () -> String?
    private let audioEngine: RealtimeAudioEngineProtocol
    private lazy var urlSession = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    private var webSocketTask: URLSessionWebSocketTask?
    private var connectionCheck: OpenAIRealtimeConnectionCheck?
    private var startGeneration = 0
    private var isStarting = false
    private var isConnecting = false
    private var isConnected = false
    private var isAudioStreaming = false
    private var isStopping = false
    private var hasReportedMicrophoneAudio = false
    private var hasReportedMicrophoneSignal = false

    init(
        configuration: VoiceSessionConfiguration,
        apiKeyProvider: @escaping () -> String?,
        audioEngine: RealtimeAudioEngineProtocol = RealtimeAudioEngine()
    ) {
        self.configuration = configuration
        self.apiKeyProvider = apiKeyProvider
        self.audioEngine = audioEngine
    }

    func prepare() {
        guard requiresAPIKey == false || apiKeyProvider()?.isEmpty == false else {
            emit(.status(.needsAttention("Add an OpenAI API key in Settings.")))
            return
        }
        emit(.status(.ready))
    }

    func update(configuration: VoiceSessionConfiguration) {
        self.configuration = configuration
        if isConnected {
            sendSessionUpdate()
        } else if isStarting || isConnecting {
            emit(.status(.starting))
        } else {
            prepare()
        }
    }

    func toggleVoice() {
        switch VoiceToggleDecision.decide(
            isStarting: isStarting,
            isConnecting: isConnecting,
            isConnected: isConnected,
            isAudioStreaming: isAudioStreaming
        ) {
        case .stop:
            stopVoice()
        case .start:
            startVoice()
        }
    }

    func stopVoice() {
        startGeneration += 1
        isStopping = true
        emit(.status(.stopping))
        if isConnected {
            sendJSON(OpenAIRealtimeRequestBuilder.responseCancelEvent)
            sendJSON(OpenAIRealtimeRequestBuilder.inputAudioBufferClearEvent)
        }
        audioEngine.stop()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        self.webSocketTask = nil
        isStarting = false
        isConnecting = false
        isConnected = false
        isAudioStreaming = false
        isStopping = false
        hasReportedMicrophoneAudio = false
        hasReportedMicrophoneSignal = false
        emit(.status(.ready))
    }

    private func startVoice() {
        let apiKey = apiKeyProvider() ?? ""
        guard requiresAPIKey == false || apiKey.isEmpty == false else {
            emit(.status(.needsAttention("Add an OpenAI API key in Settings.")))
            return
        }

        startGeneration += 1
        let generation = startGeneration
        isStarting = true
        hasReportedMicrophoneAudio = false
        hasReportedMicrophoneSignal = false
        emit(.status(.starting))
        audioEngine.requestMicrophoneAccess { [weak self] granted in
            guard let self else { return }
            guard self.startGeneration == generation,
                  self.isStarting,
                  self.isStopping == false else { return }
            guard granted else {
                self.isStarting = false
                self.emit(.status(.needsAttention(RealtimeAudioEngineError.microphoneDenied.localizedDescription)))
                return
            }
            self.connect(apiKey: apiKey, generation: generation)
        }
    }

    private var requiresAPIKey: Bool {
        configuration.providerID.requiresAPIKey
    }

    private func connect(apiKey: String, generation: Int) {
        guard startGeneration == generation,
              isStarting,
              isStopping == false else { return }

        guard let request = OpenAIRealtimeRequestBuilder.webSocketRequest(
            baseURL: OpenAIRealtimeRequestBuilder.normalizedBaseURL(for: configuration.endpointURL),
            apiKey: apiKey,
            configuration: configuration
        ) else {
            isStarting = false
            emit(.status(.needsAttention("Could not build the OpenAI Realtime URL.")))
            return
        }

        let task = urlSession.webSocketTask(with: request)
        webSocketTask = task
        isStarting = false
        isConnecting = true
        task.resume()
        receiveLoop()
    }

    private func startAudioStreaming() {
        guard isAudioStreaming == false else { return }
        isAudioStreaming = true
        do {
            try audioEngine.start(
                inputHandler: { [weak self] audio in
                    self?.sendAudio(audio)
                },
                activityHandler: { [weak self] activity in
                    self?.handleInputActivity(activity)
                }
            )
            // stopVoice() runs on the main thread while this runs on the URLSession
            // delegate queue. If a stop landed while the engine was starting, the
            // engine may be running for a session that no longer exists — tear it
            // down instead of leaking the microphone.
            guard isConnected, isStopping == false else {
                isAudioStreaming = false
                audioEngine.stop()
                return
            }
            emit(.status(.listening))
        } catch {
            audioEngine.stop()
            webSocketTask?.cancel(with: .normalClosure, reason: nil)
            webSocketTask = nil
            isConnecting = false
            isConnected = false
            isAudioStreaming = false
            emit(.status(.needsAttention(error.localizedDescription)))
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
    }

    private func sendSessionUpdate() {
        sendJSON(OpenAIRealtimeRequestBuilder.sessionUpdateEvent(configuration: configuration))
    }

    private func sendAudio(_ data: Data) {
        sendJSON(OpenAIRealtimeRequestBuilder.inputAudioAppendEvent(audio: data))
    }

    private func receiveLoop() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(message):
                guard self.webSocketTask != nil, self.isStopping == false else { return }
                self.handle(message)
                if self.webSocketTask != nil {
                    self.receiveLoop()
                }
            case let .failure(error):
                guard self.webSocketTask != nil, self.isStopping == false else { return }
                self.webSocketTask = nil
                self.isConnecting = false
                self.isConnected = false
                self.isAudioStreaming = false
                self.audioEngine.stop()
                self.emit(.status(.needsAttention(error.localizedDescription)))
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
        for action in OpenAIRealtimeEventMapper.actions(from: text) {
            switch action {
            case let .audio(audio):
                audioEngine.playPCM16(audio)
            case .sessionUpdated:
                guard isConnected else { break }
                startAudioStreaming()
            case .stopPlayback:
                audioEngine.stopPlayback()
            case let .providerEvent(event):
                emit(event)
            }
        }
    }

    private func sendJSON(_ object: [String: Any]) {
        guard let webSocketTask,
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else {
            return
        }
        webSocketTask.send(.string(text)) { [weak self] error in
            if let error {
                self?.emit(.status(.needsAttention(error.localizedDescription)))
            }
        }
    }

    private func emit(_ event: VoiceProviderEvent) {
        DispatchQueue.main.async { [weak self] in
            self?.onEvent?(event)
        }
    }
}

extension OpenAIRealtimeProvider: VoiceProviderConnectionChecking {
    func checkConnection() {
        let apiKey = apiKeyProvider() ?? ""
        guard requiresAPIKey == false || apiKey.isEmpty == false else {
            emit(.status(.needsAttention("Add an OpenAI API key in Settings.")))
            return
        }

        emit(.status(.checking))
        emit(.diagnostic("Checking OpenAI Realtime API connection."))

        let check = OpenAIRealtimeConnectionCheck(apiKey: apiKey, configuration: configuration)
        connectionCheck = check
        check.start { [weak self, weak check] result in
            guard let self, self.connectionCheck === check else { return }
            self.connectionCheck = nil
            switch result {
            case let .success(eventTypes):
                self.emit(.diagnostic("OpenAI Realtime API check succeeded: \(eventTypes.joined(separator: ", "))."))
                self.emit(.status(.ready))
            case let .failure(message):
                self.emit(.status(.needsAttention(message)))
            }
        }
    }
}

extension OpenAIRealtimeProvider: URLSessionWebSocketDelegate {
    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        guard let currentTask = self.webSocketTask,
              currentTask === webSocketTask,
              isStopping == false else { return }
        isConnecting = false
        isConnected = true
        emit(.diagnostic("OpenAI Realtime WebSocket opened."))
        sendSessionUpdate()
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        guard let currentTask = self.webSocketTask,
              currentTask === webSocketTask,
              isStopping == false else { return }
        self.webSocketTask = nil
        isConnecting = false
        isConnected = false
        isAudioStreaming = false
        isStarting = false
        audioEngine.stop()
        emit(.status(OpenAIRealtimeConnectionDiagnostics.closeStatus(code: closeCode, reason: reason)))
    }
}
