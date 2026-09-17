import Foundation

struct VoiceKeyDiagnosticsSnapshot {
    var provider: VoiceProviderID
    var readiness: VoiceProviderReadiness
    var hotKeys: [String]
    var currentStatus: ProviderStatus
    var hasAPIKey: Bool
    var supportsProviderInterface: Bool
    var supportsConnectionCheck: Bool
    var hasSessionLog: Bool
    private var model: String
    private var voice: String
    private var endpoint: PublishableDiagnosticEndpoint?

    init(
        provider: VoiceProviderID,
        configuration: VoiceSessionConfiguration,
        readiness: VoiceProviderReadiness,
        hotKeys: [String],
        currentStatus: ProviderStatus,
        hasAPIKey: Bool,
        supportsProviderInterface: Bool,
        supportsConnectionCheck: Bool,
        hasSessionLog: Bool
    ) {
        self.provider = provider
        self.readiness = readiness
        self.hotKeys = hotKeys
        self.currentStatus = currentStatus
        self.hasAPIKey = hasAPIKey
        self.supportsProviderInterface = supportsProviderInterface
        self.supportsConnectionCheck = supportsConnectionCheck
        self.hasSessionLog = hasSessionLog
        model = configuration.model
        voice = configuration.voice
        endpoint = configuration.endpointURL.isEmpty
            ? nil
            : PublishableDiagnosticEndpoint(configuration.endpointURL)
    }

    var displayText: String {
        var lines = [
            "VoiceKey Diagnostics",
            "Provider: \(provider.displayName)",
            "Provider ID: \(provider.rawValue)",
            "Provider implemented: \(yesNo(provider.isImplemented))",
            "Readiness: \(readinessTitle)",
            "API key: \(apiKeyStatus)",
            "Model: \(model)",
            "Voice: \(voice)"
        ]
        if let endpoint {
            lines.append("Endpoint: \(endpoint)")
        }
        if hotKeys.isEmpty {
            lines.append("Hotkeys: none")
        } else {
            lines += hotKeys.map { "Hotkey: \($0)" }
        }
        lines += [
            "Status: \(statusTitle)",
            "Provider window: \(yesNo(supportsProviderInterface))",
            "Connection check: \(yesNo(supportsConnectionCheck))",
            "Session log has entries: \(yesNo(hasSessionLog))"
        ]
        return lines.joined(separator: "\n")
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
