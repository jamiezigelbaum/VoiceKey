@testable import VoiceKey
import XCTest

final class OpenAIRealtimeConnectionCheckTests: XCTestCase {
    func testSessionCreatedKeepsWaiting() {
        XCTAssertEqual(
            OpenAIRealtimeConnectionCheckEventMapper.result(from: #"{"type":"session.created"}"#),
            .waiting("session.created")
        )
    }

    func testSessionUpdatedSucceeds() {
        XCTAssertEqual(
            OpenAIRealtimeConnectionCheckEventMapper.result(from: #"{"type":"session.updated"}"#),
            .succeeded("session.updated")
        )
    }

    func testErrorFailsWithMessage() {
        XCTAssertEqual(
            OpenAIRealtimeConnectionCheckEventMapper.result(
                from: #"{"type":"error","error":{"message":"Invalid API key"}}"#
            ),
            .failed("Invalid API key")
        )
    }

    func testMalformedEventIsIgnored() {
        XCTAssertNil(OpenAIRealtimeConnectionCheckEventMapper.result(from: "not json"))
    }
}
