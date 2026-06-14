import Foundation

struct VoiceKeyDiagnosticsSnapshot {
    var provider: VoiceProviderID
    var configuration: VoiceSessionConfiguration
    var readiness: VoiceProviderReadiness
    var hotKey: HotKeyConfiguration
    var currentStatus: ProviderStatus
    var hasAPIKey: Bool
    var supportsProviderInterface: Bool
    var supportsConnectionCheck: Bool
    var hasSessionLog: Bool

    var displayText: String {
        [
            "VoiceKey Diagnostics",
            "Provider: \(provider.displayName)",
            "Provider ID: \(provider.rawValue)",
            "Provider implemented: \(yesNo(provider.isImplemented))",
            "Readiness: \(readinessTitle)",
            "API key: \(apiKeyStatus)",
            "Model: \(configuration.model)",
            "Voice: \(configuration.voice)",
            "Hotkey: \(hotKey.displayName)",
            "Status: \(statusTitle)",
            "Provider window: \(yesNo(supportsProviderInterface))",
            "Connection check: \(yesNo(supportsConnectionCheck))",
            "Session log has entries: \(yesNo(hasSessionLog))"
        ].joined(separator: "\n")
    }

    private var readinessTitle: String {
        if let suffix = readiness.menuSuffix {
            return "\(suffix) - \(readiness.settingsMessage)"
        }
        return readiness.settingsMessage
    }

    private var apiKeyStatus: String {
        guard provider.requiresAPIKey else {
            return "not required"
        }
        return hasAPIKey ? "stored" : "missing"
    }

    private var statusTitle: String {
        if let detail = currentStatus.detail {
            return "\(currentStatus.menuTitle) - \(detail)"
        }
        return currentStatus.menuTitle
    }

    private func yesNo(_ value: Bool) -> String {
        value ? "yes" : "no"
    }
}
