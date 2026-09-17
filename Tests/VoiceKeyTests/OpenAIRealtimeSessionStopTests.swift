@testable import VoiceKey
import Foundation
import XCTest

final class OpenAIRealtimeSessionStopTests: XCTestCase {
    func testStopVoiceOnIdleProviderStillStopsAudioEngine() {
        let audioEngine = FakeRealtimeAudioEngine()
        let provider = makeProvider(audioEngine: audioEngine)

        provider.stopVoice()

        XCTAssertEqual(audioEngine.stopCount, 1)
    }

    func testStopVoiceIsSafeToCallRepeatedly() {
        let audioEngine = FakeRealtimeAudioEngine()
        let provider = makeProvider(audioEngine: audioEngine)

        provider.stopVoice()
        provider.stopVoice()

        XCTAssertEqual(audioEngine.stopCount, 2)
    }

    func testToggleAfterStopDuringStartupStartsANewSession() {
        // The fake engine never answers the microphone-access request, so the
        // provider stays in the "starting" state until toggled off.
        let audioEngine = FakeRealtimeAudioEngine()
        let provider = makeProvider(audioEngine: audioEngine)

        provider.toggleVoice()
        provider.toggleVoice()
        provider.toggleVoice()

        XCTAssertEqual(audioEngine.microphoneAccessRequestCount, 2)
        XCTAssertEqual(audioEngine.stopCount, 1)
    }

    func testToggleDecisionStopsWheneverAnySessionStateIsLive() {
        XCTAssertEqual(
            VoiceToggleDecision.decide(isStarting: true, isConnecting: false, isConnected: false, isAudioStreaming: false),
            .stop
        )
        XCTAssertEqual(
            VoiceToggleDecision.decide(isStarting: false, isConnecting: true, isConnected: false, isAudioStreaming: false),
            .stop
        )
        XCTAssertEqual(
            VoiceToggleDecision.decide(isStarting: false, isConnecting: false, isConnected: true, isAudioStreaming: false),
            .stop
        )
        // Regression: a session that is streaming audio with no connection flags
        // set must stop, never start a second session that abandons the engine.
        XCTAssertEqual(
            VoiceToggleDecision.decide(isStarting: false, isConnecting: false, isConnected: false, isAudioStreaming: true),
            .stop
        )
        XCTAssertEqual(
            VoiceToggleDecision.decide(isStarting: false, isConnecting: false, isConnected: false, isAudioStreaming: false),
            .start
        )
    }

    func testToggleWithoutAPIKeyDoesNotTouchAudioEngine() {
        let audioEngine = FakeRealtimeAudioEngine()
        let provider = OpenAIRealtimeProvider(
            configuration: testConfiguration,
            apiKeyProvider: { nil },
            audioEngine: audioEngine
        )

        provider.toggleVoice()

        XCTAssertEqual(audioEngine.microphoneAccessRequestCount, 0)
        XCTAssertEqual(audioEngine.stopCount, 0)
    }

    func testUpdateConfigurationOnIdleProviderDoesNotTouchAudioEngine() {
        let audioEngine = FakeRealtimeAudioEngine()
        let provider = makeProvider(audioEngine: audioEngine)

        provider.update(configuration: VoiceSessionConfiguration(
            providerID: .openAIRealtime,
            model: "other-model",
            voice: "other-voice",
            instructions: "Other instructions."
        ))

        XCTAssertEqual(audioEngine.microphoneAccessRequestCount, 0)
        XCTAssertEqual(audioEngine.stopCount, 0)
    }

