import Foundation

enum OpenAIRealtimeRequestBuilder {
    static let defaultBaseURL = "wss://api.openai.com/v1/realtime"

    static func normalizedBaseURL(for endpointURL: String) -> String {
        let trimmed = endpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return defaultBaseURL }

        var normalized = trimmed
        if normalized.contains("://") == false {
            normalized = "wss://\(normalized)"
        }
        let lowercased = normalized.lowercased()
        if lowercased.hasPrefix("https://") {
            normalized = "wss://" + normalized.dropFirst("https://".count)
        } else if lowercased.hasPrefix("http://") {
            normalized = "ws://" + normalized.dropFirst("http://".count)
        }

        if var components = URLComponents(string: normalized),
           components.path.isEmpty || components.path == "/" {
            components.path = "/v1/realtime"
            normalized = components.string ?? normalized
        }

        return normalized
    }

    static func webSocketRequest(
        baseURL: String = defaultBaseURL,
        apiKey: String,
        configuration: VoiceSessionConfiguration
    ) -> URLRequest? {
        var components = URLComponents(string: baseURL)
        let existingQueryItems = (components?.queryItems ?? []).filter { $0.name != "model" }
        components?.queryItems = existingQueryItems + [
            URLQueryItem(name: "model", value: configuration.model)
        ]
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        if apiKey.isEmpty == false {
            request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 30
        return request
    }

    static func sessionUpdateEvent(
        configuration: VoiceSessionConfiguration,
        includeModel: Bool = true
    ) -> [String: Any] {
        var session: [String: Any] = [
            "type": "realtime",
            "output_modalities": ["audio"],
            "audio": [
                "input": [
                    "format": pcm24kFormat,
                    "turn_detection": [
                        "type": "semantic_vad",
                        "eagerness": "auto",
                        "create_response": true,
                        "interrupt_response": true
                    ],
                ],
                "output": [
                    "format": pcm24kFormat,
                    "voice": configuration.voice
                ]
            ],
            "instructions": configuration.instructions
        ]
        if includeModel {
            session["model"] = configuration.model
        }

        return [
            "type": "session.update",
            "session": session
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
