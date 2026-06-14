import Foundation

enum OpenAIRealtimeRequestBuilder {
    static func webSocketRequest(apiKey: String, configuration: VoiceSessionConfiguration) -> URLRequest? {
        var components = URLComponents(string: "wss://api.openai.com/v1/realtime")
        components?.queryItems = [
            URLQueryItem(name: "model", value: configuration.model)
        ]
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        return request
    }

    static func sessionUpdateEvent(configuration: VoiceSessionConfiguration) -> [String: Any] {
        [
            "type": "session.update",
            "session": [
                "type": "realtime",
                "model": configuration.model,
                "output_modalities": ["audio"],
                "audio": [
                    "input": [
                        "format": pcm24kFormat,
                        "turn_detection": [
                            "type": "semantic_vad",
                            "eagerness": "auto",
                            "create_response": true,
                            "interrupt_response": true
                        ]
                    ],
                    "output": [
                        "format": pcm24kFormat,
                        "voice": configuration.voice
                    ]
                ],
                "instructions": configuration.instructions
            ]
        ]
    }

    static func inputAudioAppendEvent(audio: Data) -> [String: Any] {
        [
            "type": "input_audio_buffer.append",
            "audio": audio.base64EncodedString()
        ]
    }

    static var responseCancelEvent: [String: Any] {
        ["type": "response.cancel"]
    }

    static var inputAudioBufferClearEvent: [String: Any] {
        ["type": "input_audio_buffer.clear"]
    }

    private static var pcm24kFormat: [String: Any] {
        [
            "type": "audio/pcm",
            "rate": 24_000
        ]
    }
}
