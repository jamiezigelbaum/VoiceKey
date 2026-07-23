import Foundation

/// Appends every session-log event to a daily file under
/// ~/Library/Logs/VoiceKey so live-test evidence survives app relaunches.
/// Local-only, same content as Copy Session Log (transcripts are written
/// as deltas, uncoalesced); never contains credentials.
final class VoiceSessionLogFile {
    private let directory: URL
    private let queue = DispatchQueue(label: "VoiceKey.VoiceSessionLogFile", qos: .utility)

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/VoiceKey", isDirectory: true)) {
        self.directory = directory
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

        let line = "[\(Self.timestampFormatter.string(from: timestamp))] \(provider.displayName) \(kind): \(text)\n"
        let fileURL = directory.appendingPathComponent(
            "session-\(Self.dayFormatter.string(from: timestamp)).log"
        )

        queue.async { [directory] in
            let fileManager = FileManager.default
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: fileURL.path) == false {
                fileManager.createFile(atPath: fileURL.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }
}
