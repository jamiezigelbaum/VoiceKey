@testable import VoiceKey
import Foundation
import XCTest

final class OpenClawTalkSpeakerModeProviderTests: XCTestCase {
    func testMicGateClosesDuringPlaybackAndHangoverButOpensForHeadphones() throws {
        let clock = OpenClawSpeakerModeTestClock()
        let engine = OpenClawSpeakerModeFakeAudioEngine(state: speakerState)
        let socket = OpenClawSpeakerModeFakeWebSocket()
        let provider = makeConnectedProvider(
            engine: engine,
            socket: socket,
            now: { clock.date }
        )

        engine.updateState(speakerState(playbackActive: true))
        provider.prepare()
        engine.emitInput(peak: 0.01)
        provider.prepare()
        XCTAssertEqual(try socket.sentMethodCount("talk.session.appendAudio"), 0)

        engine.updateState(speakerState(playbackActive: false))
        provider.prepare()
        clock.advance(milliseconds: 1_000)
        engine.emitInput(peak: 0.01)
        provider.prepare()
        XCTAssertEqual(try socket.sentMethodCount("talk.session.appendAudio"), 0)

        clock.advance(milliseconds: 1)
        engine.emitInput(peak: 0.01)
        provider.prepare()
        XCTAssertEqual(try socket.sentMethodCount("talk.session.appendAudio"), 1)

        engine.updateState(headphoneState(playbackActive: true))
        provider.prepare()
        engine.emitInput(peak: 0.01)
        provider.prepare()
        XCTAssertEqual(try socket.sentMethodCount("talk.session.appendAudio"), 2)
        withExtendedLifetime(provider) {}
    }

    func testSpeakerModeBargeInUsesSharedThresholdCancelsOnceAndResetsNextTurn() throws {
        let engine = OpenClawSpeakerModeFakeAudioEngine(state: speakerState)
        let socket = OpenClawSpeakerModeFakeWebSocket()
        let provider = makeConnectedProvider(engine: engine, socket: socket)
        deliverAssistantAudio(provider: provider, socket: socket)
        engine.updateState(speakerState(playbackActive: true))
        provider.prepare()

        for _ in 0..<2 {
            engine.emitInput(peak: 0.2)
            provider.prepare()
        }
        XCTAssertEqual(try socket.sentMethodCount("talk.session.cancelOutput"), 0)
        XCTAssertEqual(try socket.sentMethodCount("talk.session.appendAudio"), 0)

        engine.emitInput(peak: 0.2)
        provider.prepare()
        XCTAssertEqual(try socket.sentMethodCount("talk.session.cancelOutput"), 1)
        XCTAssertEqual(try socket.sentMethodCount("talk.session.appendAudio"), 1)
        XCTAssertEqual(engine.stopPlaybackCount, 1)

        engine.emitInput(peak: 0.2)
        provider.prepare()
        XCTAssertEqual(try socket.sentMethodCount("talk.session.cancelOutput"), 1)

        deliverAssistantTurnEnded(provider: provider, socket: socket)
        deliverAssistantAudio(provider: provider, socket: socket)
        engine.updateState(speakerState(playbackActive: true))
        provider.prepare()
        for _ in 0..<3 {
            engine.emitInput(peak: 0.2)
            provider.prepare()
        }

        XCTAssertEqual(try socket.sentMethodCount("talk.session.cancelOutput"), 2)
        XCTAssertEqual(engine.stopPlaybackCount, 2)
        XCTAssertEqual(engine.beginAssistantAudioTurnCount, 2)
        withExtendedLifetime(provider) {}
    }

    func testLoudReplyDuringHangoverOpensGateWithoutCancellingOutput() throws {
        let clock = OpenClawSpeakerModeTestClock()
        let engine = OpenClawSpeakerModeFakeAudioEngine(state: speakerState)
        let socket = OpenClawSpeakerModeFakeWebSocket()
        let provider = makeConnectedProvider(
            engine: engine,
            socket: socket,
            now: { clock.date }
        )
        deliverAssistantAudio(provider: provider, socket: socket)
        engine.updateState(speakerState(playbackActive: true))
        provider.prepare()
        deliverAssistantTurnEnded(provider: provider, socket: socket)
        engine.updateState(speakerState(playbackActive: false))
        provider.prepare()

        clock.advance(milliseconds: 200)
        for _ in 0..<3 {
            engine.emitInput(peak: 0.2)
            provider.prepare()
        }

        XCTAssertEqual(try socket.sentMethodCount("talk.session.cancelOutput"), 0)
        XCTAssertEqual(try socket.sentMethodCount("talk.session.appendAudio"), 1)
        XCTAssertEqual(engine.stopPlaybackCount, 0)
        withExtendedLifetime(provider) {}
    }

