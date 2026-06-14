import Foundation

class PlannedRealtimeVoiceProvider: RealtimeVoiceProvider {
    let id: VoiceProviderID
    let capabilities: VoiceProviderCapabilities
    var onEvent: ((VoiceProviderEvent) -> Void)?

    init(id: VoiceProviderID, capabilities: VoiceProviderCapabilities) {
        self.id = id
        self.capabilities = capabilities
    }

    func prepare() {
        emitUnavailable()
    }

    func update(configuration: VoiceSessionConfiguration) {
        emitUnavailable()
    }

    func toggleVoice() {
        emitUnavailable()
    }

    func stopVoice() {
        onEvent?(.status(.ready))
    }

    private func emitUnavailable() {
        onEvent?(.status(.needsAttention("\(id.displayName) support is coming soon.")))
    }
}

final class GeminiLiveProvider: PlannedRealtimeVoiceProvider {
    init() {
        super.init(
            id: .geminiLive,
            capabilities: VoiceProviderCapabilities(
                supportsSpeechToSpeech: true,
                supportsTextInput: true,
                supportsInterruptions: true,
                supportsFunctionCalling: true,
                supportsVisionInput: true,
                supportsProviderInterface: false,
                supportsConnectionCheck: false
            )
        )
    }
}

final class DeepgramVoiceAgentProvider: PlannedRealtimeVoiceProvider {
    init() {
        super.init(
            id: .deepgramVoiceAgent,
            capabilities: VoiceProviderCapabilities(
                supportsSpeechToSpeech: true,
                supportsTextInput: true,
                supportsInterruptions: true,
                supportsFunctionCalling: true,
                supportsVisionInput: false,
                supportsProviderInterface: false,
                supportsConnectionCheck: false
            )
        )
    }
}
