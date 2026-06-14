import Foundation

final class OpenAIRealtimeProvider: NSObject, RealtimeVoiceProvider {
    let id: VoiceProviderID = .openAIRealtime
    let capabilities = VoiceProviderCapabilities(
        supportsSpeechToSpeech: true,
        supportsTextInput: true,
        supportsInterruptions: true,
        supportsFunctionCalling: true,
        supportsVisionInput: true,
        supportsProviderInterface: false
    )

    var onEvent: ((VoiceProviderEvent) -> Void)?

    private var configuration: VoiceSessionConfiguration
    private let apiKeyProvider: () -> String?
    private let audioEngine: RealtimeAudioEngine
    private lazy var urlSession = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    private var webSocketTask: URLSessionWebSocketTask?
    private var isConnected = false
    private var isStopping = false

    init(
        configuration: VoiceSessionConfiguration,
        apiKeyProvider: @escaping () -> String?,
        audioEngine: RealtimeAudioEngine = RealtimeAudioEngine()
    ) {
        self.configuration = configuration
        self.apiKeyProvider = apiKeyProvider
        self.audioEngine = audioEngine
    }

    func prepare() {
        guard apiKeyProvider()?.isEmpty == false else {
            emit(.status(.needsAttention("Add an OpenAI API key in Settings.")))
            return
        }
        emit(.status(.ready))
    }

    func update(configuration: VoiceSessionConfiguration) {
        self.configuration = configuration
        if isConnected {
            sendSessionUpdate()
        } else {
            prepare()
        }
    }

    func toggleVoice() {
        if isConnected {
            stopVoice()
        } else {
            startVoice()
        }
    }

    func stopVoice() {
        isStopping = true
        emit(.status(.stopping))
        sendJSON(["type": "response.cancel"])
        sendJSON(["type": "input_audio_buffer.clear"])
        audioEngine.stop()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        isConnected = false
        isStopping = false
        emit(.status(.ready))
    }

    private func startVoice() {
        guard let apiKey = apiKeyProvider(), apiKey.isEmpty == false else {
            emit(.status(.needsAttention("Add an OpenAI API key in Settings.")))
            return
        }

        emit(.status(.starting))
        audioEngine.requestMicrophoneAccess { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.emit(.status(.needsAttention(RealtimeAudioEngineError.microphoneDenied.localizedDescription)))
                return
            }
            self.connect(apiKey: apiKey)
        }
    }

    private func connect(apiKey: String) {
        var components = URLComponents(string: "wss://api.openai.com/v1/realtime")!
        components.queryItems = [
            URLQueryItem(name: "model", value: configuration.model)
        ]
        guard let url = components.url else {
            emit(.status(.needsAttention("Could not build the OpenAI Realtime URL.")))
            return
        }

        var request = URLRequest(url: url)
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let task = urlSession.webSocketTask(with: request)
        webSocketTask = task
        task.resume()
        isConnected = true
        receiveLoop()
        sendSessionUpdate()

        do {
            try audioEngine.start { [weak self] audio in
                self?.sendAudio(audio)
            }
            emit(.status(.listening))
        } catch {
            emit(.status(.needsAttention(error.localizedDescription)))
            stopVoice()
        }
    }

    private func sendSessionUpdate() {
        sendJSON([
            "type": "session.update",
            "session": [
                "type": "realtime",
                "model": configuration.model,
                "output_modalities": ["audio"],
                "audio": [
                    "input": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": 24_000
                        ],
                        "turn_detection": [
                            "type": "semantic_vad",
                            "eagerness": "auto",
                            "create_response": true,
                            "interrupt_response": true
                        ]
                    ],
                    "output": [
                        "format": [
                            "type": "audio/pcm"
                        ],
                        "voice": configuration.voice
                    ]
                ],
                "instructions": configuration.instructions
            ]
        ])
    }

    private func sendAudio(_ data: Data) {
        sendJSON([
            "type": "input_audio_buffer.append",
            "audio": data.base64EncodedString()
        ])
    }

    private func receiveLoop() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(message):
                self.handle(message)
                if self.webSocketTask != nil {
                    self.receiveLoop()
                }
            case let .failure(error):
                guard self.isStopping == false else { return }
                self.isConnected = false
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

extension OpenAIRealtimeProvider: URLSessionWebSocketDelegate {
    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        emit(.diagnostic("OpenAI Realtime WebSocket opened."))
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        guard isStopping == false else { return }
        isConnected = false
        audioEngine.stop()
        emit(.status(.ready))
    }
}
