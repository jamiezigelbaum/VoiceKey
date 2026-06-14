@testable import VoiceKey
import XCTest

final class VoiceSessionLogTests: XCTestCase {
    func testEmptyLogShowsPlaceholder() {
        let log = VoiceSessionLog()

        XCTAssertTrue(log.isEmpty)
        XCTAssertEqual(log.displayText, "No voice session activity yet.")
    }

    func testTranscriptDeltasCoalesceForSameProvider() {
        var log = VoiceSessionLog()

        log.append(.transcript("hel"), provider: .openAIRealtime)
        log.append(.transcript("lo"), provider: .openAIRealtime)

        XCTAssertEqual(log.displayText, "OpenAI Realtime API transcript: hello")
    }

    func testTranscriptDeltasDoNotCoalesceAcrossProviders() {
        var log = VoiceSessionLog()

        log.append(.transcript("hello"), provider: .openAIRealtime)
        log.append(.transcript("hi"), provider: .chatGPTWeb)

        XCTAssertEqual(
            log.displayText,
            """
            OpenAI Realtime API transcript: hello
            ChatGPT Web (OAuth) transcript: hi
            """
        )
    }

    func testStatusAndDiagnosticsAreLogged() {
        var log = VoiceSessionLog()

        log.append(.status(.listening), provider: .openAIRealtime)
        log.append(.diagnostic("rate_limits.updated"), provider: .openAIRealtime)

        XCTAssertEqual(
            log.displayText,
            """
            OpenAI Realtime API status: Listening
            OpenAI Realtime API diagnostic: rate_limits.updated
            """
        )
    }

    func testInitialReadyStatusIsIgnored() {
        var log = VoiceSessionLog()

        log.append(.status(.ready), provider: .openAIRealtime)

        XCTAssertTrue(log.isEmpty)
        XCTAssertEqual(log.displayText, "No voice session activity yet.")
    }

    func testClearRemovesEntries() {
        var log = VoiceSessionLog()
        log.append(.diagnostic("connected"), provider: .openAIRealtime)

        log.clear()

        XCTAssertTrue(log.isEmpty)
    }
}
