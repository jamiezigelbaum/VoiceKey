import Foundation

enum VoiceProviderID: String, CaseIterable, Equatable {
    case openAIRealtime = "openai-realtime"
    case geminiLive = "gemini-live"
    case deepgramVoiceAgent = "deepgram-voice-agent"

    var displayName: String {
        switch self {
        case .openAIRealtime:
            return "OpenAI Realtime"
        case .geminiLive:
            return "Gemini Live"
        case .deepgramVoiceAgent:
            return "Deepgram Voice Agent"
        }
    }

    var isImplemented: Bool {
        self == .openAIRealtime
    }
}

struct VoiceProviderCapabilities: Equatable {
    var supportsSpeechToSpeech: Bool
    var supportsTextInput: Bool
    var supportsInterruptions: Bool
    var supportsFunctionCalling: Bool
    var supportsVisionInput: Bool
}

struct VoiceSessionConfiguration: Equatable {
    var providerID: VoiceProviderID
    var model: String
    var voice: String
    var instructions: String

    static let defaultInstructions = "You are VoiceKey, a concise and helpful voice assistant. Speak naturally and keep answers brief unless the user asks for detail."

    static var `default`: VoiceSessionConfiguration {
        VoiceSessionConfiguration(
            providerID: .openAIRealtime,
            model: "gpt-realtime-2",
            voice: "marin",
            instructions: defaultInstructions
        )
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
