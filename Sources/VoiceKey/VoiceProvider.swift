import Foundation

enum VoiceProviderID: String, CaseIterable, Codable, Equatable {
    case openAIRealtime = "openai-realtime"
    case chatGPTWeb = "chatgpt-web"
    case geminiLive = "gemini-live"
    case deepgramVoiceAgent = "deepgram-voice-agent"
    case custom = "custom"
    case openClaw = "openClaw"

    var displayName: String {
        switch self {
        case .openAIRealtime:
            return "OpenAI Realtime API"
        case .chatGPTWeb:
            return "ChatGPT (web)"
        case .geminiLive:
            return "Gemini Live"
        case .deepgramVoiceAgent:
            return "Deepgram Voice Agent"
        case .custom:
            return "Custom Realtime Endpoint"
        case .openClaw:
            return "OpenClaw Talk"
        }
    }

    var settingsDescription: String {
        switch self {
        case .openAIRealtime:
            return "OpenAI Realtime API — your OpenAI API key; pick model & voice; web search via MCP"
        case .chatGPTWeb:
            return "ChatGPT (web) — your ChatGPT subscription in a window; GPT-Live voice when available; OpenAI controls model & voice"
        case .geminiLive:
            return "Gemini Live — Google’s live voice service; requires a Gemini API key"
        case .deepgramVoiceAgent:
            return "Deepgram Voice Agent — Deepgram’s hosted voice agent; requires a Deepgram API key"
        case .custom:
            return "Custom Realtime Endpoint — connect to a compatible realtime endpoint you manage"
        case .openClaw:
            return "OpenClaw Talk — a gateway-managed voice runtime using the dedicated VoiceKey consult session"
        }
    }

    /// Stable text written to on-disk session logs. User-facing provider names
    /// may change, but release hardening treats these file terms as wire data.
    var logWireName: String {
        switch self {
        case .chatGPTWeb:
            return "ChatGPT Web (OAuth)"
        case .openAIRealtime, .geminiLive, .deepgramVoiceAgent, .custom, .openClaw:
            return displayName
        }
    }

    var isImplemented: Bool {
        switch self {
        case .openAIRealtime, .chatGPTWeb, .custom, .openClaw:
            return true
        case .geminiLive, .deepgramVoiceAgent:
            return false
        }
    }

    var requiresAPIKey: Bool {
        switch self {
        case .openAIRealtime, .geminiLive, .deepgramVoiceAgent:
            return true
        case .chatGPTWeb, .custom, .openClaw:
            return false
        }
    }

    var credentialLabel: String {
        switch self {
        case .openAIRealtime:
            return "OpenAI API key"
        case .chatGPTWeb:
            return "ChatGPT sign-in"
        case .geminiLive:
            return "Gemini API key"
        case .deepgramVoiceAgent:
            return "Deepgram API key"
        case .custom:
            return "API Key (optional)"
        case .openClaw:
            return "Gateway Token (optional)"
        }
    }

    var credentialPlaceholder: String {
        switch self {
        case .chatGPTWeb:
            return "Use Show Provider to sign in"
        case .openAIRealtime, .geminiLive, .deepgramVoiceAgent, .custom, .openClaw:
            return "Paste key here"
        }
    }

    var supportsModelSetting: Bool {
        self != .chatGPTWeb && self != .openClaw
    }

    var supportsVoiceSetting: Bool {
        self != .chatGPTWeb && self != .openClaw
    }

    var supportsEndpointSetting: Bool {
        switch self {
        case .openAIRealtime, .custom, .openClaw:
            return true
        case .chatGPTWeb, .geminiLive, .deepgramVoiceAgent:
            return false
        }
    }

    var endpointPlaceholder: String {
        switch self {
        case .openClaw:
            return "ws://127.0.0.1:18790 (auto)"
        case .openAIRealtime, .chatGPTWeb, .geminiLive, .deepgramVoiceAgent, .custom:
            return "wss://localhost:8080"
        }
    }

    var usesRealtimeWebSocket: Bool {
        switch self {
        case .openAIRealtime, .custom:
            return true
        case .chatGPTWeb, .geminiLive, .deepgramVoiceAgent, .openClaw:
            return false
        }
    }

    var defaultModel: String {
        switch self {
        case .openAIRealtime, .custom:
            return "gpt-realtime-2"
        case .chatGPTWeb:
            return "chatgpt.com"
        case .geminiLive:
            return "gemini-live-2.5-flash-preview"
        case .deepgramVoiceAgent:
            return "deepgram-voice-agent"
        case .openClaw:
            // The gateway owns model configuration.
            return ""
        }
    }

