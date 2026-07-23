@testable import VoiceKey
import XCTest

final class RealtimeAudioEngineSafetyTests: XCTestCase {
    func testTeardownStillStopsEngineWhenRemovingTapThrows() {
        var operations: [String] = []

        RealtimeAudioEngine.performTeardown(
            removeTap: {
                operations.append("remove tap")
                throw TeardownError.expected
            },
            stopPlayback: {
                operations.append("stop playback")
            },
            stopEngine: {
                operations.append("stop engine")
            },
            shield: { _, operation in
                try operation()
            }
        )

        XCTAssertEqual(operations, ["remove tap", "stop playback", "stop engine"])
    }

    func testPlayedDurationPrefersRenderedFramesAndClampsToScheduledAudio() {
        XCTAssertEqual(
            RealtimeAudioEngine.playedDurationMilliseconds(
                renderedFrameCount: 2_400,
                scheduledFrameCount: 4_800
            ),
            100
        )
        XCTAssertEqual(
            RealtimeAudioEngine.playedDurationMilliseconds(
                renderedFrameCount: 9_600,
                scheduledFrameCount: 4_800
            ),
            200
        )
    }

    func testPlayedDurationFallsBackToScheduledPCM24kFrames() {
        XCTAssertEqual(
            RealtimeAudioEngine.playedDurationMilliseconds(
                renderedFrameCount: nil,
                scheduledFrameCount: 6_000
            ),
            250
        )
    }
}

private enum TeardownError: Error {
    case expected
}
