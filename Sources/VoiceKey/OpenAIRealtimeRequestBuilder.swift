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

    // The realtime model has no clock; stamping the session start into the
    // instructions lets it answer "what time is it" without any tools.
    static func instructionsWithSessionContext(
        _ instructions: String,
        sessionStart: Date
    ) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        let stamp = "Session started \(formatter.string(from: sessionStart)) (\(TimeZone.current.identifier))."
        guard instructions.isEmpty == false else { return stamp }
        return "\(instructions)\n\n\(stamp)"
    }

    static func sessionUpdateEvent(
        configuration: VoiceSessionConfiguration,
        includeModel: Bool = true,
        sessionStart: Date = Date(),
        authorizationProvider: (UUID) -> String? = {
            APIKeyStore.shared.authorizationToken(forMCPServer: $0)
        }
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
            "instructions": instructionsWithSessionContext(
                configuration.instructions,
                sessionStart: sessionStart
            )
        ]
        if includeModel {
            session["model"] = configuration.model
        }
        if configuration.mcpServers.isEmpty == false {
            session["tools"] = configuration.mcpServers.map { server in
                var tool: [String: Any] = [
                    "type": "mcp",
                    "server_label": server.label,
                    "server_url": server.urlString,
                    "require_approval": "never"
                ]
                if let allowedTools = server.allowedTools, allowedTools.isEmpty == false {
                    tool["allowed_tools"] = allowedTools
                }
                if let authorization = authorizationProvider(server.id),
                   authorization.isEmpty == false {
                    tool["authorization"] = authorization
                }
                return tool
            }
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