    var defaultVoice: String {
        switch self {
        case .openAIRealtime, .custom:
            return "marin"
        case .chatGPTWeb:
            return "Configured in ChatGPT"
        case .geminiLive:
            return "Puck"
        case .deepgramVoiceAgent:
            return "aura-2-thalia-en"
        case .openClaw:
            // The gateway owns voice configuration.
            return ""
        }
    }

    var voiceOptions: [String] {
        switch self {
        case .openAIRealtime:
            return ["marin", "cedar", "alloy", "ash", "ballad", "coral", "echo", "sage", "shimmer", "verse"]
        case .chatGPTWeb:
            return [defaultVoice]
        case .geminiLive:
            return ["Puck"]
        case .deepgramVoiceAgent:
            return ["aura-2-thalia-en"]
        case .custom, .openClaw:
            return []
        }
    }

    var defaultConfiguration: VoiceSessionConfiguration {
        VoiceSessionConfiguration(
            providerID: self,
            model: defaultModel,
            voice: defaultVoice,
            instructions: VoiceSessionConfiguration.defaultInstructions
        )
    }

    func readiness(hasAPIKey: Bool) -> VoiceProviderReadiness {
        guard isImplemented else {
            return .unavailable("\(displayName) is coming soon.")
        }
        // Custom endpoints and OpenClaw resolve credentials at connect time (optional
        // key, plus gateway token file discovery for OpenClaw), so they always pass.
        guard self != .custom, self != .openClaw else {
            return .ready
        }
        guard requiresAPIKey else {
            return .providerSignIn("Uses provider sign-in.")
        }
        return hasAPIKey ? .ready : .needsAPIKey("\(credentialLabel) required.")
    }
}

enum VoiceProviderReadiness: Equatable {
    case ready
    case providerSignIn(String)
    case needsAPIKey(String)
    case unavailable(String)

    var menuSuffix: String? {
        switch self {
        case .ready:
            return nil
        case .providerSignIn:
            return "Sign-in"
        case .needsAPIKey:
            return "Needs key"
        case .unavailable:
            return "Coming soon"
        }
    }

    var settingsMessage: String {
        switch self {
        case .ready:
            return "Ready to use."
        case let .providerSignIn(message),
             let .needsAPIKey(message),
             let .unavailable(message):
            return message
        }
    }

    var allowsVoiceToggle: Bool {
        switch self {
        case .ready, .providerSignIn:
            return true
        case .needsAPIKey, .unavailable:
            return false
        }
    }
}

struct VoiceProviderCapabilities: Equatable {
    var supportsSpeechToSpeech: Bool
    var supportsTextInput: Bool
    var supportsInterruptions: Bool
    var supportsFunctionCalling: Bool
    var supportsVisionInput: Bool
    var supportsProviderInterface: Bool
    var supportsConnectionCheck: Bool
}

struct VoiceProviderCredentialViewState: Equatable {
    var statusMessage: String
    var acceptsAPIKeyInput: Bool
    var canRemoveAPIKey: Bool

    init(
        provider: VoiceProviderID,
        hasAPIKey: Bool,
        hasDiscoveredGatewayToken: Bool = OpenClawTokenResolver.gatewayTokenFromSecretsDirectory(
            OpenClawTokenResolver.defaultSecretsDirectory
        ) != nil
    ) {
        // The credential caption reflects credential PRESENCE, not channel
        // readiness: OpenClaw's readiness always passes (token optional,
        // resolved at connect time), which made a machine with no token and
        // no OpenClaw pairing claim "Ready to use." (fresh-Air install,
        // 2026-07-24).
        if provider == .openClaw {
            if hasAPIKey {
                statusMessage = "Gateway token stored."
            } else if hasDiscoveredGatewayToken {
                statusMessage = "Using this Mac's OpenClaw pairing (auto-discovered token)."
            } else {
                statusMessage = "No gateway token found — paste one, or pair this Mac with OpenClaw."
            }
        } else {
            statusMessage = provider.readiness(hasAPIKey: hasAPIKey).settingsMessage
        }
        // ChatGPT Web signs in through the provider's web UI. All other providers can
        // edit a stored key; for custom endpoints the key is optional.
        acceptsAPIKeyInput = provider.isImplemented && provider != .chatGPTWeb
        canRemoveAPIKey = provider != .chatGPTWeb && hasAPIKey
    }
}

