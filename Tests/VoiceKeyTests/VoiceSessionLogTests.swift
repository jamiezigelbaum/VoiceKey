@testable import VoiceKey
import XCTest

final class VoiceSessionLogTests: XCTestCase {
    private let timestamp = Date(timeIntervalSince1970: 1_781_438_400)

    func testEmptyLogShowsPlaceholder() {
        let log = VoiceSessionLog()

        XCTAssertTrue(log.isEmpty)
        XCTAssertEqual(log.displayText, "No voice session activity yet.")
    }

    func testTranscriptDeltasCoalesceAsStructuralFactsWithoutText() {
        var log = VoiceSessionLog()

        log.append(.transcript("hel"), provider: .openAIRealtime, timestamp: timestamp)
        log.append(.transcript("lo"), provider: .openAIRealtime, timestamp: timestamp.addingTimeInterval(1))

        XCTAssertEqual(
            log.displayText,
            "[2026-06-14T12:00:00Z] OpenAI Realtime API transcript: assistant turn occurred (2 deltas, 5 characters)"
        )
        XCTAssertFalse(log.displayText.contains("hello"))
    }

    func testTranscriptDeltasDoNotCoalesceAcrossProviders() {
        var log = VoiceSessionLog()

        log.append(.transcript("hello"), provider: .openAIRealtime, timestamp: timestamp)
        log.append(.transcript("hi"), provider: .chatGPTWeb, timestamp: timestamp.addingTimeInterval(1))

        XCTAssertEqual(
            log.displayText,
            """
            [2026-06-14T12:00:00Z] OpenAI Realtime API transcript: assistant turn occurred (1 delta, 5 characters)
            [2026-06-14T12:00:01Z] ChatGPT (web) transcript: assistant turn occurred (1 delta, 2 characters)
            """
        )
    }

