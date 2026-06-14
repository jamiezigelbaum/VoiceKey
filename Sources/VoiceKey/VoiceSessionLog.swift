import Foundation

struct VoiceSessionLog: Equatable {
    private enum Entry: Equatable {
        case status(provider: VoiceProviderID, title: String)
        case transcript(provider: VoiceProviderID, text: String)
        case diagnostic(provider: VoiceProviderID, text: String)

        var line: String {
            switch self {
            case let .status(provider, title):
                return "\(provider.displayName) status: \(title)"
            case let .transcript(provider, text):
                return "\(provider.displayName) transcript: \(text)"
            case let .diagnostic(provider, text):
                return "\(provider.displayName) diagnostic: \(text)"
            }
        }
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

    mutating func append(_ event: VoiceProviderEvent, provider: VoiceProviderID) {
        switch event {
        case let .status(status):
            appendStatus(status, provider: provider)
        case let .transcript(delta):
            appendTranscriptDelta(delta, provider: provider)
        case let .diagnostic(message):
            appendDiagnostic(message, provider: provider)
        }
    }

    mutating func clear() {
        entries.removeAll()
    }

    private mutating func appendStatus(_ status: ProviderStatus, provider: VoiceProviderID) {
        if case .ready = status, entries.isEmpty {
            return
        }
        entries.append(.status(provider: provider, title: statusLogTitle(status)))
    }

    private mutating func appendTranscriptDelta(_ delta: String, provider: VoiceProviderID) {
        guard delta.isEmpty == false else { return }

        if let last = entries.last,
           case let .transcript(lastProvider, text) = last,
           lastProvider == provider {
            entries[entries.count - 1] = .transcript(provider: provider, text: text + delta)
            return
        }

        entries.append(.transcript(provider: provider, text: delta))
    }

    private mutating func appendDiagnostic(_ message: String, provider: VoiceProviderID) {
        guard message.isEmpty == false else { return }
        entries.append(.diagnostic(provider: provider, text: message))
    }

    private func statusLogTitle(_ status: ProviderStatus) -> String {
        if let detail = status.detail {
            return "\(status.menuTitle) - \(detail)"
        }
        return status.menuTitle
    }
}
