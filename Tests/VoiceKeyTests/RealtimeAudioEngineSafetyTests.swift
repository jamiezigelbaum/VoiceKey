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
}

private enum TeardownError: Error {
    case expected
}
