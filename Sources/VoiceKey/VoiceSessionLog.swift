import Foundation

struct VoiceSessionLog: Equatable {
    private enum Entry: Equatable {
        case status(timestamp: Date, provider: VoiceProviderID, title: String)
        case transcript(
            timestamp: Date,
            provider: VoiceProviderID,
            summary: PublishableTranscriptSummary
        )
        case diagnostic(timestamp: Date, provider: VoiceProviderID, text: String)

        var line: String {
            switch self {
            case let .status(timestamp, provider, title):
                return "\(prefix(timestamp: timestamp, provider: provider)) status: \(title)"
            case let .transcript(timestamp, provider, summary):
                return "\(prefix(timestamp: timestamp, provider: provider)) transcript: \(summary.text)"
            case let .diagnostic(timestamp, provider, text):
                return "\(prefix(timestamp: timestamp, provider: provider)) diagnostic: \(text)"
            }
        }

        private func prefix(timestamp: Date, provider: VoiceProviderID) -> String {
            "[\(Self.timestampFormatter.string(from: timestamp))] \(provider.displayName)"
        }

        private static let timestampFormatter: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return formatter
        }()
    }

    private var entries: [Entry] = []

    var isEmpty: Bool {
        entries.isEmpty
    }

    var displayText: String {
        guard entries.isEmpty == false else {
            return "No voice session activity yet."
        }
        return entries.map(\.line).joined(separator: "\n")
    }

    mutating func append(_ event: VoiceProviderEvent, provider: VoiceProviderID, timestamp: Date = Date()) {
        switch event {
        case let .status(status):
            appendStatus(status, provider: provider, timestamp: timestamp)
        case let .transcript(delta):
            appendTranscriptDelta(delta, provider: provider, timestamp: timestamp)
        case let .diagnostic(message):
            appendDiagnostic(message, provider: provider, timestamp: timestamp)
        }
    }

    mutating func clear() {
        entries.removeAll()
    }

    private mutating func appendStatus(_ status: ProviderStatus, provider: VoiceProviderID, timestamp: Date) {
        if case .ready = status, entries.isEmpty {
            return
        }
        entries.append(.status(timestamp: timestamp, provider: provider, title: statusLogTitle(status)))
    }

    private mutating func appendTranscriptDelta(_ delta: String, provider: VoiceProviderID, timestamp: Date) {
        guard let summary = PublishableTranscriptSummary(delta: delta) else {
            return
        }

        if let last = entries.last,
           case let .transcript(
               lastTimestamp,
               lastProvider,
               lastSummary
           ) = last,
           lastProvider == provider,
           let combined = lastSummary.appending(summary) {
            entries[entries.count - 1] = .transcript(
                timestamp: lastTimestamp,
                provider: provider,
                summary: combined
            )
            return
        }

        entries.append(.transcript(
            timestamp: timestamp,
            provider: provider,
            summary: summary
        ))
    }

    private mutating func appendDiagnostic(_ message: String, provider: VoiceProviderID, timestamp: Date) {
        guard message.isEmpty == false else { return }
        entries.append(.diagnostic(timestamp: timestamp, provider: provider, text: message))
    }

    private func statusLogTitle(_ status: ProviderStatus) -> String {
        if let detail = status.detail {
            return "\(status.menuTitle) - \(detail)"
        }
        return status.menuTitle
    }
}
