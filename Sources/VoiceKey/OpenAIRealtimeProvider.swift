import Foundation

protocol OpenAIRealtimeWebSocketTaskProtocol: AnyObject {
    func resume()
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
    func send(
        _ message: URLSessionWebSocketTask.Message,
        completionHandler: @escaping @Sendable (Error?) -> Void
    )
    func receive(
        completionHandler: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void
    )
}

extension URLSessionWebSocketTask: OpenAIRealtimeWebSocketTaskProtocol {}

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
    var id: VoiceProviderID {
        syncOnStateQueue { configuration.providerID }
    }
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
    private let audioEngineProvider: () -> RealtimeAudioEngineProtocol
    private lazy var audioEngine = audioEngineProvider()
    private let webSocketTaskFactory: ((URLRequest) -> OpenAIRealtimeWebSocketTaskProtocol)?
    private let stateQueue = DispatchQueue(label: "VoiceKey.OpenAIRealtimeProvider")
    private let stateQueueKey = DispatchSpecificKey<UInt8>()
    private lazy var urlSession = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    private var webSocketTask: OpenAIRealtimeWebSocketTaskProtocol?
    private var activeModel: String?
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
        audioEngine: RealtimeAudioEngineProtocol? = nil,
        webSocketTaskFactory: ((URLRequest) -> OpenAIRealtimeWebSocketTaskProtocol)? = nil
    ) {
        self.configuration = configuration
        self.apiKeyProvider = apiKeyProvider
        if let audioEngine {
            self.audioEngineProvider = { audioEngine }
        } else {
            self.audioEngineProvider = { RealtimeAudioEngine() }
        }
        self.webSocketTaskFactory = webSocketTaskFactory
        super.init()
        stateQueue.setSpecific(key: stateQueueKey, value: 1)
    }

    func prepare() {
        syncOnStateQueue {
            prepareOnStateQueue()
        }
    }

    private func prepareOnStateQueue() {
        guard requiresAPIKey == false || apiKeyProvider()?.isEmpty == false else {
            emit(.status(.needsAttention("Add an OpenAI API key in Settings.")))
            return
        }
        emit(.status(.ready))
    }

    func update(configuration: VoiceSessionConfiguration) {
        syncOnStateQueue {
            updateOnStateQueue(configuration)
        }
    }

    private func updateOnStateQueue(_ configuration: VoiceSessionConfiguration) {
        self.configuration = configuration
        if isConnected {
            sendSessionUpdate(includeModel: false)
        } else if isStarting || isConnecting {
            emit(.status(.starting))
        } else {
            prepareOnStateQueue()
        }
    }

    func toggleVoice() {
        syncOnStateQueue {
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
        syncOnStateQueue {
            stopVoiceOnStateQueue()
        }
    }

    private func stopVoiceOnStateQueue() {
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
        activeModel = nil
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
            self.asyncOnStateQueue {
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

        let task = webSocketTaskFactory?(request) ?? urlSession.webSocketTask(with: request)
        webSocketTask = task
        activeModel = configuration.model
        isStarting = false
        isConnecting = true
        task.resume()
        receiveLoop(for: task, generation: generation)
    }

    private func startAudioStreaming() {
        guard isAudioStreaming == false else { return }
        isAudioStreaming = true
        do {
            try audioEngine.start(
                inputHandler: { [weak self] audio in
                    self?.asyncOnStateQueue {
                        self?.sendAudio(audio)
                    }
                },
                activityHandler: { [weak self] activity in
                    self?.asyncOnStateQueue {
                        self?.handleInputActivity(activity)
                    }
                }
            )
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
            activeModel = nil
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

    private func sendSessionUpdate(includeModel: Bool = true) {
        var sessionConfiguration = configuration
        if includeModel, let activeModel {
            sessionConfiguration.model = activeModel
        }
        sendJSON(OpenAIRealtimeRequestBuilder.sessionUpdateEvent(
            configuration: sessionConfiguration,
            includeModel: includeModel
        ))
    }

    private func sendAudio(_ data: Data) {
        sendJSON(OpenAIRealtimeRequestBuilder.inputAudioAppendEvent(audio: data))
    }

    private func receiveLoop(
        for task: OpenAIRealtimeWebSocketTaskProtocol,
        generation: Int
    ) {
        task.receive { [weak self, weak task] result in
            guard let self, let task else { return }
            self.asyncOnStateQueue {
                guard self.isCurrent(task: task, generation: generation),
                      self.isStopping == false else { return }
                switch result {
                case let .success(message):
                    self.handle(message)
                    guard self.isCurrent(task: task, generation: generation),
                          self.isStopping == false else { return }
                    self.receiveLoop(for: task, generation: generation)
                case let .failure(error):
                    self.webSocketTask = nil
                    self.activeModel = nil
                    self.isConnecting = false
                    self.isConnected = false
                    self.isAudioStreaming = false
                    self.audioEngine.stop()
                    self.emit(.status(.needsAttention(error.localizedDescription)))
                }
            }
        }
    }

    private func isCurrent(
        task: OpenAIRealtimeWebSocketTaskProtocol,
        generation: Int
    ) -> Bool {
        guard let currentTask = webSocketTask else { return false }
        return currentTask === task && startGeneration == generation
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
        guard let task = webSocketTask,
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else {
            return
        }
        let generation = startGeneration
        task.send(.string(text)) { [weak self, weak task] error in
            guard let self, let task, let error else { return }
            self.asyncOnStateQueue {
                guard self.isCurrent(task: task, generation: generation),
                      self.isStopping == false else { return }
                self.emit(.status(.needsAttention(error.localizedDescription)))
            }
        }
    }

    private func syncOnStateQueue<T>(_ work: () -> T) -> T {
        if DispatchQueue.getSpecific(key: stateQueueKey) != nil {
            return work()
        }
        return stateQueue.sync(execute: work)
    }

    private func asyncOnStateQueue(_ work: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: stateQueueKey) != nil {
            work()
        } else {
            stateQueue.async(execute: work)
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
        syncOnStateQueue {
            checkConnectionOnStateQueue()
        }
    }

    private func checkConnectionOnStateQueue() {
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
            guard let self else { return }
            self.asyncOnStateQueue {
                guard self.connectionCheck === check else { return }
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
}

extension OpenAIRealtimeProvider: URLSessionWebSocketDelegate {
    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        webSocketDidOpen(webSocketTask)
    }

    func webSocketDidOpen(_ task: OpenAIRealtimeWebSocketTaskProtocol) {
        syncOnStateQueue {
            guard let currentTask = webSocketTask,
                  currentTask === task,
                  isStopping == false else { return }
            isConnecting = false
            isConnected = true
            emit(.diagnostic("OpenAI Realtime WebSocket opened."))
            sendSessionUpdate()
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        syncOnStateQueue {
            guard let currentTask = self.webSocketTask,
                  currentTask === webSocketTask,
                  isStopping == false else { return }
            self.webSocketTask = nil
            activeModel = nil
            isConnecting = false
            isConnected = false
            isAudioStreaming = false
            isStarting = false
            audioEngine.stop()
            emit(.status(OpenAIRealtimeConnectionDiagnostics.closeStatus(code: closeCode, reason: reason)))
        }
    }
}
