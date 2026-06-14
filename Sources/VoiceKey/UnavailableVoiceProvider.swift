import Foundation

final class UnavailableVoiceProvider: RealtimeVoiceProvider {
    let id: VoiceProviderID
    let capabilities = VoiceProviderCapabilities(
        supportsSpeechToSpeech: false,
        supportsTextInput: false,
        supportsInterruptions: false,
        supportsFunctionCalling: false,
        supportsVisionInput: false,
        supportsProviderInterface: false
    )

    var onEvent: ((VoiceProviderEvent) -> Void)?

    init(id: VoiceProviderID) {
        self.id = id
    }

    func prepare() {
        onEvent?(.status(.needsAttention("\(id.displayName) is selectable, but its adapter is not implemented yet.")))
    }

    func update(configuration: VoiceSessionConfiguration) {
        prepare()
    }

    func toggleVoice() {
        prepare()
    }

    func stopVoice() {
        onEvent?(.status(.ready))
    }
}