    func testHeadphoneModeKeepsImmediateBargeInAndStreamsMicAudio() throws {
        let engine = OpenClawSpeakerModeFakeAudioEngine(
            state: headphoneState(playbackActive: true)
        )
        let socket = OpenClawSpeakerModeFakeWebSocket()
        let provider = makeConnectedProvider(engine: engine, socket: socket)
        deliverAssistantAudio(provider: provider, socket: socket)

        engine.emitInput(peak: 0.03)
        provider.prepare()

        XCTAssertEqual(try socket.sentMethodCount("talk.session.cancelOutput"), 1)
        XCTAssertEqual(try socket.sentMethodCount("talk.session.appendAudio"), 1)
        XCTAssertEqual(engine.stopPlaybackCount, 0)
        withExtendedLifetime(provider) {}
    }

    func testInactiveAECForcesGatingWhenPreferenceIsOff() throws {
        let forcedState = RealtimeAudioEngineState(
            outputRoute: .headphones,
            isEchoCancellationActive: false,
            isPlaybackActive: true,
            currentAssistantPlayedDurationMilliseconds: 0
        )
        let engine = OpenClawSpeakerModeFakeAudioEngine(state: forcedState)
        let socket = OpenClawSpeakerModeFakeWebSocket()
        var configuration = testConfiguration
        configuration.speakerModePreference = .off
        let diagnostic = expectation(description: "AEC fallback diagnostic")
        let provider = makeConnectedProvider(
            engine: engine,
            socket: socket,
            configuration: configuration,
            onEvent: { event in
                guard case let .diagnostic(message) = event,
                      message.contains("Echo cancellation is inactive") else {
                    return
                }
                diagnostic.fulfill()
            }
        )

        engine.emitInput(peak: 0.01)
        provider.prepare()

        XCTAssertEqual(try socket.sentMethodCount("talk.session.appendAudio"), 0)
        wait(for: [diagnostic], timeout: 1)
        withExtendedLifetime(provider) {}
    }

    func testSpeakerGateStateResetsAcrossTeardownAndReconnect() throws {
        let clock = OpenClawSpeakerModeTestClock()
        let engine = OpenClawSpeakerModeFakeAudioEngine(state: speakerState)
        let firstSocket = OpenClawSpeakerModeFakeWebSocket()
        let secondSocket = OpenClawSpeakerModeFakeWebSocket()
        let sockets = [firstSocket, secondSocket]
        var socketIndex = 0
        let provider = OpenClawTalkProvider(
            configuration: testConfiguration,
            tokenProvider: { "test-token" },
            audioEngine: engine,
            deviceCredentialsProvider: { nil },
            webSocketFactory: { _ in
                defer { socketIndex += 1 }
                return sockets[socketIndex]
            },
            watchdogScheduler: { _, _ in
                OpenClawSpeakerModeFakeWatchdog()
            },
            gateNow: { clock.date }
        )

        provider.toggleVoice()
        completeHandshake(provider: provider, socket: firstSocket)
        engine.updateState(speakerState(playbackActive: true))
        provider.prepare()
        engine.updateState(speakerState(playbackActive: false))
        provider.prepare()
        provider.stopVoice()

        provider.toggleVoice()
        completeHandshake(provider: provider, socket: secondSocket)
        engine.emitInput(peak: 0.01)
        provider.prepare()

        XCTAssertEqual(try secondSocket.sentMethodCount("talk.session.appendAudio"), 1)
        withExtendedLifetime(provider) {}
    }

    private var testConfiguration: VoiceSessionConfiguration {
        VoiceSessionConfiguration(
            providerID: .openClaw,
            model: "",
            voice: "",
            instructions: "",
            endpointURL: "ws://gateway.test"
        )
    }

    private var speakerState: RealtimeAudioEngineState {
        speakerState(playbackActive: false)
    }

    private func speakerState(playbackActive: Bool) -> RealtimeAudioEngineState {
        RealtimeAudioEngineState(
            outputRoute: .unknown,
            isEchoCancellationActive: true,
            isPlaybackActive: playbackActive,
            currentAssistantPlayedDurationMilliseconds: 0
        )
    }

    private func headphoneState(playbackActive: Bool) -> RealtimeAudioEngineState {
        RealtimeAudioEngineState(
            outputRoute: .headphones,
            isEchoCancellationActive: true,
            isPlaybackActive: playbackActive,
            currentAssistantPlayedDurationMilliseconds: 0
        )
    }

    private func makeConnectedProvider(
        engine: OpenClawSpeakerModeFakeAudioEngine,
        socket: OpenClawSpeakerModeFakeWebSocket,
        configuration: VoiceSessionConfiguration? = nil,
        now: @escaping () -> Date = Date.init,
        onEvent: ((VoiceProviderEvent) -> Void)? = nil
    ) -> OpenClawTalkProvider {
        let provider = OpenClawTalkProvider(
            configuration: configuration ?? testConfiguration,
            tokenProvider: { "test-token" },
            audioEngine: engine,
            deviceCredentialsProvider: { nil },
            webSocketFactory: { _ in socket },
            watchdogScheduler: { _, _ in
                OpenClawSpeakerModeFakeWatchdog()
            },
            gateNow: now
        )
        provider.onEvent = onEvent
        provider.toggleVoice()
        completeHandshake(provider: provider, socket: socket)
        return provider
    }