    func testUserTranscriptBecomesRoleAndCountsWithoutText() {
        var log = VoiceSessionLog()

        log.append(
            .transcript("You: account number 482917"),
            provider: .openClaw,
            timestamp: timestamp
        )

        XCTAssertEqual(
            log.displayText,
            "[2026-06-14T12:00:00Z] OpenClaw Talk transcript: user turn occurred (1 delta, 21 characters)"
        )
        XCTAssertFalse(log.displayText.contains("482917"))
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
    func testOpenClawEndpointTokenDoesNotReachSessionFileOrDiagnosticsSnapshot() throws {
        let directory = try makeTemporaryDirectory()
        let endpoint = "wss://gateway.example/ws?token=tok_SENTINEL"
        let logFile = VoiceSessionLogFile(directory: directory)
        let provider = OpenClawTalkProvider(
            configuration: VoiceSessionConfiguration(
                providerID: .openClaw,
                model: "",
                voice: "",
                instructions: "",
                endpointURL: endpoint
            ),
            tokenResolutionProvider: {
                OpenClawGatewayTokenResolution(
                    token: "gateway-token",
                    source: .enteredToken
                )
            },
            audioEngine: PublishableLogAudioEngine(),
            webSocketFactory: { _ in PublishableLogWebSocket() }
        )
        provider.onEvent = { event in
            logFile.append(event, provider: .openClaw)
        }

        provider.toggleVoice()
        waitUntil({
            logFile.waitForPendingWrites()
            guard let file = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).first(where: { $0.lastPathComponent.hasPrefix("session-") }),
            let text = try? String(contentsOf: file, encoding: .utf8) else {
                return false
            }
            return text.contains("gateway.example")
        }, "Provider endpoint diagnostic never reached the session file.")

        let file = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).first(where: { $0.lastPathComponent.hasPrefix("session-") })
        )
        let fileText = try String(contentsOf: file, encoding: .utf8)
        let snapshotText = VoiceKeyDiagnosticsSnapshot(
            provider: .openClaw,
            configuration: VoiceSessionConfiguration(
                providerID: .openClaw,
                model: "",
                voice: "",
                instructions: "",
                endpointURL: endpoint
            ),
            readiness: .ready,
            hotKeys: [],
            currentStatus: .starting,
            hasAPIKey: false,
            supportsProviderInterface: true,
            supportsConnectionCheck: false,
            hasSessionLog: true
        ).displayText

        for text in [fileText, snapshotText] {
            XCTAssertFalse(text.contains("tok_SENTINEL"), text)
            XCTAssertTrue(text.contains("gateway.example"), text)
        }
    }

    func testTranscriptContentDoesNotReachSessionFileOrCopiedText() throws {
        let directory = try makeTemporaryDirectory()
        let logFile = VoiceSessionLogFile(directory: directory)
        let transcript = "the recovery code is 482917"
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        var inMemoryLog = VoiceSessionLog()

        inMemoryLog.append(
            .transcript(transcript),
            provider: .openAIRealtime,
            timestamp: timestamp
        )
        logFile.append(
            .transcript(transcript),
            provider: .openAIRealtime,
            timestamp: timestamp
        )
        logFile.waitForPendingWrites()

        let file = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).first(where: { $0.lastPathComponent.hasPrefix("session-") })
        )
        let fileText = try String(contentsOf: file, encoding: .utf8)
        for text in [fileText, inMemoryLog.displayText] {
            XCTAssertFalse(text.contains("482917"), text)
            XCTAssertFalse(text.contains(transcript), text)
            XCTAssertTrue(text.contains("assistant"), text)
            XCTAssertTrue(text.contains("turn occurred"), text)
        }
    }

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

    func testComponentEventsShareTheProviderLineShapeInTheSameDailyFile() throws {
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
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        // Retention is measured against the file's real mtime, which is older
        // than this fixed timestamp; a short window would prune the file
        // between appends.
        let logFile = VoiceSessionLogFile(
            directory: directory,
            retentionDays: 3_650
        )

        logFile.append(
            .diagnostic("connected"),
            provider: .openAIRealtime,
            timestamp: timestamp
        )
        logFile.record(
            .stepTransition(
                from: .welcome,
                to: .services,
                trigger: .advance,
                reason: .noServicesSelected
            ),
            timestamp: timestamp.addingTimeInterval(1)
        )
        // A message carrying newlines still occupies exactly one line.
        logFile.append(
            component: "onboarding",
            kind: "apikey",
            text: "save failed\nchannel=OpenAI",
            timestamp: timestamp.addingTimeInterval(2)
        )
        logFile.waitForPendingWrites()

        let file = directory.appendingPathComponent(
            "session-2027-01-15.log"
        )
        XCTAssertEqual(
            try String(contentsOf: file, encoding: .utf8),
            """
            [2027-01-15T08:00:00Z] OpenAI Realtime API diagnostic: connected
            [2027-01-15T08:00:01Z] onboarding step: welcome -> services trigger=advance reason=no-services-selected
            [2027-01-15T08:00:02Z] onboarding apikey: save failed channel=OpenAI

            """
        )
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

    func testClearTodayTruncatesOnlyTodaysSessionFile() throws {
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
        let today = Date(timeIntervalSince1970: 1_800_000_000)
        let olderFile = directory.appendingPathComponent(
            "session-2027-01-01.log"
        )
        try Data("older session".utf8).write(to: olderFile)
        let logFile = VoiceSessionLogFile(
            directory: directory,
            retentionDays: 3_650
        )
        logFile.append(
            .diagnostic("today"),
            provider: .openAIRealtime,
            timestamp: today
        )

        logFile.clearToday(timestamp: today)
        logFile.waitForPendingWrites()

        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents(
            in: TimeZone(identifier: "UTC")!,
            from: today
        )
        let todayFile = directory.appendingPathComponent(
            String(
                format: "session-%04d-%02d-%02d.log",
                components.year!,
                components.month!,
                components.day!
            )
        )
        XCTAssertEqual(
            try Data(contentsOf: todayFile),
            Data()
        )
        XCTAssertEqual(
            try String(contentsOf: olderFile, encoding: .utf8),
            "older session"
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
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
        return directory
    }
}

private final class PublishableLogAudioEngine: RealtimeAudioEngineProtocol {
    func requestMicrophoneAccess(_ completion: @escaping (Bool) -> Void) {
        completion(true)
    }

    func start(
        inputHandler: @escaping (Data) -> Void,
        activityHandler: @escaping (RealtimeAudioInputActivity) -> Void
    ) throws {}

    func stop() {}
    func stopPlayback() {}
    func playPCM16(_ data: Data) {}
}

private final class PublishableLogWebSocket: OpenClawTalkWebSocket {
    var onOpen: (() -> Void)?
    var onClose: ((URLSessionWebSocketTask.CloseCode) -> Void)?

    func resume() {}

    func receive(
        completionHandler: @escaping (
            Result<URLSessionWebSocketTask.Message, Error>
        ) -> Void
    ) {}

    func send(
        _ message: URLSessionWebSocketTask.Message,
        completionHandler: @escaping (Error?) -> Void
    ) {
        completionHandler(nil)
    }

    func cancel(
        with closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {}

    func invalidateAndCancel() {}
}
