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
            disableVoiceProcessing: {
                operations.append("disable voice processing")
            },
            shield: { _, operation in
                try operation()
            }
        )

        XCTAssertEqual(
            operations,
            [
                "remove tap", "stop playback", "stop engine",
                "disable voice processing"
            ],
            """
            voice processing must be released, and released after the engine \
            has stopped: leaving it on keeps the system output in the \
            communications path, which ducks every other app to about half \
            volume for as long as VoiceKey runs.
            """
        )
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

extension RealtimeAudioEngineSafetyTests {
    /// The ducking outlived the voice session because this step did not exist.
    /// A throwing engine stop must not skip it — that is exactly the state
    /// (a wedged engine) where the owner is most likely to be left quiet.
    func testTeardownReleasesVoiceProcessingEvenWhenStoppingTheEngineThrows() {
        var operations: [String] = []

        RealtimeAudioEngine.performTeardown(
            removeTap: { operations.append("remove tap") },
            stopPlayback: { operations.append("stop playback") },
            stopEngine: {
                operations.append("stop engine")
                throw TeardownError.expected
            },
            disableVoiceProcessing: {
                operations.append("disable voice processing")
            },
            shield: { _, operation in try operation() }
        )

        XCTAssertEqual(operations.last, "disable voice processing")
    }
}

extension RealtimeAudioEngineSafetyTests {
    /// Teardown turns voice processing off so other apps stop being ducked.
    /// Nothing else turns it back on, so a start that skips this leaves echo
    /// cancellation dead for every session after the first.
    func testStartArmsVoiceProcessingBeforeCapturing() throws {
        var operations: [String] = []

        try RealtimeAudioEngine.performStart(
            armVoiceProcessing: { operations.append("arm voice processing") },
            startCapture: { operations.append("start capture") }
        )

        XCTAssertEqual(
            operations,
            ["arm voice processing", "start capture"],
            """
            voice processing must be armed before capture begins: the setting \
            cannot be changed on a running engine, and teardown left it off.
            """
        )
    }

    /// A session must still start when arming fails — degraded echo
    /// cancellation is better than no voice at all, and the speaker-mode policy
    /// already forces mic gating when AEC is inactive.
    func testCaptureStillStartsWhenArmingVoiceProcessingFails() throws {
        var captured = false

        try RealtimeAudioEngine.performStart(
            armVoiceProcessing: { /* swallowed failure, as in production */ },
            startCapture: { captured = true }
        )

        XCTAssertTrue(captured)
    }
}
