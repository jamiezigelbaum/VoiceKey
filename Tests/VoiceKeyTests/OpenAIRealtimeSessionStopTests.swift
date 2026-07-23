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
        XCTAssertTrue(liveInstructions.hasPrefix("Updated instructions."))

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

    private func makeProvider(audioEngine: FakeRealtimeAudioEngine) -> OpenAIRealtimeProvider {
        OpenAIRealtimeProvider(
            configuration: testConfiguration,
            apiKeyProvider: { "test-api-key" },
            audioEngine: audioEngine
        )
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
