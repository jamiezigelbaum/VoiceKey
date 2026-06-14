import Foundation

enum OpenAIRealtimeEventAction: Equatable {
    case providerEvent(VoiceProviderEvent)
    case sessionUpdated
    case stopPlayback
    case audio(Data)
}

enum OpenAIRealtimeEventMapper {
    static func actions(from text: String) -> [OpenAIRealtimeEventAction] {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            return []
        }

        switch type {
        case "session.created":
            return [.providerEvent(.diagnostic(type))]
        case "session.updated":
            return [
                .providerEvent(.diagnostic(type)),
                .sessionUpdated
            ]
        case "input_audio_buffer.speech_started":
            return [
                .stopPlayback,
                .providerEvent(.status(.listening))
            ]
        case "input_audio_buffer.speech_stopped", "input_audio_buffer.committed", "response.created":
            return [.providerEvent(.status(.thinking))]
        case "response.output_audio.delta", "response.audio.delta":
            guard let delta = object["delta"] as? String,
                  let audio = Data(base64Encoded: delta) else {
                return []
            }
            return [
                .audio(audio),
                .providerEvent(.status(.speaking))
            ]
        case "response.output_audio_transcript.delta", "response.audio_transcript.delta", "response.output_text.delta":
            guard let delta = object["delta"] as? String else { return [] }
            return [.providerEvent(.transcript(delta))]
        case "response.output_audio.done", "response.audio.done", "response.done":
            return [.providerEvent(.status(.listening))]
        case "error":
            let message = ((object["error"] as? [String: Any])?["message"] as? String)
                ?? "OpenAI Realtime returned an error."
            return [.providerEvent(.status(.needsAttention(message)))]
        default:
            return [.providerEvent(.diagnostic(type))]
        }
    }
}
