import Foundation

/// Appends every session-log event to a daily file under
/// ~/Library/Logs/VoiceKey so live-test evidence survives app relaunches.
/// Local-only, with stable provider wire names (transcripts are written as
/// deltas, uncoalesced); never contains credentials.
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
            guard delta.isEmpty == false else { return }
            kind = "transcript"
            text = delta
        case let .diagnostic(message):
            guard message.isEmpty == false else { return }
            kind = "diagnostic"
            text = message
        }

        let line = "[\(Self.timestampFormatter.string(from: timestamp))] \(provider.logWireName) \(kind): \(text)\n"
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
