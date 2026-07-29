import Foundation

/// Appends every session-log event to a daily file under
/// ~/Library/Logs/VoiceKey so live-test evidence survives app relaunches.
/// Publishable, with stable provider wire names. Transcript content is reduced
/// to role and counts before it reaches the queue or disk.
/// Subsystems that are not voice providers — the onboarding wizard — write
/// through `append(component:kind:text:)` into the same file.
final class VoiceSessionLogFile {
    private let directory: URL
    private let retentionDays: Int
    private let queue = DispatchQueue(label: "VoiceKey.VoiceSessionLogFile", qos: .utility)

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/VoiceKey", isDirectory: true),
         retentionDays: Int = 14) {
        self.directory = directory
        self.retentionDays = retentionDays
    }

    func append(_ event: VoiceProviderEvent, provider: VoiceProviderID, timestamp: Date = Date()) {
        let kind: String
        let text: String
        switch event {
        case let .status(status):
            kind = "status"
            text = status.detail.map { "\(status.menuTitle) - \($0)" } ?? status.menuTitle
        case let .transcript(delta):
            guard let summary = PublishableTranscriptSummary(
                delta: delta
            ) else {
                return
            }
            kind = "transcript"
            text = summary.text
        case let .diagnostic(message):
            guard message.isEmpty == false else { return }
            kind = "diagnostic"
            text = message
        }

        append(label: provider.logWireName, kind: kind, text: text, timestamp: timestamp)
    }

    /// Non-provider subsystems (the onboarding wizard) share the same daily
    /// file, retention and timestamp format: `component` takes the slot the
    /// provider wire name occupies, so one line shape covers both and a
    /// walkthrough can be read straight out of the session log.
    func append(
        component: String,
        kind: String,
        text: String,
        timestamp: Date = Date()
    ) {
        guard component.isEmpty == false,
              kind.isEmpty == false,
              text.isEmpty == false else {
            return
        }
        // One event is one line: a message carrying newlines would otherwise
        // read as several unattributed entries.
        let singleLine = text
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
        append(label: component, kind: kind, text: singleLine, timestamp: timestamp)
    }

    private func append(label: String, kind: String, text: String, timestamp: Date) {
        let line = "[\(Self.timestampFormatter.string(from: timestamp))] \(label) \(kind): \(text)\n"
        let fileURL = directory.appendingPathComponent(
            "session-\(Self.dayFormatter.string(from: timestamp)).log"
        )

        queue.async { [directory, retentionDays] in
            let fileManager = FileManager.default
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            Self.pruneExpiredLogs(
                in: directory,
                retentionDays: retentionDays,
                referenceDate: timestamp,
                fileManager: fileManager
            )
            if fileManager.fileExists(atPath: fileURL.path) == false {
                fileManager.createFile(atPath: fileURL.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }

    func clearToday(timestamp: Date = Date()) {
        let fileURL = directory.appendingPathComponent(
            "session-\(Self.dayFormatter.string(from: timestamp)).log"
        )
        queue.async {
            guard FileManager.default.fileExists(
                atPath: fileURL.path
            ), let handle = try? FileHandle(
                forWritingTo: fileURL
            ) else {
                return
            }
            defer { try? handle.close() }
            try? handle.truncate(atOffset: 0)
        }
    }

    func waitForPendingWrites() {
        queue.sync {}
    }

    private static func pruneExpiredLogs(
        in directory: URL,
        retentionDays: Int,
        referenceDate: Date,
        fileManager: FileManager
    ) {
        guard retentionDays >= 0 else { return }
        let expirationDate = referenceDate.addingTimeInterval(
            -TimeInterval(retentionDays) * 24 * 60 * 60
        )
        let files = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        for file in files {
            let name = file.lastPathComponent
            guard name.hasPrefix("session-"), name.hasSuffix(".log"),
                  let values = try? file.resourceValues(
                    forKeys: [.contentModificationDateKey, .isRegularFileKey]
                  ),
                  values.isRegularFile == true,
                  let modificationDate = values.contentModificationDate,
                  modificationDate < expirationDate else {
                continue
            }
            try? fileManager.removeItem(at: file)
        }
    }
}

extension VoiceSessionLogFile: OnboardingDiagnosticsLogging {
    func record(_ event: OnboardingLogEvent, timestamp: Date) {
        append(
            component: OnboardingLogEvent.component,
            kind: event.kind,
            text: event.text,
            timestamp: timestamp
        )
    }
}
