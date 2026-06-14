import Foundation

enum VoiceProviderFactory {
    static func makeProvider(
        for configuration: VoiceSessionConfiguration,
        apiKeyStore: APIKeyStore = .shared
    ) -> RealtimeVoiceProvider {
        switch configuration.providerID {
        case .openAIRealtime:
            return OpenAIRealtimeProvider(
                configuration: configuration,
                apiKeyProvider: { apiKeyStore.apiKey(for: .openAIRealtime) }
            )
        case .chatGPTWeb:
            return ChatGPTWebProvider()
        case .geminiLive:
            return GeminiLiveProvider()
        case .deepgramVoiceAgent:
            return DeepgramVoiceAgentProvider()
        }
    }
}
