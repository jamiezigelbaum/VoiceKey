@testable import VoiceKey
import Foundation
import XCTest

final class OpenAIRealtimeSpeakerModeProviderTests: XCTestCase {
    func testRouteFlipResendsExactSpeakerModeSessionConfiguration() throws {
        let engine = SpeakerModeFakeAudioEngine(state: headphoneState)
        let task = SpeakerModeFakeWebSocketTask()
        let provider = makeConnectedProvider(engine: engine, task: task)

        XCTAssertEqual(task.sendCount, 1)
        let initialInput = try inputConfiguration(from: task.sentText(at: 0))
        XCTAssertEqual(
            try dictionary(initialInput["noise_reduction"])["type"] as? String,
            "near_field"
        )
        XCTAssertEqual(
            try dictionary(initialInput["turn_detection"])["type"] as? String,
            "semantic_vad"
        )

        engine.updateState(speakerState)
        provider.prepare()

        XCTAssertEqual(task.sendCount, 2)
        let flippedInput = try inputConfiguration(from: task.sentText(at: 1))
        XCTAssertEqual(
            try dictionary(flippedInput["noise_reduction"])["type"] as? String,
            "far_field"
        )
        let vad = try dictionary(flippedInput["turn_detection"])
        XCTAssertEqual(vad["type"] as? String, "server_vad")
        XCTAssertEqual(vad["threshold"] as? Double, 0.75)
        XCTAssertEqual(vad["prefix_padding_ms"] as? Int, 300)
        XCTAssertEqual(vad["silence_duration_ms"] as? Int, 700)
        XCTAssertEqual(vad["create_response"] as? Bool, true)
        XCTAssertEqual(vad["interrupt_response"] as? Bool, false)
        withExtendedLifetime(provider) {}
    }

    func testMicAppendIsClosedDuringPlaybackAndHangoverThenReopens() throws {
        let clock = SpeakerModeTestClock()
        let engine = SpeakerModeFakeAudioEngine(state: speakerState)
        let task = SpeakerModeFakeWebSocketTask()
        let provider = makeConnectedProvider(
            engine: engine,
            task: task,
            now: { clock.date }
        )
        startAudioAndAssistantTurn(provider: provider, task: task)

        engine.updateState(speakerState(playbackActive: true, playedMilliseconds: 100))
        provider.prepare()
        engine.emitInput(peak: 0.01)
        provider.prepare()
        XCTAssertEqual(try task.sentEventTypes(), ["session.update"])

        engine.updateState(speakerState(playbackActive: false, playedMilliseconds: 100))
        provider.prepare()
        clock.advance(milliseconds: 1_000)
        engine.emitInput(peak: 0.01)
        provider.prepare()
        XCTAssertEqual(try task.sentEventTypes(), ["session.update"])

        clock.advance(milliseconds: 1)
        engine.emitInput(peak: 0.01)
        provider.prepare()
        XCTAssertEqual(
            try task.sentEventTypes(),
            ["session.update", "input_audio_buffer.append"]
        )
        withExtendedLifetime(provider) {}
    }

