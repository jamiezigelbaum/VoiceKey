import Foundation

enum OpenAIRealtimeConnectionDiagnostics {
    static func closeStatus(code: URLSessionWebSocketTask.CloseCode, reason: Data?) -> ProviderStatus {
        switch code {
        case .normalClosure, .goingAway:
            return .ready
        default:
            return .needsAttention(closeMessage(code: code, reason: reason))
        }
    }

    static func closeMessage(code: URLSessionWebSocketTask.CloseCode, reason: Data?) -> String {
        let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = reasonText.flatMap { $0.isEmpty ? nil : ": \($0)" } ?? "."
        return "OpenAI Realtime WebSocket closed with code \(code.rawValue)\(suffix)"
    }
}