    private func completeHandshake(
        provider: OpenClawTalkProvider,
        socket: OpenClawSpeakerModeFakeWebSocket
    ) {
        socket.deliver(
            #"{"type":"event","event":"connect.challenge","payload":{"nonce":"nonce"}}"#
        )
        provider.prepare()
        socket.deliver(
            #"{"type":"res","id":"1","ok":true,"payload":{"type":"hello-ok"}}"#
        )
        provider.prepare()
        socket.deliver(
            #"{"type":"res","id":"2","ok":true,"payload":{"sessionId":"session-1","relaySessionId":"relay-1"}}"#
        )
        provider.prepare()
        socket.deliver(talkEventFrame(
            #"{"relaySessionId":"relay-1","type":"ready"}"#
        ))
        provider.prepare()
    }

    private func deliverAssistantAudio(
        provider: OpenClawTalkProvider,
        socket: OpenClawSpeakerModeFakeWebSocket
    ) {
        socket.deliver(talkEventFrame(
            #"{"relaySessionId":"relay-1","type":"audio","audioBase64":"AAE="}"#
        ))
        provider.prepare()
    }

    private func deliverAssistantTurnEnded(
        provider: OpenClawTalkProvider,
        socket: OpenClawSpeakerModeFakeWebSocket
    ) {
        socket.deliver(talkEventFrame(
            #"{"relaySessionId":"relay-1","type":"audioDone"}"#
        ))
        provider.prepare()
    }

    private func talkEventFrame(_ envelope: String) -> String {
        #"{"type":"event","event":"talk.event","payload":\#(envelope)}"#
    }
}

private final class OpenClawSpeakerModeTestClock {
    private(set) var date = Date(timeIntervalSince1970: 100)

    func advance(milliseconds: Int) {
        date = date.addingTimeInterval(TimeInterval(milliseconds) / 1_000)
    }
}

private final class OpenClawSpeakerModeFakeAudioEngine: RealtimeAudioEngineProtocol {
    private var state: RealtimeAudioEngineState
    private var stateChangeHandler: ((RealtimeAudioEngineState) -> Void)?
    private var inputHandler: ((Data) -> Void)?
    private var activityHandler: ((RealtimeAudioInputActivity) -> Void)?
    private(set) var stopPlaybackCount = 0
    private(set) var beginAssistantAudioTurnCount = 0

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

    func stop() {
        inputHandler = nil
        activityHandler = nil
    }

    func stopPlayback() {
        stopPlaybackCount += 1
        state.isPlaybackActive = false
        stateChangeHandler?(state)
    }

    func beginAssistantAudioTurn() {
        beginAssistantAudioTurnCount += 1
    }

    func playPCM16(_ data: Data) {}

    func updateState(_ state: RealtimeAudioEngineState) {
        self.state = state
        stateChangeHandler?(state)
    }

    func emitInput(peak: Float) {
        activityHandler?(RealtimeAudioInputActivity(rms: peak / 2, peak: peak))
        inputHandler?(Data(repeating: 0, count: 9_600))
    }
}

private final class OpenClawSpeakerModeFakeWebSocket: OpenClawTalkWebSocket {
    var onOpen: (() -> Void)?
    var onClose: ((URLSessionWebSocketTask.CloseCode) -> Void)?
    private(set) var sentMessages: [URLSessionWebSocketTask.Message] = []
    private var receiveCompletions: [
        (Result<URLSessionWebSocketTask.Message, Error>) -> Void
    ] = []

    func resume() {
        onOpen?()
    }

    func receive(
        completionHandler: @escaping (Result<URLSessionWebSocketTask.Message, Error>) -> Void
    ) {
        receiveCompletions.append(completionHandler)
    }

    func send(
        _ message: URLSessionWebSocketTask.Message,
        completionHandler: @escaping (Error?) -> Void
    ) {
        sentMessages.append(message)
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {}

    func invalidateAndCancel() {}

    func deliver(_ text: String) {
        receiveCompletions.removeFirst()(.success(.string(text)))
    }

    func sentMethodCount(_ method: String) throws -> Int {
        try sentMessages.reduce(into: 0) { count, message in
            guard case let .string(text) = message,
                  let data = text.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }
            if object["method"] as? String == method {
                count += 1
            }
        }
    }
}

private final class OpenClawSpeakerModeFakeWatchdog: OpenClawTalkWatchdogCancellation {
    func cancel() {}
}