enum VoiceProviderSetupAction: Equatable {
    case none
    case openSettings
    case showProviderInterface
}

struct VoiceProviderMenuState: Equatable {
    var providerTitle: String
    var toggleTitle: String
    var isToggleEnabled: Bool
    var setupTitle: String
    var setupAction: VoiceProviderSetupAction
    var isSetupEnabled: Bool
    var showProviderTitle: String
    var reloadProviderTitle: String
    var isProviderInterfaceEnabled: Bool
    var checkConnectionTitle: String
    var isCheckConnectionEnabled: Bool
    var isCopySessionLogEnabled: Bool
    var isClearSessionLogEnabled: Bool

    init(
        provider: VoiceProviderID,
        readiness: VoiceProviderReadiness,
        currentStatus: ProviderStatus = .ready,
        supportsProviderInterface: Bool,
        supportsConnectionCheck: Bool,
        hasSessionLog: Bool
    ) {
        providerTitle = "Provider: \(provider.displayName)"
        if let suffix = readiness.menuSuffix {
            providerTitle += " - \(suffix)"
        }

        switch readiness {
        case .ready:
            toggleTitle = currentStatus.voiceToggleTitle
            isToggleEnabled = currentStatus.allowsVoiceToggleWhileReady
            setupTitle = "Provider Settings..."
            setupAction = .openSettings
            isSetupEnabled = true
        case .providerSignIn:
            toggleTitle = currentStatus.voiceToggleTitle
            isToggleEnabled = currentStatus.allowsVoiceToggleWhileReady
            setupTitle = "Sign In with Provider..."
            setupAction = supportsProviderInterface ? .showProviderInterface : .openSettings
            isSetupEnabled = true
        case .needsAPIKey:
            toggleTitle = "Add API Key in Settings"
            isToggleEnabled = false
            setupTitle = "Add API Key..."
            setupAction = .openSettings
            isSetupEnabled = true
        case .unavailable:
            toggleTitle = "\(provider.displayName) Coming Soon"
            isToggleEnabled = false
            setupTitle = "\(provider.displayName) Coming Soon"
            setupAction = .none
            isSetupEnabled = false
        }

        isProviderInterfaceEnabled = supportsProviderInterface
        if supportsProviderInterface {
            showProviderTitle = "Show Provider"
            reloadProviderTitle = "Reload Provider"
        } else if provider.isImplemented {
            showProviderTitle = "Show Provider (API provider)"
            reloadProviderTitle = "Reload Provider (API provider)"
        } else {
            showProviderTitle = "Show Provider (coming soon)"
            reloadProviderTitle = "Reload Provider (coming soon)"
        }

        checkConnectionTitle = provider.requiresAPIKey ? "Check API Connection" : "Check Provider Connection"
        isCheckConnectionEnabled = readiness == .ready && supportsConnectionCheck
        isCopySessionLogEnabled = hasSessionLog
        isClearSessionLogEnabled = hasSessionLog
    }
}

struct VoiceSessionConfiguration: Equatable {
    var profileID: UUID? = nil
    var providerID: VoiceProviderID
    var model: String
    var voice: String
    var instructions: String
    var endpointURL: String = ""
    var mcpServers: [MCPServerConfiguration] = []
    var webSearchEnabled: Bool = false
    var speakerModePreference: OpenAISpeakerModePreference = .automatic

    // Empty by design (owner ruling 2026-07-24): VoiceKey is the app, not
    // the assistant — never bake an identity into sessions. Users add
    // instructions per channel if they want them.
    static let defaultInstructions = ""

    static var `default`: VoiceSessionConfiguration {
        VoiceProviderID.openAIRealtime.defaultConfiguration
    }
}

enum VoiceProviderEvent: Equatable {
    case status(ProviderStatus)
    case transcript(String)
    case diagnostic(String)
}

protocol RealtimeVoiceProvider: AnyObject {
    var id: VoiceProviderID { get }
    var capabilities: VoiceProviderCapabilities { get }
    var onEvent: ((VoiceProviderEvent) -> Void)? { get set }

    func prepare()
    func update(configuration: VoiceSessionConfiguration)
    func toggleVoice()
    func stopVoice()
    func showProviderInterface()
    func reloadProviderInterface()
}

protocol VoiceProviderConnectionChecking: AnyObject {
    func checkConnection()
}

extension RealtimeVoiceProvider {
    func showProviderInterface() {}
    func reloadProviderInterface() {}
}
