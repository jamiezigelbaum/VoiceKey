@testable import VoiceKey
import Foundation
import XCTest

final class OpenAIRealtimeConnectionDiagnosticsTests: XCTestCase {
    func testNormalClosureReturnsReady() {
        XCTAssertEqual(
            OpenAIRealtimeConnectionDiagnostics.closeStatus(code: .normalClosure, reason: nil),
            .ready
        )
    }

    func testGoingAwayClosureReturnsReady() {
        XCTAssertEqual(
            OpenAIRealtimeConnectionDiagnostics.closeStatus(code: .goingAway, reason: nil),
            .ready
        )
    }

    func testAbnormalClosureReturnsNeedsAttentionWithCode() {
        XCTAssertEqual(
            OpenAIRealtimeConnectionDiagnostics.closeStatus(code: .invalid, reason: nil),
            .needsAttention("OpenAI Realtime WebSocket closed with code 0.")
        )
    }

    func testAbnormalClosureIncludesReasonText() {
        let reason = Data("Invalid API key".utf8)

        XCTAssertEqual(
            OpenAIRealtimeConnectionDiagnostics.closeStatus(code: .invalid, reason: reason),
            .needsAttention("OpenAI Realtime WebSocket closed with code 0: Invalid API key")
        )
    }
}
