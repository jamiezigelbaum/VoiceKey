@testable import VoiceKey
import Foundation
import XCTest

final class OpenAIRealtimeProviderTests: XCTestCase {
    func testToggleWhileMicrophonePermissionIsPendingStopsInsteadOfStartingAgain() {
        let audioEngine = FakeRealtimeAudioEngine()
        let provider = OpenAIRealtimeProvider(
            configuration: testConfiguration,
            apiKeyProvider: { "test-api-key" },
            audioEngine: audioEngine
        )

        provider.toggleVoice()
        provider.toggleVoice()

        XCTAssertEqual(audioEngine.microphoneAccessRequestCount, 1)
        XCTAssertEqual(audioEngine.stopCount, 1)
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
