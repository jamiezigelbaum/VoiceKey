@testable import VoiceKey
import Foundation
import XCTest

final class OpenClawTalkSessionStopTests: XCTestCase {
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
        // OpenClawTalkProvider.toggleVoice() shares this decision with the
        // OpenAI provider; pinning it here guards the OpenClaw-side regression:
        // a session that is only streaming audio must stop, never start a
        // second session that abandons the engine.
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
        XCTAssertEqual(
            VoiceToggleDecision.decide(isStarting: false, isConnecting: false, isConnected: false, isAudioStreaming: true),
            .stop
        )
        XCTAssertEqual(
            VoiceToggleDecision.decide(isStarting: false, isConnecting: false, isConnected: false, isAudioStreaming: false),
            .start
        )
    }

    func testToggleWithoutTokenDoesNotTouchAudioEngine() {
        let audioEngine = FakeRealtimeAudioEngine()
        let provider = OpenClawTalkProvider(
            configuration: testConfiguration,
            tokenResolutionProvider: { nil },
            audioEngine: audioEngine,
            deviceCredentialsProvider: { nil }
        )

        provider.toggleVoice()

        XCTAssertEqual(audioEngine.microphoneAccessRequestCount, 0)
        XCTAssertEqual(audioEngine.stopCount, 0)
    }

    func testUpdateConfigurationOnIdleProviderDoesNotTouchAudioEngine() {
        let audioEngine = FakeRealtimeAudioEngine()
        let provider = makeProvider(audioEngine: audioEngine)

        provider.update(configuration: VoiceSessionConfiguration(
            providerID: .openClaw,
            model: "",
            voice: "",
            instructions: "Other instructions.",
            endpointURL: "ws://127.0.0.1:18789"
        ))

        XCTAssertEqual(audioEngine.microphoneAccessRequestCount, 0)
        XCTAssertEqual(audioEngine.stopCount, 0)
    }

    private func makeProvider(audioEngine: FakeRealtimeAudioEngine) -> OpenClawTalkProvider {
        OpenClawTalkProvider(
            configuration: testConfiguration,
            tokenResolutionProvider: {
            OpenClawGatewayTokenResolution(
                token: "test-gateway-token",
                source: .enteredToken
            )
        },
            audioEngine: audioEngine,
            deviceCredentialsProvider: { nil }
        )
    }

    private var testConfiguration: VoiceSessionConfiguration {
        VoiceSessionConfiguration(
            providerID: .openClaw,
            model: "",
            voice: "",
            instructions: "",
            endpointURL: ""
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
