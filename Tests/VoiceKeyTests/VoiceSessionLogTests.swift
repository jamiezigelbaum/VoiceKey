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
            [2026-06-14T12:00:01Z] ChatGPT (web) transcript: hi
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

final class VoiceSessionLogFileTests: XCTestCase {
    func testProviderRenameDoesNotChangeOnDiskWireTerm() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "VoiceSessionLogFileTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let logFile = VoiceSessionLogFile(directory: directory)

        logFile.append(
            .diagnostic("connected"),
            provider: .chatGPTWeb,
            timestamp: Date(timeIntervalSince1970: 1_800_000_000)
        )
        logFile.waitForPendingWrites()

        let file = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).first(where: { $0.lastPathComponent.hasPrefix("session-") })
        )
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("ChatGPT Web (OAuth) diagnostic"))
        XCTAssertFalse(text.contains("ChatGPT (web)"))
    }

    func testAppendDeletesOnlyExpiredSessionLogFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceSessionLogFileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }

        let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)
        let expiredLog = directory.appendingPathComponent("session-expired.log")
        let retainedLog = directory.appendingPathComponent("session-recent.log")
        let unrelatedFile = directory.appendingPathComponent("diagnostics.log")
        try Data("old session".utf8).write(to: expiredLog)
        try Data("recent session".utf8).write(to: retainedLog)
        try Data("unrelated".utf8).write(to: unrelatedFile)
        try FileManager.default.setAttributes(
            [.modificationDate: referenceDate.addingTimeInterval(-15 * 24 * 60 * 60)],
            ofItemAtPath: expiredLog.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: referenceDate.addingTimeInterval(-13 * 24 * 60 * 60)],
            ofItemAtPath: retainedLog.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: referenceDate.addingTimeInterval(-30 * 24 * 60 * 60)],
            ofItemAtPath: unrelatedFile.path
        )

        let logFile = VoiceSessionLogFile(directory: directory, retentionDays: 14)
        logFile.append(
            .diagnostic("retention check"),
            provider: .openAIRealtime,
            timestamp: referenceDate
        )
        logFile.waitForPendingWrites()

        XCTAssertFalse(FileManager.default.fileExists(atPath: expiredLog.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: retainedLog.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedFile.path))
    }
}