    func testBargeInCancelsAndTruncatesOnceThenLatchResets() throws {
        let engine = SpeakerModeFakeAudioEngine(state: speakerState)
        let task = SpeakerModeFakeWebSocketTask()
        let provider = makeConnectedProvider(engine: engine, task: task)
        startAudioAndAssistantTurn(
            provider: provider,
            task: task,
            itemID: "assistant-1"
        )
        engine.updateState(speakerState(playbackActive: true, playedMilliseconds: 250))
        provider.prepare()

        for _ in 0..<2 {
            engine.emitInput(peak: 0.2)
            provider.prepare()
        }
        XCTAssertEqual(try task.sentEventTypes(), ["session.update"])

        engine.emitInput(peak: 0.2)
        provider.prepare()
        XCTAssertEqual(
            try task.sentEventTypes(),
            [
                "session.update",
                "response.cancel",
                "conversation.item.truncate",
                "input_audio_buffer.append"
            ]
        )
        let firstTruncate = try task.sentObject(at: 2)
        XCTAssertEqual(firstTruncate["item_id"] as? String, "assistant-1")
        XCTAssertEqual(firstTruncate["content_index"] as? Int, 0)
        XCTAssertEqual(firstTruncate["audio_end_ms"] as? Int, 250)
        XCTAssertEqual(engine.stopPlaybackCount, 1)

        engine.emitInput(peak: 0.2)
        provider.prepare()
        XCTAssertEqual(
            try task.sentEventTypes().filter { $0 == "response.cancel" }.count,
            1
        )

        task.deliver(#"{"type":"response.done","status":"cancelled","status_details":{"reason":"client_cancelled"}}"#)
        provider.prepare()
        XCTAssertFalse(try task.sentEventTypes().contains("response.create"))

        task.deliver(#"{"type":"response.created"}"#)
        provider.prepare()
        task.deliver(
            #"{"type":"response.output_item.added","item":{"type":"message","id":"assistant-2"}}"#
        )
        provider.prepare()
        engine.updateState(speakerState(playbackActive: true, playedMilliseconds: 125))
        provider.prepare()
        for _ in 0..<3 {
            engine.emitInput(peak: 0.2)
            provider.prepare()
        }

        XCTAssertEqual(
            try task.sentEventTypes().filter { $0 == "response.cancel" }.count,
            2
        )
        let secondTruncateIndex = try XCTUnwrap(
            task.sentEventTypes().lastIndex(of: "conversation.item.truncate")
        )
        let secondTruncate = try task.sentObject(at: secondTruncateIndex)
        XCTAssertEqual(secondTruncate["item_id"] as? String, "assistant-2")
        XCTAssertEqual(secondTruncate["audio_end_ms"] as? Int, 125)
        withExtendedLifetime(provider) {}
    }

    func testLoudReplyDuringHangoverOpensGateWithoutCancelOrTruncate() throws {
        let clock = SpeakerModeTestClock()
        let engine = SpeakerModeFakeAudioEngine(state: speakerState)
        let task = SpeakerModeFakeWebSocketTask()
        let provider = makeConnectedProvider(
            engine: engine,
            task: task,
            now: { clock.date }
        )
        startAudioAndAssistantTurn(
            provider: provider,
            task: task,
            itemID: "assistant-1"
        )

        // Playback runs, the response completes, then playback drains: the
        // common shape of a turn the user heard in full.
        engine.updateState(speakerState(playbackActive: true, playedMilliseconds: 500))
        provider.prepare()
        task.deliver(#"{"type":"response.done"}"#)
        provider.prepare()
        engine.updateState(speakerState(playbackActive: false, playedMilliseconds: 500))
        provider.prepare()

        // A prompt, loud reply inside the hangover window trips the gate
        // latch, but there is nothing to cancel or truncate — a cancel here
        // would draw a server error and a spurious needsAttention.
        clock.advance(milliseconds: 200)
        for _ in 0..<3 {
            engine.emitInput(peak: 0.2)
            provider.prepare()
        }

        XCTAssertFalse(try task.sentEventTypes().contains("response.cancel"))
        XCTAssertFalse(
            try task.sentEventTypes().contains("conversation.item.truncate")
        )
        XCTAssertEqual(engine.stopPlaybackCount, 0)
        // The latch opened the gate: the triggering speech streams on.
        XCTAssertEqual(
            try task.sentEventTypes().filter { $0 == "input_audio_buffer.append" }.count,
            1
        )
        withExtendedLifetime(provider) {}
    }

    func testSpeechStartedStopsPlaybackExceptInSpeakerModeDuringPlayback() {
        let engine = SpeakerModeFakeAudioEngine(
            state: speakerState(playbackActive: true)
        )
        let task = SpeakerModeFakeWebSocketTask()
        let provider = makeConnectedProvider(engine: engine, task: task)

        task.deliver(#"{"type":"input_audio_buffer.speech_started"}"#)
        provider.prepare()
        XCTAssertEqual(engine.stopPlaybackCount, 0)

        engine.updateState(speakerState(playbackActive: false))
        provider.prepare()
        task.deliver(#"{"type":"input_audio_buffer.speech_started"}"#)
        provider.prepare()
        XCTAssertEqual(engine.stopPlaybackCount, 1)

        engine.updateState(headphoneState(playbackActive: true))
        provider.prepare()
        task.deliver(#"{"type":"input_audio_buffer.speech_started"}"#)
        provider.prepare()
        XCTAssertEqual(engine.stopPlaybackCount, 2)
        withExtendedLifetime(provider) {}
    }

    func testInactiveAECForcesSessionAndMicGatingEvenWhenPreferenceIsOff() throws {
        let forcedState = RealtimeAudioEngineState(
            outputRoute: .headphones,
            isEchoCancellationActive: false,
            isPlaybackActive: true,
            currentAssistantPlayedDurationMilliseconds: 0
        )
        let engine = SpeakerModeFakeAudioEngine(state: forcedState)
        let task = SpeakerModeFakeWebSocketTask()
        var configuration = testConfiguration
        configuration.speakerModePreference = .off
        let diagnostic = expectation(description: "AEC fallback diagnostic")
        let provider = makeConnectedProvider(
            engine: engine,
            task: task,
            configuration: configuration,
            onEvent: { event in
                guard case let .diagnostic(message) = event,
                      message.contains("Echo cancellation is inactive") else {
                    return
                }
                diagnostic.fulfill()
            }
        )
        task.deliver(#"{"type":"session.updated"}"#)
        provider.prepare()
        engine.emitInput(peak: 0.01)
        provider.prepare()

        let input = try inputConfiguration(from: task.sentText(at: 0))
        XCTAssertEqual(
            try dictionary(input["noise_reduction"])["type"] as? String,
            "far_field"
        )
        XCTAssertEqual(try task.sentEventTypes(), ["session.update"])
        wait(for: [diagnostic], timeout: 1)
        withExtendedLifetime(provider) {}
    }

    private var testConfiguration: VoiceSessionConfiguration {
        VoiceSessionConfiguration(
            providerID: .openAIRealtime,
            model: "gpt-realtime-2-test",
            voice: "marin-test",
            instructions: "Keep it concise."
        )
    }

    private var headphoneState: RealtimeAudioEngineState {
        headphoneState(playbackActive: false)
    }

    private func headphoneState(
        playbackActive: Bool,
        playedMilliseconds: Int = 0
    ) -> RealtimeAudioEngineState {
        RealtimeAudioEngineState(
            outputRoute: .headphones,
            isEchoCancellationActive: true,
            isPlaybackActive: playbackActive,
            currentAssistantPlayedDurationMilliseconds: playedMilliseconds
        )
    }

    private var speakerState: RealtimeAudioEngineState {
        speakerState(playbackActive: false)
    }

    private func speakerState(
        playbackActive: Bool,
        playedMilliseconds: Int = 0
    ) -> RealtimeAudioEngineState {
        RealtimeAudioEngineState(
            outputRoute: .unknown,
            isEchoCancellationActive: true,
            isPlaybackActive: playbackActive,
            currentAssistantPlayedDurationMilliseconds: playedMilliseconds
        )
    }

    private func makeConnectedProvider(
        engine: SpeakerModeFakeAudioEngine,
        task: SpeakerModeFakeWebSocketTask,
        configuration: VoiceSessionConfiguration? = nil,
        now: @escaping () -> Date = Date.init,
        onEvent: ((VoiceProviderEvent) -> Void)? = nil
    ) -> OpenAIRealtimeProvider {
        let provider = OpenAIRealtimeProvider(
            configuration: configuration ?? testConfiguration,
            apiKeyProvider: { "test-api-key" },
            audioEngine: engine,
            webSocketTaskFactory: { _ in task },
            gateNow: now
        )
        provider.onEvent = onEvent
        provider.toggleVoice()
        provider.webSocketDidOpen(task)
        return provider
    }

    private func startAudioAndAssistantTurn(
        provider: OpenAIRealtimeProvider,
        task: SpeakerModeFakeWebSocketTask,
        itemID: String = "assistant-item"
    ) {
        task.deliver(#"{"type":"session.updated"}"#)
        provider.prepare()
        task.deliver(#"{"type":"response.created"}"#)
        provider.prepare()
        task.deliver(
            #"{"type":"response.output_item.added","item":{"type":"message","id":"\#(itemID)"}}"#
        )
        provider.prepare()
    }

    private func inputConfiguration(from text: String?) throws -> [String: Any] {
        let data = try XCTUnwrap(text?.data(using: .utf8))
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let session = try dictionary(object["session"])
        let audio = try dictionary(session["audio"])
        return try dictionary(audio["input"])
    }

    private func dictionary(
        _ value: Any?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String: Any] {
        try XCTUnwrap(value as? [String: Any], file: file, line: line)
    }
}

private final class SpeakerModeTestClock {
    private(set) var date = Date(timeIntervalSince1970: 100)

    func advance(milliseconds: Int) {
        date = date.addingTimeInterval(TimeInterval(milliseconds) / 1_000)
    }
}

private final class SpeakerModeFakeAudioEngine: RealtimeAudioEngineProtocol {
    private var state: RealtimeAudioEngineState
    private var stateChangeHandler: ((RealtimeAudioEngineState) -> Void)?
    private var inputHandler: ((Data) -> Void)?
    private var activityHandler: ((RealtimeAudioInputActivity) -> Void)?
    private(set) var stopPlaybackCount = 0

    init(state: RealtimeAudioEngineState) {
        self.state = state
    }

    func setStateChangeHandler(_ handler: ((RealtimeAudioEngineState) -> Void)?) {
        stateChangeHandler = handler
    }

    func stateSnapshot() -> RealtimeAudioEngineState {
        state
    }

    func requestMicrophoneAccess(_ completion: @escaping (Bool) -> Void) {
        completion(true)
    }

    func start(
        inputHandler: @escaping (Data) -> Void,
        activityHandler: @escaping (RealtimeAudioInputActivity) -> Void
    ) throws {
        self.inputHandler = inputHandler
        self.activityHandler = activityHandler
    }

    func stop() {}

    func stopPlayback() {
        stopPlaybackCount += 1
        state.isPlaybackActive = false
        stateChangeHandler?(state)
    }

    func playPCM16(_ data: Data) {}

    func updateState(_ state: RealtimeAudioEngineState) {
        self.state = state
        stateChangeHandler?(state)
    }

    func emitInput(peak: Float) {
        activityHandler?(RealtimeAudioInputActivity(rms: peak / 2, peak: peak))
        inputHandler?(Data([0x00, 0x01]))
    }
}

private final class SpeakerModeFakeWebSocketTask: OpenAIRealtimeWebSocketTaskProtocol {
    private(set) var sentMessages: [URLSessionWebSocketTask.Message] = []
    private var receiveCompletions: [
        @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void
    ] = []

    var sendCount: Int {
        sentMessages.count
    }

    func resume() {}

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {}

    func send(
        _ message: URLSessionWebSocketTask.Message,
        completionHandler: @escaping @Sendable (Error?) -> Void
    ) {
        sentMessages.append(message)
    }

    func receive(
        completionHandler: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void
    ) {
        receiveCompletions.append(completionHandler)
    }

    func deliver(_ text: String) {
        receiveCompletions.removeFirst()(.success(.string(text)))
    }

    func sentText(at index: Int) -> String? {
        guard case let .string(text) = sentMessages[index] else { return nil }
        return text
    }

    func sentObject(at index: Int) throws -> [String: Any] {
        let data = try XCTUnwrap(sentText(at: index)?.data(using: .utf8))
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    func sentEventTypes() throws -> [String] {
        try sentMessages.indices.map { index in
            try XCTUnwrap(sentObject(at: index)["type"] as? String)
        }
    }
}
