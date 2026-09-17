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
    private lazy var audioEngine: RealtimeAudioEngineProtocol = {
        let engine = audioEngineProvider()
        engine.setFatalFailureHandler { [weak self] in
            self?.asyncOnStateQueue { [weak self] in
                self?.handleFatalAudioFailure()
            }
        }
        engine.setStateChangeHandler { [weak self] state in
            self?.asyncOnStateQueue { [weak self] in
                self?.adoptAudioEngineState(
                    state,
                    resendSessionOnModeChange: true
                )
            }
        }
        audioEngineState = engine.stateSnapshot()
        return engine
    }()
    private let webSocketTaskFactory: ((URLRequest) -> OpenAIRealtimeWebSocketTaskProtocol)?
    private let webSearcher: OpenAIWebSearching
    private let webSearchTimeout: TimeInterval
    private let now: () -> Date
    private let gateNow: () -> Date
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
    private var sessionStart: Date?
    private var isResponseInFlight = false
    private var isMCPContinuationPending = false
    private var consecutiveMCPContinuationCount = 0
    private var audioEngineState: RealtimeAudioEngineState?
    /// True between the server finishing its audio and the speaker going quiet.
    private var isAwaitingPlaybackDrain = false
    /// Scopes the drain watchdog to the turn that armed it. A session-level
    /// guard is not enough: a watchdog left over from an interrupted turn would
    /// fire during a later one and report listening while she is speaking.
    private var playbackDrainToken = UUID()
    private static let playbackDrainTimeout: TimeInterval = 30
    private var speakerGate = OpenAIRealtimeSpeakerGate()
    private var currentAssistantMessageItemID: String?
    private var lastSessionSpeakerMode: Bool?
    private var hasReportedAECFallback = false
    private var pendingWebSearches: [String: Int] = [:]

    private static let fatalAudioFailureMessage =
        "Microphone audio stopped after repeated audio device failures. Start the voice session again."
    private static let maximumConsecutiveMCPContinuations = 8

    init(
        configuration: VoiceSessionConfiguration,
        apiKeyProvider: @escaping () -> String?,
        audioEngine: RealtimeAudioEngineProtocol? = nil,
        webSocketTaskFactory: ((URLRequest) -> OpenAIRealtimeWebSocketTaskProtocol)? = nil,
        webSearcher: OpenAIWebSearching =
            OpenAIResponsesWebSearchClient(),
        webSearchTimeout: TimeInterval = 20,
        now: @escaping () -> Date = Date.init,
        gateNow: @escaping () -> Date = Date.init
    ) {
        self.configuration = configuration
        self.apiKeyProvider = apiKeyProvider
        if let audioEngine {
            self.audioEngineProvider = { audioEngine }
        } else {
            self.audioEngineProvider = { RealtimeAudioEngine() }
        }
        self.webSocketTaskFactory = webSocketTaskFactory
        self.webSearcher = webSearcher
        self.webSearchTimeout = webSearchTimeout
        self.now = now
        self.gateNow = gateNow
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
        sessionStart = nil
        isStarting = false
        isConnecting = false
        isConnected = false
        isAudioStreaming = false
        isStopping = false
        hasReportedMicrophoneAudio = false
        hasReportedMicrophoneSignal = false
        resetMCPContinuationState()
        pendingWebSearches.removeAll()
        resetSpeakerModeState()
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

        resetMCPContinuationState()
        pendingWebSearches.removeAll()
        resetSpeakerModeState()
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
        sessionStart = now()
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
            sessionStart = nil
            isConnecting = false
            isConnected = false
            isAudioStreaming = false
            resetMCPContinuationState()
            pendingWebSearches.removeAll()
            resetSpeakerModeState()
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

        refreshAudioEngineState(resendSessionOnModeChange: true)
        guard currentAssistantMessageItemID != nil else {
            speakerGate.resetActivity()
            return
        }
        guard speakerGate.observe(activity, at: gateNow()) else { return }
        interruptAssistantPlayback()
    }

    private func handleFatalAudioFailure() {
        guard isAudioStreaming else { return }
        isAudioStreaming = false
        stopVoiceOnStateQueue()
        emit(.status(.needsAttention(Self.fatalAudioFailureMessage)))
    }

    private func sendSessionUpdate(includeModel: Bool = true) {
        // The engine can remain instantiated between sessions, so read the
        // default output device again before choosing the initial contract.
        audioEngine.refreshOutputRoute()
        refreshAudioEngineState(resendSessionOnModeChange: false)
        var sessionConfiguration = configuration
        if includeModel, let activeModel {
            sessionConfiguration.model = activeModel
        }
        let speakerMode = effectiveSpeakerMode()
        speakerGate.setSpeakerMode(speakerMode)
        sendJSON(OpenAIRealtimeRequestBuilder.sessionUpdateEvent(
            configuration: sessionConfiguration,
            speakerMode: speakerMode,
            includeModel: includeModel,
            sessionStart: sessionStart ?? now()
        ))
        lastSessionSpeakerMode = speakerMode
    }

    private func sendAudio(_ data: Data) {
        refreshAudioEngineState(resendSessionOnModeChange: true)
        guard speakerGate.isGateClosed(at: gateNow()) == false else { return }
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
                    self.sessionStart = nil
                    self.isConnecting = false
                    self.isConnected = false
                    self.isAudioStreaming = false
                    self.resetMCPContinuationState()
                    self.pendingWebSearches.removeAll()
                    self.resetSpeakerModeState()
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
            case .responseStarted:
                isResponseInFlight = true
                currentAssistantMessageItemID = nil
                speakerGate.beginAssistantTurn()
            case .responseEnded:
                isResponseInFlight = false
                sendPendingMCPContinuationIfNeeded()
            case let .assistantMessageStarted(itemID):
                currentAssistantMessageItemID = itemID
                speakerGate.beginAssistantTurn()
                audioEngine.beginAssistantAudioTurn()
            case .assistantAudioComplete:
                handleAssistantAudioComplete()
            case let .webSearchFunctionCall(callID, arguments):
                handleWebSearchFunctionCall(
                    callID: callID,
                    arguments: arguments
                )
            case .mcpCallTerminated:
                handleMCPCallTermination()
            case .stopPlayback:
                // The owner cut her off: the mapper already reports listening,
                // so cancel the hold without emitting a second one.
                endPlaybackDrain(emitListening: false)
                refreshAudioEngineState(resendSessionOnModeChange: true)
                if speakerGate.isSpeakerMode,
                   audioEngineState?.isPlaybackActive == true {
                    // In speaker mode the mic gate and local energy threshold
                    // own interruption. A server speech_started event must not
                    // let leaked speaker audio stop its own response.
                    break
                }
                isMCPContinuationPending = false
                consecutiveMCPContinuationCount = 0
                audioEngine.stopPlayback()
            case let .providerEvent(event):
                emit(event)
            }
        }
    }

    private func handleMCPCallTermination() {
        guard isResponseInFlight == false else {
            isMCPContinuationPending = true
            return
        }
        sendMCPContinuation()
    }

    private func handleWebSearchFunctionCall(
        callID: String,
        arguments: String
    ) {
        guard pendingWebSearches[callID] == nil else { return }
        guard configuration.providerID == .openAIRealtime,
              configuration.webSearchEnabled else {
            finishWebSearch(
                callID: callID,
                output:
                    "Web search is turned off for this voice channel.",
                outcome: "disabled"
            )
            return
        }
        guard let query = Self.webSearchQuery(
            from: arguments
        ) else {
            finishWebSearch(
                callID: callID,
                output:
                    "Web search could not run because no valid query was provided.",
                outcome: "invalid_arguments"
            )
            return
        }
        let apiKey = apiKeyProvider() ?? ""
        guard apiKey.isEmpty == false else {
            finishWebSearch(
                callID: callID,
                result: .failure(.missingAPIKey)
            )
            return
        }

        let generation = startGeneration
        pendingWebSearches[callID] = generation
        emit(.diagnostic(
            "Built-in web search started (query length: \(query.count))."
        ))
        stateQueue.asyncAfter(
            deadline: .now() + webSearchTimeout
        ) { [weak self] in
            guard let self,
                  self.pendingWebSearches[callID] == generation
            else {
                return
            }
            self.finishWebSearch(
                callID: callID,
                result: .failure(.timedOut)
            )
        }
        webSearcher.search(
            query: query,
            apiKey: apiKey
        ) { [weak self] result in
            self?.asyncOnStateQueue { [weak self] in
                guard let self,
                      self.pendingWebSearches[callID] == generation
                else {
                    return
                }
                self.finishWebSearch(
                    callID: callID,
                    result: result
                )
            }
        }
    }

    private static func webSearchQuery(
        from arguments: String
    ) -> String? {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(
                with: data
              ) as? [String: Any],
              let query = object["query"] as? String
        else {
            return nil
        }
        let trimmed = query.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return trimmed.isEmpty ? nil : trimmed
    }

    private func finishWebSearch(
        callID: String,
        result: OpenAIWebSearchResult
    ) {
        switch result {
        case let .success(output):
            finishWebSearch(
                callID: callID,
                output: output,
                outcome: "success"
            )
        case let .failure(failure):
            finishWebSearch(
                callID: callID,
                output: failure.functionOutput,
                outcome: failure.diagnosticCategory
            )
        }
    }

    private func finishWebSearch(
        callID: String,
        output: String,
        outcome: String
    ) {
        pendingWebSearches.removeValue(forKey: callID)
        emit(.diagnostic(
            "Built-in web search finished (outcome: \(outcome))."
        ))
        sendJSON(
            OpenAIRealtimeRequestBuilder.functionCallOutputEvent(
                callID: callID,
                output: output
            )
        )
        sendJSON(["type": "response.create"])
    }

    private func sendPendingMCPContinuationIfNeeded() {
        guard isMCPContinuationPending else { return }
        sendMCPContinuation()
    }

    private func sendMCPContinuation() {
        isMCPContinuationPending = false
        guard consecutiveMCPContinuationCount < Self.maximumConsecutiveMCPContinuations else {
            return
        }
        consecutiveMCPContinuationCount += 1
        sendJSON(["type": "response.create"])
    }

    private func resetMCPContinuationState() {
        isResponseInFlight = false
        isMCPContinuationPending = false
        consecutiveMCPContinuationCount = 0
    }

    private func refreshAudioEngineState(resendSessionOnModeChange: Bool) {
        adoptAudioEngineState(
            audioEngine.stateSnapshot(),
            resendSessionOnModeChange: resendSessionOnModeChange
        )
    }

    /// The server finishing its audio is not the assistant finishing speaking:
    /// the buffer usually has seconds left to play. Reporting `listening` at
    /// that moment made the menu-bar animation stop while she was still audibly
    /// talking (owner report, 2026-07-30). Hold the speaking state until local
    /// playback actually drains.
    private func handleAssistantAudioComplete() {
        guard audioEngineState?.isPlaybackActive == true else {
            endPlaybackDrain(emitListening: true)
            return
        }
        isAwaitingPlaybackDrain = true
        playbackDrainToken = UUID()
        armPlaybackDrainWatchdog(token: playbackDrainToken)
    }

    /// One way out of the waiting state, so no path can leave it stuck on.
    private func endPlaybackDrain(emitListening: Bool) {
        isAwaitingPlaybackDrain = false
        playbackDrainToken = UUID()
        if emitListening {
            emit(.status(.listening))
        }
    }

    /// Playback state arrives from the audio engine, and a wedged or silently
    /// failed engine would otherwise leave the app claiming she is still
    /// speaking forever.
    private func armPlaybackDrainWatchdog(token: UUID) {
        stateQueue.asyncAfter(
            deadline: .now() + Self.playbackDrainTimeout
        ) { [weak self] in
            guard let self,
                  self.isAwaitingPlaybackDrain,
                  self.playbackDrainToken == token
            else {
                return
            }
            self.endPlaybackDrain(emitListening: true)
        }
    }

    private func adoptAudioEngineState(
        _ state: RealtimeAudioEngineState,
        resendSessionOnModeChange: Bool
    ) {
        audioEngineState = state
        let speakerMode = effectiveSpeakerMode()
        speakerGate.setSpeakerMode(speakerMode)
        speakerGate.updatePlayback(isActive: state.isPlaybackActive, at: gateNow())

        if isAwaitingPlaybackDrain, state.isPlaybackActive == false {
            endPlaybackDrain(emitListening: true)
        }

        if state.isEchoCancellationActive {
            hasReportedAECFallback = false
        } else if hasReportedAECFallback == false {
            hasReportedAECFallback = true
            emit(.diagnostic(
                "Echo cancellation is inactive; forcing speaker-mode microphone gating."
            ))
        }

        if resendSessionOnModeChange,
           isConnected,
           let lastSessionSpeakerMode,
           lastSessionSpeakerMode != speakerMode {
            sendSessionUpdate(includeModel: false)
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

    private func interruptAssistantPlayback() {
        guard let itemID = currentAssistantMessageItemID else { return }
        // A loud reply during the post-playback hangover trips the gate too,
        // but with playback finished there is nothing to cancel or truncate —
        // the user heard everything, and a response.cancel with no active
        // response makes the server emit an error event that would surface
        // as a spurious needsAttention. The gate latch opening the mic is
        // the whole interruption in that window.
        guard audioEngineState?.isPlaybackActive == true else { return }
        let playedMilliseconds =
            audioEngineState?.currentAssistantPlayedDurationMilliseconds ?? 0
        audioEngine.stopPlayback()
        // Live verification on 2026-07-23 confirmed this cancel + truncate
        // sequence and the client_cancelled response.done that follows it.
        // Cancel targets the in-flight response only; truncate is valid (and
        // needed) even after response.done while playback is still draining.
        if isResponseInFlight {
            sendJSON(OpenAIRealtimeRequestBuilder.responseCancelEvent)
        }
        sendJSON(OpenAIRealtimeRequestBuilder.conversationItemTruncateEvent(
            itemID: itemID,
            audioEndMilliseconds: playedMilliseconds
        ))
        emit(.diagnostic("User interrupted OpenAI playback."))
    }

    private func resetSpeakerModeState() {
        audioEngineState = nil
        speakerGate = OpenAIRealtimeSpeakerGate()
        currentAssistantMessageItemID = nil
        lastSessionSpeakerMode = nil
        hasReportedAECFallback = false
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
            sessionStart = nil
            isConnecting = false
            isConnected = false
            isAudioStreaming = false
            isStarting = false
            resetMCPContinuationState()
            pendingWebSearches.removeAll()
            resetSpeakerModeState()
            audioEngine.stop()
            emit(.status(OpenAIRealtimeConnectionDiagnostics.closeStatus(code: closeCode, reason: reason)))
        }
    }
}
