@testable import VoiceKey
import XCTest

final class VoiceSessionLogTests: XCTestCase {
    private let timestamp = Date(timeIntervalSince1970: 1_781_438_400)

    func testEmptyLogShowsPlaceholder() {
        let log = VoiceSessionLog()

        XCTAssertTrue(log.isEmpty)
        XCTAssertEqual(log.displayText, "No voice session activity yet.")
    }

    func testTranscriptDeltasCoalesceForSameProvider() {
        var log = VoiceSessionLog()

        log.append(.transcript("hel"), provider: .openAIRealtime, timestamp: timestamp)
        log.append(.transcript("lo"), provider: .openAIRealtime, timestamp: timestamp.addingTimeInterval(1))

        XCTAssertEqual(log.displayText, "[2026-06-14T12:00:00Z] OpenAI Realtime API transcript: hello")
    }

    func testTranscriptDeltasDoNotCoalesceAcrossProviders() {
        var log = VoiceSessionLog()

        log.append(.transcript("hello"), provider: .openAIRealtime, timestamp: timestamp)
        log.append(.transcript("hi"), provider: .chatGPTWeb, timestamp: timestamp.addingTimeInterval(1))

        XCTAssertEqual(
            log.displayText,
            """
            [2026-06-14T12:00:00Z] OpenAI Realtime API transcript: hello
            [2026-06-14T12:00:01Z] ChatGPT Web (OAuth) transcript: hi
            """
        )
    }

    func testStatusAndDiagnosticsAreLogged() {
        var log = VoiceSessionLog()

        log.append(.status(.listening), provider: .openAIRealtime, timestamp: timestamp)
        log.append(.diagnostic("rate_limits.updated"), provider: .openAIRealtime, timestamp: timestamp.addingTimeInterval(1))

        XCTAssertEqual(
            log.displayText,
            """
            [2026-06-14T12:00:00Z] OpenAI Realtime API status: Listening
            [2026-06-14T12:00:01Z] OpenAI Realtime API diagnostic: rate_limits.updated
            """
        )
    }

    func testInitialReadyStatusIsIgnored() {
        var log = VoiceSessionLog()

        log.append(.status(.ready), provider: .openAIRealtime, timestamp: timestamp)

        XCTAssertTrue(log.isEmpty)
        XCTAssertEqual(log.displayText, "No voice session activity yet.")
    }

    func testClearRemovesEntries() {
        var log = VoiceSessionLog()
        log.append(.diagnostic("connected"), provider: .openAIRealtime, timestamp: timestamp)

        log.clear()

        XCTAssertTrue(log.isEmpty)
    }
}
