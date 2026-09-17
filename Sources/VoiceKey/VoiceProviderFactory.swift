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
        case .custom:
            return OpenAIRealtimeProvider(
                configuration: configuration,
                apiKeyProvider: {
                    apiKey(
                        for: configuration,
                        store: apiKeyStore
                    )
                }
            )
        case .openClaw:
            return OpenClawTalkProvider(
                configuration: configuration,
                tokenResolutionProvider: {
                    OpenClawTokenResolver.gatewayTokenResolution(
                        apiKeyProvider: { apiKeyStore.apiKey(for: .openClaw) }
                    )
                }
            )
        case .chatGPTWeb:
            return ChatGPTWebProvider()
        case .geminiLive:
            return GeminiLiveProvider()
        case .deepgramVoiceAgent:
            return DeepgramVoiceAgentProvider()
        }
    }

    static func apiKey(
        for configuration: VoiceSessionConfiguration,
        store: APIKeyStore
    ) -> String? {
        store.apiKey(
            for: configuration.providerID,
            profileID: configuration.profileID
        )
    }
}
