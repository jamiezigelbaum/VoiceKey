import Foundation

final class ChatGPTWebProvider: RealtimeVoiceProvider {
    let id: VoiceProviderID = .chatGPTWeb
    let capabilities = VoiceProviderCapabilities(
        supportsSpeechToSpeech: true,
        supportsTextInput: false,
        supportsInterruptions: true,
        supportsFunctionCalling: false,
        supportsVisionInput: false,
        supportsProviderInterface: true,
        supportsConnectionCheck: false
    )

    var onEvent: ((VoiceProviderEvent) -> Void)?

    private let chatGPT = ChatGPTProvider()

    init() {
        chatGPT.onStatusChange = { [weak self] status in
            self?.onEvent?(.status(status))
        }
        chatGPT.onDebugChange = { [weak self] message in
            self?.onEvent?(.diagnostic(message))
        }
    }

    func prepare() {
        chatGPT.prepare()
    }

    func update(configuration: VoiceSessionConfiguration) {
        prepare()
    }

    func toggleVoice() {
        chatGPT.toggleVoice()
    }

    func stopVoice() {
        chatGPT.endVoice()
    }

    func showProviderInterface() {
        chatGPT.show()
    }

    func reloadProviderInterface() {
        chatGPT.reload()
    }
}
