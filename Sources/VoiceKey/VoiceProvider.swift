import Foundation

enum VoiceProviderID: String, CaseIterable, Equatable {
    case openAIRealtime = "openai-realtime"
    case chatGPTWeb = "chatgpt-web"
    case geminiLive = "gemini-live"
    case deepgramVoiceAgent = "deepgram-voice-agent"

    var displayName: String {
        switch self {
        case .openAIRealtime:
            return "OpenAI Realtime"
        case .chatGPTWeb:
            return "ChatGPT Web (OAuth)"
        case .geminiLive:
            return "Gemini Live"
        case .deepgramVoiceAgent:
            return "Deepgram Voice Agent"
        }
    }

    var isImplemented: Bool {
        switch self {
        case .openAIRealtime, .chatGPTWeb:
            return true
        case .geminiLive, .deepgramVoiceAgent:
            return false
        }
    }

    var requiresAPIKey: Bool {
        switch self {
        case .openAIRealtime, .geminiLive, .deepgramVoiceAgent:
            return true
        case .chatGPTWeb:
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
        }
    }

    var credentialPlaceholder: String {
        requiresAPIKey ? "Stored in macOS Keychain" : "Use Show Provider to sign in"
    }

    var supportsModelSetting: Bool {
        self != .chatGPTWeb
    }

    var supportsVoiceSetting: Bool {
        self != .chatGPTWeb
    }

    var defaultModel: String {
        switch self {
        case .openAIRealtime:
            return "gpt-realtime-2"
        case .chatGPTWeb:
            return "chatgpt.com"
        case .geminiLive:
            return "gemini-live-2.5-flash-preview"
        case .deepgramVoiceAgent:
            return "deepgram-voice-agent"
        }
    }

    var defaultVoice: String {
        switch self {
        case .openAIRealtime:
            return "marin"
        case .chatGPTWeb:
            return "Configured in ChatGPT"
        case .geminiLive:
            return "Puck"
        case .deepgramVoiceAgent:
            return "aura-2-thalia-en"
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
}

struct VoiceProviderCredentialViewState: Equatable {
    var statusMessage: String
    var acceptsAPIKeyInput: Bool
    var canRemoveAPIKey: Bool

    init(provider: VoiceProviderID, hasAPIKey: Bool) {
        statusMessage = provider.readiness(hasAPIKey: hasAPIKey).settingsMessage
        acceptsAPIKeyInput = provider.requiresAPIKey && provider.isImplemented
        canRemoveAPIKey = provider.requiresAPIKey && hasAPIKey
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
    var isClearSessionLogEnabled: Bool

    init(
        provider: VoiceProviderID,
        readiness: VoiceProviderReadiness,
        supportsProviderInterface: Bool,
        hasSessionLog: Bool
    ) {
        providerTitle = "Provider: \(provider.displayName)"
        if let suffix = readiness.menuSuffix {
            providerTitle += " - \(suffix)"
        }

        switch readiness {
        case .ready:
            toggleTitle = "Start/End VoiceKey Voice"
            isToggleEnabled = true
            setupTitle = "Provider Settings..."
            setupAction = .openSettings
            isSetupEnabled = true
        case .providerSignIn:
            toggleTitle = "Start/End VoiceKey Voice"
            isToggleEnabled = true
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

        isClearSessionLogEnabled = hasSessionLog
    }
}

struct VoiceSessionConfiguration: Equatable {
    var providerID: VoiceProviderID
    var model: String
    var voice: String
    var instructions: String

    static let defaultInstructions = "You are VoiceKey, a concise and helpful voice assistant. Speak naturally and keep answers brief unless the user asks for detail."

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

extension RealtimeVoiceProvider {
    func showProviderInterface() {}
    func reloadProviderInterface() {}
}

enum VoiceProviderSettingsStore {
    private static let providerKey = "VoiceProvider.providerID"
    private static let modelKey = "VoiceProvider.model"
    private static let voiceKey = "VoiceProvider.voice"
    private static let instructionsKey = "VoiceProvider.instructions"

    static func load(defaults: UserDefaults = .standard) -> VoiceSessionConfiguration {
        var configuration = VoiceSessionConfiguration.default

        if let rawProvider = defaults.string(forKey: providerKey),
           let provider = VoiceProviderID(rawValue: rawProvider) {
            configuration.providerID = provider
        }
        if let model = defaults.string(forKey: modelKey), model.isEmpty == false {
            configuration.model = model
        }
        if let voice = defaults.string(forKey: voiceKey), voice.isEmpty == false {
            configuration.voice = voice
        }
        if let instructions = defaults.string(forKey: instructionsKey), instructions.isEmpty == false {
            configuration.instructions = instructions
        }

        return configuration
    }

    static func save(_ configuration: VoiceSessionConfiguration, defaults: UserDefaults = .standard) {
        defaults.set(configuration.providerID.rawValue, forKey: providerKey)
        defaults.set(configuration.model, forKey: modelKey)
        defaults.set(configuration.voice, forKey: voiceKey)
        defaults.set(configuration.instructions, forKey: instructionsKey)
    }
}