    func testStaleReceiveCallbacksDoNotAffectReplacementSession() {
        let audioEngine = FakeRealtimeAudioEngine(grantsMicrophoneAccess: true)
        var tasks: [FakeRealtimeWebSocketTask] = []
        let provider = OpenAIRealtimeProvider(
            configuration: testConfiguration,
            apiKeyProvider: { "test-api-key" },
            audioEngine: audioEngine,
            webSocketTaskFactory: { _ in
                let task = FakeRealtimeWebSocketTask()
                tasks.append(task)
                return task
            }
        )
        let unexpectedError = expectation(description: "No stale callback error")
        unexpectedError.isInverted = true
        provider.onEvent = { event in
            guard case .status(.needsAttention) = event else { return }
            unexpectedError.fulfill()
        }

        provider.toggleVoice()
        XCTAssertEqual(tasks.count, 1)
        let staleTask = tasks[0]
        provider.stopVoice()
        provider.toggleVoice()
        XCTAssertEqual(tasks.count, 2)
        let replacementTask = tasks[1]

        staleTask.completeReceive(.success(.string(#"{"type":"session.updated"}"#)))
        staleTask.completeReceive(.failure(TestError.lateCallback))
        provider.webSocketDidOpen(replacementTask)

        XCTAssertEqual(staleTask.receiveCount, 1)
        XCTAssertEqual(audioEngine.startCount, 0)
        XCTAssertEqual(audioEngine.stopCount, 1)
        XCTAssertEqual(replacementTask.cancelCount, 0)

        replacementTask.completeReceive(.success(.string(#"{"type":"session.updated"}"#)))
        provider.update(configuration: testConfiguration)

        XCTAssertEqual(audioEngine.startCount, 1)
        XCTAssertEqual(replacementTask.receiveCount, 2)
        wait(for: [unexpectedError], timeout: 0.1)
    }

    func testSendErrorsAfterIntentionalStopDoNotEmitNeedsAttention() {
        let audioEngine = FakeRealtimeAudioEngine(grantsMicrophoneAccess: true)
        let task = FakeRealtimeWebSocketTask()
        let provider = OpenAIRealtimeProvider(
            configuration: testConfiguration,
            apiKeyProvider: { "test-api-key" },
            audioEngine: audioEngine,
            webSocketTaskFactory: { _ in task }
        )
        let unexpectedError = expectation(description: "No intentional-stop send error")
        unexpectedError.isInverted = true
        provider.onEvent = { event in
            guard case .status(.needsAttention) = event else { return }
            unexpectedError.fulfill()
        }

        provider.toggleVoice()
        provider.webSocketDidOpen(task)
        provider.stopVoice()
        XCTAssertEqual(task.sendCount, 3)

        task.completeSend(at: 1, error: TestError.intentionalStop)
        task.completeSend(at: 2, error: TestError.intentionalStop)
        provider.prepare()

        wait(for: [unexpectedError], timeout: 0.1)
    }

    func testConnectedConfigurationUpdateDefersModelUntilNextSession() throws {
        let audioEngine = FakeRealtimeAudioEngine(grantsMicrophoneAccess: true)
        var requests: [URLRequest] = []
        var tasks: [FakeRealtimeWebSocketTask] = []
        let provider = OpenAIRealtimeProvider(
            configuration: testConfiguration,
            apiKeyProvider: { "test-api-key" },
            audioEngine: audioEngine,
            webSocketTaskFactory: { request in
                requests.append(request)
                let task = FakeRealtimeWebSocketTask()
                tasks.append(task)
                return task
            }
        )
        let updatedConfiguration = VoiceSessionConfiguration(
            providerID: .openAIRealtime,
            model: "next-session-model",
            voice: "next-voice",
            instructions: "Updated instructions."
        )

        provider.toggleVoice()
        provider.webSocketDidOpen(tasks[0])
        provider.update(configuration: updatedConfiguration)

        XCTAssertEqual(tasks[0].sendCount, 2)
        let initialSession = try sessionDictionary(from: tasks[0].sentText(at: 0))
        XCTAssertEqual(initialSession["model"] as? String, "gpt-realtime-2-test")
        let liveSession = try sessionDictionary(from: tasks[0].sentText(at: 1))
        XCTAssertNil(liveSession["model"])
        let liveAudio = try XCTUnwrap(liveSession["audio"] as? [String: Any])
        let liveOutput = try XCTUnwrap(liveAudio["output"] as? [String: Any])
        XCTAssertEqual(liveOutput["voice"] as? String, "next-voice")
        let liveInstructions = try XCTUnwrap(liveSession["instructions"] as? String)
        XCTAssertTrue(
            liveInstructions.components(separatedBy: "\n\n")
                .contains("Updated instructions.")
        )

        provider.stopVoice()
        provider.toggleVoice()

        let nextURL = try XCTUnwrap(requests.last?.url)
        let nextModel = URLComponents(
            url: nextURL,
            resolvingAgainstBaseURL: false
        )?.queryItems?.first { $0.name == "model" }?.value
        XCTAssertEqual(nextModel, "next-session-model")
    }

    func testLiveConfigurationUpdateKeepsOriginalSessionStart() throws {
        let audioEngine = FakeRealtimeAudioEngine(grantsMicrophoneAccess: true)
        let task = FakeRealtimeWebSocketTask()
        let startDate = Date(timeIntervalSince1970: 1_790_000_000)
        var nowCallCount = 0
        let provider = OpenAIRealtimeProvider(
            configuration: testConfiguration,
            apiKeyProvider: { "test-api-key" },
            audioEngine: audioEngine,
            webSocketTaskFactory: { _ in task },
            now: {
                nowCallCount += 1
                return startDate.addingTimeInterval(TimeInterval(nowCallCount - 1) * 3_600)
            }
        )

        provider.toggleVoice()
        provider.webSocketDidOpen(task)
        provider.update(configuration: VoiceSessionConfiguration(
            providerID: .openAIRealtime,
            model: "unchanged-until-next-session",
            voice: "updated-voice",
            instructions: "Updated instructions."
        ))

        let initialSession = try sessionDictionary(from: task.sentText(at: 0))
        let updatedSession = try sessionDictionary(from: task.sentText(at: 1))
        let initialInstructions = try XCTUnwrap(initialSession["instructions"] as? String)
        let updatedInstructions = try XCTUnwrap(updatedSession["instructions"] as? String)
        let initialStamp = try XCTUnwrap(initialInstructions.components(separatedBy: "\n\n").last)
        let updatedStamp = try XCTUnwrap(updatedInstructions.components(separatedBy: "\n\n").last)

        XCTAssertEqual(initialStamp, updatedStamp)
        XCTAssertEqual(nowCallCount, 1)
    }

    func testFatalAudioFailureStopsSessionAndSurfacesNeedsAttention() {
        let audioEngine = FakeRealtimeAudioEngine(grantsMicrophoneAccess: true)
        let task = FakeRealtimeWebSocketTask()
        let provider = OpenAIRealtimeProvider(
            configuration: testConfiguration,
            apiKeyProvider: { "test-api-key" },
            audioEngine: audioEngine,
            webSocketTaskFactory: { _ in task }
        )
        let listening = expectation(description: "Audio streaming started")
        let failure = expectation(description: "Fatal audio failure surfaced")
        provider.onEvent = { event in
            switch event {
            case .status(.listening):
                listening.fulfill()
            case let .status(.needsAttention(message))
                where message.contains("Microphone audio stopped"):
                failure.fulfill()
            default:
                break
            }
        }

        provider.toggleVoice()
        provider.webSocketDidOpen(task)
        task.completeReceive(.success(.string(#"{"type":"session.updated"}"#)))
        wait(for: [listening], timeout: 1)
        XCTAssertEqual(audioEngine.startCount, 1)

        audioEngine.triggerFatalFailure()

        wait(for: [failure], timeout: 1)
        XCTAssertEqual(audioEngine.stopCount, 1)
        XCTAssertEqual(task.cancelCount, 1)
    }

    func testWebSearchFunctionCallReturnsOutputThenContinuesResponse()
        throws {
        let task = FakeRealtimeWebSocketTask()
        let searcher = FakeOpenAIWebSearcher(
            result: .success("Search answer with sources")
        )
        let provider = OpenAIRealtimeProvider(
            configuration: testConfiguration,
            apiKeyProvider: { "channel-openai-key" },
            audioEngine: FakeRealtimeAudioEngine(
                grantsMicrophoneAccess: true
            ),
            webSocketTaskFactory: { _ in task },
            webSearcher: searcher
        )
        provider.toggleVoice()
        provider.webSocketDidOpen(task)

        receive(
            #"{"type":"response.function_call_arguments.done","call_id":"call-42","arguments":"{\"query\":\"current headlines\"}"}"#,
            from: task,
            provider: provider
        )

        XCTAssertEqual(searcher.queries, ["current headlines"])
        XCTAssertEqual(searcher.apiKeys, ["channel-openai-key"])
        XCTAssertEqual(task.sendCount, 3)
        let outputEvent = try eventDictionary(
            from: task.sentText(at: 1)
        )
        XCTAssertEqual(
            outputEvent["type"] as? String,
            "conversation.item.create"
        )
        let item = try XCTUnwrap(
            outputEvent["item"] as? [String: Any]
        )
        XCTAssertEqual(
            item["type"] as? String,
            "function_call_output"
        )
        XCTAssertEqual(item["call_id"] as? String, "call-42")
        XCTAssertEqual(
            item["output"] as? String,
            "Search answer with sources"
        )
        XCTAssertEqual(
            try eventType(from: task.sentText(at: 2)),
            "response.create"
        )
    }

    func testWebSearchFailureStillReturnsSpeakableFunctionOutput()
        throws {
        let task = FakeRealtimeWebSocketTask()
        let searcher = FakeOpenAIWebSearcher(
            result: .failure(.rateLimited)
        )
        let provider = OpenAIRealtimeProvider(
            configuration: testConfiguration,
            apiKeyProvider: { "channel-openai-key" },
            audioEngine: FakeRealtimeAudioEngine(
                grantsMicrophoneAccess: true
            ),
            webSocketTaskFactory: { _ in task },
            webSearcher: searcher
        )
        provider.toggleVoice()
        provider.webSocketDidOpen(task)

        receive(
            #"{"type":"response.function_call_arguments.done","call_id":"failed-call","arguments":"{\"query\":\"current headlines\"}"}"#,
            from: task,
            provider: provider
        )

        XCTAssertEqual(task.sendCount, 3)
        let outputEvent = try eventDictionary(
            from: task.sentText(at: 1)
        )
        let item = try XCTUnwrap(
            outputEvent["item"] as? [String: Any]
        )
        let output = try XCTUnwrap(item["output"] as? String)
        XCTAssertTrue(output.contains("rate limit"))
        XCTAssertEqual(
            try eventType(from: task.sentText(at: 2)),
            "response.create"
        )
    }

    func testWebSearchWithKeyRemovedStillReturnsFailureOutput()
        throws {
        let task = FakeRealtimeWebSocketTask()
        var apiKey: String? = "channel-openai-key"
        let searcher = FakeOpenAIWebSearcher(
            result: .success("must not be used")
        )
        let provider = OpenAIRealtimeProvider(
            configuration: testConfiguration,
            apiKeyProvider: { apiKey },
            audioEngine: FakeRealtimeAudioEngine(
                grantsMicrophoneAccess: true
            ),
            webSocketTaskFactory: { _ in task },
            webSearcher: searcher
        )
        provider.toggleVoice()
        provider.webSocketDidOpen(task)
        apiKey = nil

        receive(
            #"{"type":"response.function_call_arguments.done","call_id":"missing-key-call","arguments":"{\"query\":\"current headlines\"}"}"#,
            from: task,
            provider: provider
        )

        XCTAssertEqual(searcher.queries, [])
        XCTAssertEqual(task.sendCount, 3)
        let outputEvent = try eventDictionary(
            from: task.sentText(at: 1)
        )
        let item = try XCTUnwrap(
            outputEvent["item"] as? [String: Any]
        )
        XCTAssertTrue(
            try XCTUnwrap(item["output"] as? String)
                .contains("no OpenAI API key")
        )
        XCTAssertEqual(
            try eventType(from: task.sentText(at: 2)),
            "response.create"
        )
    }

    func testHangingWebSearchTimesOutAndContinuesResponse() throws {
        let task = FakeRealtimeWebSocketTask()
        let searcher = FakeOpenAIWebSearcher(result: nil)
        let provider = OpenAIRealtimeProvider(
            configuration: testConfiguration,
            apiKeyProvider: { "channel-openai-key" },
            audioEngine: FakeRealtimeAudioEngine(
                grantsMicrophoneAccess: true
            ),
            webSocketTaskFactory: { _ in task },
            webSearcher: searcher,
            webSearchTimeout: 0
        )
        provider.toggleVoice()
        provider.webSocketDidOpen(task)

        receive(
            #"{"type":"response.function_call_arguments.done","call_id":"hung-call","arguments":"{\"query\":\"current headlines\"}"}"#,
            from: task,
            provider: provider
        )

        waitUntil(
            { task.sendCount == 3 },
            "timed-out search did not produce a continuation"
        )
        let outputEvent = try eventDictionary(
            from: task.sentText(at: 1)
        )
        let item = try XCTUnwrap(
            outputEvent["item"] as? [String: Any]
        )
        XCTAssertTrue(
            try XCTUnwrap(item["output"] as? String)
                .contains("timed out")
        )
        XCTAssertEqual(
            try eventType(from: task.sentText(at: 2)),
            "response.create"
        )
    }

    func testWebSearchDiagnosticsNeverContainKeyQueryOrResult()
        throws {
        let task = FakeRealtimeWebSocketTask()
        let apiKey = "sentinel-api-key-must-not-log"
        let query = "sentinel query must not log"
        let resultText = "sentinel result must not log"
        let searcher = FakeOpenAIWebSearcher(
            result: .success(resultText)
        )
        let provider = OpenAIRealtimeProvider(
            configuration: testConfiguration,
            apiKeyProvider: { apiKey },
            audioEngine: FakeRealtimeAudioEngine(
                grantsMicrophoneAccess: true
            ),
            webSocketTaskFactory: { _ in task },
            webSearcher: searcher
        )
        var diagnostics: [String] = []
        provider.onEvent = {
            guard case let .diagnostic(message) = $0 else {
                return
            }
            diagnostics.append(message)
        }
        provider.toggleVoice()
        provider.webSocketDidOpen(task)

        receive(
            #"{"type":"response.function_call_arguments.done","call_id":"private-call","arguments":"{\"query\":\"sentinel query must not log\"}"}"#,
            from: task,
            provider: provider
        )

        waitUntil(
            {
                diagnostics.contains(where: {
                    $0.contains("outcome: success")
                })
            },
            "search outcome diagnostic did not arrive"
        )
        let logText = diagnostics.joined(separator: "\n")
        XCTAssertFalse(logText.contains(apiKey))
        XCTAssertFalse(logText.contains(query))
        XCTAssertFalse(logText.contains(resultText))
        XCTAssertTrue(logText.contains("query length: \(query.count)"))
    }

    func testMCPCallTerminationSendsContinuationWhenResponseIsIdle() throws {
        let task = FakeRealtimeWebSocketTask()
        let provider = makeConnectedProvider(task: task)

        receive(
            #"{"type":"response.mcp_call.completed"}"#,
            from: task,
            provider: provider
        )

        XCTAssertEqual(task.sendCount, 2)
        XCTAssertEqual(try eventType(from: task.sentText(at: 1)), "response.create")
        withExtendedLifetime(provider) {}
    }

    func testMCPCallFailureUsesTheSameContinuationPath() throws {
        let task = FakeRealtimeWebSocketTask()
        let provider = makeConnectedProvider(task: task)

        receive(
            #"{"type":"response.mcp_call.failed"}"#,
            from: task,
            provider: provider
        )

        XCTAssertEqual(task.sendCount, 2)
        XCTAssertEqual(try eventType(from: task.sentText(at: 1)), "response.create")
        withExtendedLifetime(provider) {}
    }

    func testMCPContinuationWaitsForActiveResponseToEnd() throws {
        let task = FakeRealtimeWebSocketTask()
        let provider = makeConnectedProvider(task: task)

        receive(#"{"type":"response.created"}"#, from: task, provider: provider)
        receive(
            #"{"type":"response.mcp_call.completed"}"#,
            at: 1,
            from: task,
            provider: provider
        )
        XCTAssertEqual(task.sendCount, 1)

        receive(
            #"{"type":"response.done"}"#,
            at: 2,
            from: task,
            provider: provider
        )

        XCTAssertEqual(task.sendCount, 2)
        XCTAssertEqual(try eventType(from: task.sentText(at: 1)), "response.create")
        withExtendedLifetime(provider) {}
    }

    func testSpeechStartedClearsPendingMCPContinuation() {
        let task = FakeRealtimeWebSocketTask()
        let provider = makeConnectedProvider(task: task)

        receive(#"{"type":"response.created"}"#, from: task, provider: provider)
        receive(
            #"{"type":"response.mcp_call.completed"}"#,
            at: 1,
            from: task,
            provider: provider
        )
        receive(
            #"{"type":"input_audio_buffer.speech_started"}"#,
            at: 2,
            from: task,
            provider: provider
        )
        receive(
            #"{"type":"response.done"}"#,
            at: 3,
            from: task,
            provider: provider
        )

        XCTAssertEqual(task.sendCount, 1)
        withExtendedLifetime(provider) {}
    }

    func testMCPContinuationsAreCappedWithoutInterveningSpeech() throws {
        let task = FakeRealtimeWebSocketTask()
        let provider = makeConnectedProvider(task: task)

        for index in 0..<9 {
            receive(
                #"{"type":"response.mcp_call.completed"}"#,
                at: index,
                from: task,
                provider: provider
            )
        }

        XCTAssertEqual(task.sendCount, 9)
        for index in 1..<task.sendCount {
            XCTAssertEqual(try eventType(from: task.sentText(at: index)), "response.create")
        }
        withExtendedLifetime(provider) {}
    }

    func testStopClearsPendingMCPContinuation() {
        let firstTask = FakeRealtimeWebSocketTask()
        let secondTask = FakeRealtimeWebSocketTask()
        var tasks = [firstTask, secondTask]
        let audioEngine = FakeRealtimeAudioEngine(grantsMicrophoneAccess: true)
        let provider = OpenAIRealtimeProvider(
            configuration: testConfiguration,
            apiKeyProvider: { "test-api-key" },
            audioEngine: audioEngine,
            webSocketTaskFactory: { _ in tasks.removeFirst() }
        )

        provider.toggleVoice()
        provider.webSocketDidOpen(firstTask)
        receive(
            #"{"type":"response.created"}"#,
            from: firstTask,
            provider: provider
        )
        receive(
            #"{"type":"response.mcp_call.completed"}"#,
            at: 1,
            from: firstTask,
            provider: provider
        )
        provider.stopVoice()

        provider.toggleVoice()
        provider.webSocketDidOpen(secondTask)
        receive(
            #"{"type":"response.done"}"#,
            from: secondTask,
            provider: provider
        )

        XCTAssertEqual(secondTask.sendCount, 1)
    }

    func testStopResetsMCPContinuationCap() throws {
        let firstTask = FakeRealtimeWebSocketTask()
        let secondTask = FakeRealtimeWebSocketTask()
        var tasks = [firstTask, secondTask]
        let audioEngine = FakeRealtimeAudioEngine(grantsMicrophoneAccess: true)
        let provider = OpenAIRealtimeProvider(
            configuration: testConfiguration,
            apiKeyProvider: { "test-api-key" },
            audioEngine: audioEngine,
            webSocketTaskFactory: { _ in tasks.removeFirst() }
        )

        provider.toggleVoice()
        provider.webSocketDidOpen(firstTask)
        for index in 0..<9 {
            receive(
                #"{"type":"response.mcp_call.completed"}"#,
                at: index,
                from: firstTask,
                provider: provider
            )
        }
        XCTAssertEqual(firstTask.sendCount, 9)
        provider.stopVoice()

        provider.toggleVoice()
        provider.webSocketDidOpen(secondTask)
        receive(
            #"{"type":"response.mcp_call.completed"}"#,
            from: secondTask,
            provider: provider
        )

        XCTAssertEqual(secondTask.sendCount, 2)
        XCTAssertEqual(try eventType(from: secondTask.sentText(at: 1)), "response.create")
    }

    private func makeProvider(audioEngine: FakeRealtimeAudioEngine) -> OpenAIRealtimeProvider {
        OpenAIRealtimeProvider(
            configuration: testConfiguration,
            apiKeyProvider: { "test-api-key" },
            audioEngine: audioEngine
        )
    }

    private func makeConnectedProvider(
        task: FakeRealtimeWebSocketTask
    ) -> OpenAIRealtimeProvider {
        let provider = OpenAIRealtimeProvider(
            configuration: testConfiguration,
            apiKeyProvider: { "test-api-key" },
            audioEngine: FakeRealtimeAudioEngine(grantsMicrophoneAccess: true),
            webSocketTaskFactory: { _ in task }
        )
        provider.toggleVoice()
        provider.webSocketDidOpen(task)
        return provider
    }

    private var testConfiguration: VoiceSessionConfiguration {
        VoiceSessionConfiguration(
            providerID: .openAIRealtime,
            model: "gpt-realtime-2-test",
            voice: "marin-test",
            instructions: "Keep it concise."
        )
    }

    private func sessionDictionary(from text: String?) throws -> [String: Any] {
        let data = try XCTUnwrap(text?.data(using: .utf8))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(object["session"] as? [String: Any])
    }

    private func eventType(from text: String?) throws -> String {
        try XCTUnwrap(
            eventDictionary(from: text)["type"] as? String
        )
    }

    private func eventDictionary(
        from text: String?
    ) throws -> [String: Any] {
        let data = try XCTUnwrap(text?.data(using: .utf8))
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        )
    }

    private func receive(
        _ text: String,
        at index: Int = 0,
        from task: FakeRealtimeWebSocketTask,
        provider: OpenAIRealtimeProvider
    ) {
        task.completeReceive(.success(.string(text)), at: index)
        provider.prepare()
    }
}

private final class FakeOpenAIWebSearcher: OpenAIWebSearching {
    private let result: OpenAIWebSearchResult?
    private(set) var queries: [String] = []
    private(set) var apiKeys: [String] = []

    init(result: OpenAIWebSearchResult?) {
        self.result = result
    }

    func search(
        query: String,
        apiKey: String,
        completion: @escaping (OpenAIWebSearchResult) -> Void
    ) {
        queries.append(query)
        apiKeys.append(apiKey)
        if let result {
            completion(result)
        }
    }
}

private final class FakeRealtimeAudioEngine: RealtimeAudioEngineProtocol {
    private let grantsMicrophoneAccess: Bool
    private(set) var microphoneAccessRequestCount = 0
    private(set) var stopCount = 0
    private(set) var startCount = 0
    private var fatalFailureHandler: (() -> Void)?

    init(grantsMicrophoneAccess: Bool = false) {
        self.grantsMicrophoneAccess = grantsMicrophoneAccess
    }

    func setFatalFailureHandler(_ handler: (() -> Void)?) {
        fatalFailureHandler = handler
    }

    func requestMicrophoneAccess(_ completion: @escaping (Bool) -> Void) {
        microphoneAccessRequestCount += 1
        if grantsMicrophoneAccess {
            completion(true)
        }
    }

    func start(
        inputHandler: @escaping (Data) -> Void,
        activityHandler: @escaping (RealtimeAudioInputActivity) -> Void
    ) throws {
        startCount += 1
    }

    func stop() {
        stopCount += 1
    }

    func stopPlayback() {}

    func playPCM16(_ data: Data) {}

    func triggerFatalFailure() {
        fatalFailureHandler?()
    }
}

private final class FakeRealtimeWebSocketTask: OpenAIRealtimeWebSocketTaskProtocol {
    private(set) var cancelCount = 0
    private(set) var receiveCount = 0
    private(set) var sentMessages: [URLSessionWebSocketTask.Message] = []
    private var receiveCompletions: [
        @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void
    ] = []
    private var sendCompletions: [@Sendable (Error?) -> Void] = []

    var sendCount: Int {
        sentMessages.count
    }

    func resume() {}

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        cancelCount += 1
    }

    func send(
        _ message: URLSessionWebSocketTask.Message,
        completionHandler: @escaping @Sendable (Error?) -> Void
    ) {
        sentMessages.append(message)
        sendCompletions.append(completionHandler)
    }

    func receive(
        completionHandler: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void
    ) {
        receiveCount += 1
        receiveCompletions.append(completionHandler)
    }

    func completeReceive(_ result: Result<URLSessionWebSocketTask.Message, Error>, at index: Int = 0) {
        receiveCompletions[index](result)
    }

    func completeSend(at index: Int, error: Error?) {
        sendCompletions[index](error)
    }

    func sentText(at index: Int) -> String? {
        guard case let .string(text) = sentMessages[index] else { return nil }
        return text
    }
}

private enum TestError: LocalizedError {
    case lateCallback
    case intentionalStop

    var errorDescription: String? {
        switch self {
        case .lateCallback:
            return "Late callback from stale socket."
        case .intentionalStop:
            return "Socket closed during intentional stop."
        }
    }
}
