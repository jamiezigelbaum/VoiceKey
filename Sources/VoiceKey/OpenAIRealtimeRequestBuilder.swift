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

    /// Whether this session will actually be handed the `search_web` tool.
    /// The tool declaration and the preamble's nudge both read this, so they
    /// can never drift into telling a model about a tool it does not have.
    static func declaresWebSearchTool(
        _ configuration: VoiceSessionConfiguration
    ) -> Bool {
        configuration.providerID == .openAIRealtime
            && configuration.webSearchEnabled
    }

    static let webSearchNudge =
        "A search_web tool is available; use it whenever the answer depends on current information."

    /// The whole of VoiceKey's own instruction text — capability facts the
    /// model cannot otherwise know, and nothing else. It is composed here on
    /// the wire rather than stored in a profile, so it is never visible or
    /// editable in Settings and rewording it never needs a data migration.
    /// VoiceKey is a tool, not a personality: resist adding to this.
    static func operationalPreamble(
        for configuration: VoiceSessionConfiguration
    ) -> String {
        guard declaresWebSearchTool(configuration) else { return "" }
        return webSearchNudge
    }

    // The realtime model has no clock; stamping the session start into the
    // instructions lets it answer "what time is it" without any tools.
    static func instructionsWithSessionContext(
        _ instructions: String,
        sessionStart: Date,
        preamble: String = ""
    ) -> String {
        let formatter = DateFormatter()
        // Pin locale/calendar so non-Gregorian regions do not report a
        // mis-stated year (e.g. Buddhist 2569) to the model.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        let stamp = "Session started \(formatter.string(from: sessionStart)) (\(TimeZone.current.identifier))."
        // App-owned text first, the user's own instructions after it so they
        // win, and the stamp last — a live session update is compared against
        // the original by its trailing component.
        return [preamble, instructions, stamp]
            .filter { $0.isEmpty == false }
            .joined(separator: "\n\n")
    }

    static func sessionUpdateEvent(
        configuration: VoiceSessionConfiguration,
        speakerMode: Bool = false,
        includeModel: Bool = true,
        sessionStart: Date = Date(),
        authorizationProvider: (UUID) -> String? = {
            APIKeyStore.shared.authorizationToken(forMCPServer: $0)
        }
    ) -> [String: Any] {
        let turnDetection: [String: Any]
        let noiseReduction: [String: Any]
        if speakerMode {
            // Live verification on 2026-07-23 established that server_vad can
            // create responses without interrupting them. Client-side energy
            // gating therefore remains the sole interruption owner.
            turnDetection = [
                "type": "server_vad",
                "threshold": OpenAIRealtimeSpeakerModeTuning.serverVADThreshold,
                "prefix_padding_ms": OpenAIRealtimeSpeakerModeTuning.serverVADPrefixPaddingMilliseconds,
                "silence_duration_ms": OpenAIRealtimeSpeakerModeTuning.serverVADSilenceDurationMilliseconds,
                "create_response": true,
                "interrupt_response": false
            ]
            noiseReduction = ["type": "far_field"]
        } else {
            turnDetection = [
                "type": "semantic_vad",
                "eagerness": "auto",
                "create_response": true,
                "interrupt_response": true
            ]
            noiseReduction = ["type": "near_field"]
        }

        var session: [String: Any] = [
            "type": "realtime",
            "output_modalities": ["audio"],
            "audio": [
                "input": [
                    "format": pcm24kFormat,
                    "noise_reduction": noiseReduction,
                    "turn_detection": turnDetection,
                ],
                "output": [
                    "format": pcm24kFormat,
                    "voice": configuration.voice
                ]
            ],
            "instructions": instructionsWithSessionContext(
                configuration.instructions,
                sessionStart: sessionStart,
                preamble: operationalPreamble(for: configuration)
            )
        ]
        if includeModel {
            session["model"] = configuration.model
        }
        var tools: [[String: Any]] = []
        if declaresWebSearchTool(configuration) {
            tools.append(Self.webSearchFunctionTool)
        }
        tools += configuration.mcpServers.map { server in
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
        if tools.isEmpty == false {
            session["tools"] = tools
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

    static func conversationItemTruncateEvent(
        itemID: String,
        audioEndMilliseconds: Int
    ) -> [String: Any] {
        [
            "type": "conversation.item.truncate",
            "item_id": itemID,
            "content_index": 0,
            "audio_end_ms": max(0, audioEndMilliseconds)
        ]
    }

    static func functionCallOutputEvent(
        callID: String,
        output: String
    ) -> [String: Any] {
        [
            "type": "conversation.item.create",
            "item": [
                "type": "function_call_output",
                "call_id": callID,
                "output": output
            ]
        ]
    }

    private static var pcm24kFormat: [String: Any] {
        [
            "type": "audio/pcm",
            "rate": 24_000
        ]
    }

    private static var webSearchFunctionTool: [String: Any] {
        [
            "type": "function",
            "name": "search_web",
            "description":
                "Search the current web when up-to-date or externally sourced information is needed.",
            "parameters": [
                "type": "object",
                "properties": [
                    "query": [
                        "type": "string",
                        "description": "The web search query."
                    ]
                ],
                "required": ["query"],
                "additionalProperties": false
            ]
        ]
    }
}
