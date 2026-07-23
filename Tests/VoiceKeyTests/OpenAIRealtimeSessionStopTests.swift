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
}

private final class FakeRealtimeAudioEngine: RealtimeAudioEngineProtocol {
    private(set) var microphoneAccessRequestCount = 0
    private(set) var stopCount = 0

    func requestMicrophoneAccess(_ completion: @escaping (Bool) -> Void) {
        microphoneAccessRequestCount += 1
    }

    func start(
        inputHandler: @escaping (Data) -> Void,
        activityHandler: @escaping (RealtimeAudioInputActivity) -> Void
    ) throws {}

    func stop() {
        stopCount += 1
    }

    func stopPlayback() {}

    func playPCM16(_ data: Data) {}
}
