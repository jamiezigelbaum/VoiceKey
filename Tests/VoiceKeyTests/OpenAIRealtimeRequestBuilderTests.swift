@testable import VoiceKey
import XCTest

final class OpenAIRealtimeRequestBuilderTests: XCTestCase {
    func testWebSocketRequestTargetsRealtimeModelWithBearerAuth() throws {
        let request = try XCTUnwrap(OpenAIRealtimeRequestBuilder.webSocketRequest(
            apiKey: "test-api-key",
            configuration: testConfiguration
        ))

        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.scheme, "wss")
        XCTAssertEqual(url.host, "api.openai.com")
        XCTAssertEqual(url.path, "/v1/realtime")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems, [
            URLQueryItem(name: "model", value: "gpt-realtime-2-test")
        ])
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-api-key")
        XCTAssertEqual(request.timeoutInterval, 30)
    }

    func testSessionUpdateEventMatchesRealtimeVoiceAgentContract() throws {
        let event = OpenAIRealtimeRequestBuilder.sessionUpdateEvent(configuration: testConfiguration)

        XCTAssertEqual(event["type"] as? String, "session.update")

        let session = try dictionary(event["session"])
        XCTAssertEqual(session["type"] as? String, "realtime")
        XCTAssertEqual(session["model"] as? String, "gpt-realtime-2-test")
        let instructions = try XCTUnwrap(session["instructions"] as? String)
        XCTAssertTrue(instructions.hasPrefix("Keep it concise."))
        XCTAssertTrue(instructions.contains("Session started"))
        XCTAssertEqual(session["output_modalities"] as? [String], ["audio"])
        let tools = try XCTUnwrap(
            session["tools"] as? [[String: Any]]
        )
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(
            tools.first?["server_label"] as? String,
            "exa"
        )

        let audio = try dictionary(session["audio"])
        let input = try dictionary(audio["input"])
        let inputFormat = try dictionary(input["format"])
        XCTAssertEqual(inputFormat["type"] as? String, "audio/pcm")
        XCTAssertEqual(inputFormat["rate"] as? Int, 24_000)
        XCTAssertEqual(
            try dictionary(input["noise_reduction"])["type"] as? String,
            "near_field"
        )

        let turnDetection = try dictionary(input["turn_detection"])
        XCTAssertEqual(turnDetection["type"] as? String, "semantic_vad")
        XCTAssertEqual(turnDetection["eagerness"] as? String, "auto")
        XCTAssertEqual(turnDetection["create_response"] as? Bool, true)
        XCTAssertEqual(turnDetection["interrupt_response"] as? Bool, true)

        let output = try dictionary(audio["output"])
        let outputFormat = try dictionary(output["format"])
        XCTAssertEqual(outputFormat["type"] as? String, "audio/pcm")
        XCTAssertEqual(outputFormat["rate"] as? Int, 24_000)
        XCTAssertEqual(output["voice"] as? String, "marin-test")
    }

    func testSpeakerModeSessionUpdateUsesExactEchoSafeContract() throws {
        let event = OpenAIRealtimeRequestBuilder.sessionUpdateEvent(
            configuration: testConfiguration,
            speakerMode: true
        )

        let session = try dictionary(event["session"])
        let audio = try dictionary(session["audio"])
        let input = try dictionary(audio["input"])
        XCTAssertEqual(
            try dictionary(input["noise_reduction"])["type"] as? String,
            "far_field"
        )

        let turnDetection = try dictionary(input["turn_detection"])
        XCTAssertEqual(turnDetection["type"] as? String, "server_vad")
        XCTAssertEqual(turnDetection["threshold"] as? Double, 0.75)
        XCTAssertEqual(turnDetection["prefix_padding_ms"] as? Int, 300)
        XCTAssertEqual(turnDetection["silence_duration_ms"] as? Int, 700)
        XCTAssertEqual(turnDetection["create_response"] as? Bool, true)
        XCTAssertEqual(turnDetection["interrupt_response"] as? Bool, false)
        XCTAssertNil(turnDetection["eagerness"])
    }

    func testLiveSessionUpdateOmitsModel() throws {
        let event = OpenAIRealtimeRequestBuilder.sessionUpdateEvent(
            configuration: testConfiguration,
            includeModel: false
        )

        let session = try dictionary(event["session"])
        XCTAssertNil(session["model"])
        let instructions = try XCTUnwrap(session["instructions"] as? String)
        XCTAssertTrue(instructions.hasPrefix("Keep it concise."))
        XCTAssertTrue(instructions.contains("Session started"))
    }

    func testSessionUpdateDeclaresMCPServersWithOptionalFields() throws {
        let authorizedID = UUID()
        let publicID = UUID()
        var configuration = testConfiguration
        configuration.mcpServers = [
            MCPServerConfiguration(
                id: authorizedID,
                label: "calendar",
                urlString: "https://mcp.example.com/calendar",
                allowedTools: ["search_events", "create_event"]
            ),
            MCPServerConfiguration(
                id: publicID,
                label: "search",
                urlString: "https://mcp.example.com/search"
            )
        ]

        let event = OpenAIRealtimeRequestBuilder.sessionUpdateEvent(
            configuration: configuration,
            authorizationProvider: { id in
                id == authorizedID ? "secret-token" : nil
            }
        )

        let session = try dictionary(event["session"])
        let tools = try XCTUnwrap(session["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 3)
        XCTAssertEqual(
            tools[0]["server_label"] as? String,
            "exa"
        )
        XCTAssertEqual(tools[1]["type"] as? String, "mcp")
        XCTAssertEqual(tools[1]["server_label"] as? String, "calendar")
        XCTAssertEqual(
            tools[1]["server_url"] as? String,
            "https://mcp.example.com/calendar"
        )
        XCTAssertEqual(tools[1]["require_approval"] as? String, "never")
        XCTAssertEqual(
            tools[1]["allowed_tools"] as? [String],
            ["search_events", "create_event"]
        )
        XCTAssertEqual(tools[1]["authorization"] as? String, "secret-token")

        XCTAssertEqual(tools[2]["type"] as? String, "mcp")
        XCTAssertEqual(tools[2]["server_label"] as? String, "search")
        XCTAssertEqual(
            tools[2]["server_url"] as? String,
            "https://mcp.example.com/search"
        )
        XCTAssertEqual(tools[2]["require_approval"] as? String, "never")
        XCTAssertNil(tools[2]["allowed_tools"])
        XCTAssertNil(tools[2]["authorization"])
    }

    func testSessionUpdateOmitsEmptyAuthorization() throws {
        var configuration = testConfiguration
        configuration.mcpServers = [
            MCPServerConfiguration(
                label: "public",
                urlString: "https://mcp.example.com"
            )
        ]

        let event = OpenAIRealtimeRequestBuilder.sessionUpdateEvent(
            configuration: configuration,
            authorizationProvider: { _ in "" }
        )

        let session = try dictionary(event["session"])
        let tools = try XCTUnwrap(session["tools"] as? [[String: Any]])
        let publicTool = try XCTUnwrap(
            tools.first(where: {
                ($0["server_label"] as? String) == "public"
            })
        )
        XCTAssertNil(publicTool["authorization"])
    }

    func testInputAudioAppendEventBase64EncodesPCMBytes() {
        let event = OpenAIRealtimeRequestBuilder.inputAudioAppendEvent(audio: Data([0x01, 0x02, 0x03]))

        XCTAssertEqual(event["type"] as? String, "input_audio_buffer.append")
        XCTAssertEqual(event["audio"] as? String, "AQID")
    }

    func testStopEventsUseRealtimeClientEventTypes() {
        XCTAssertEqual(OpenAIRealtimeRequestBuilder.responseCancelEvent["type"] as? String, "response.cancel")
        XCTAssertEqual(
            OpenAIRealtimeRequestBuilder.inputAudioBufferClearEvent["type"] as? String,
            "input_audio_buffer.clear"
        )
    }

    func testConversationItemTruncateUsesTrackedItemAndClampsNegativeTime() {
        let event = OpenAIRealtimeRequestBuilder.conversationItemTruncateEvent(
            itemID: "assistant-item",
            audioEndMilliseconds: -1
        )

        XCTAssertEqual(event["type"] as? String, "conversation.item.truncate")
        XCTAssertEqual(event["item_id"] as? String, "assistant-item")
        XCTAssertEqual(event["content_index"] as? Int, 0)
        XCTAssertEqual(event["audio_end_ms"] as? Int, 0)
    }

    private var testConfiguration: VoiceSessionConfiguration {
        VoiceSessionConfiguration(
            providerID: .openAIRealtime,
            model: "gpt-realtime-2-test",
            voice: "marin-test",
            instructions: "Keep it concise."
        )
    }

    private func dictionary(_ value: Any?, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        try XCTUnwrap(value as? [String: Any], file: file, line: line)
    }

    func testOpenAIAlwaysInjectsExaMCPServerAndNoInvalidHostedType() throws {
        // Web search is delivered as the Exa remote MCP server (Realtime
        // executes it server-side); it must never be an invalid hosted type.
        var configuration = VoiceSessionConfiguration(
            providerID: .openAIRealtime,
            model: "gpt-realtime-2-test",
            voice: "marin",
            instructions: "Keep it concise."
        )
        configuration.webSearchEnabled = false
        configuration.mcpServers = [
            MCPServerConfiguration(label: "deepwiki", urlString: "https://mcp.deepwiki.com/mcp")
        ]

        let event = OpenAIRealtimeRequestBuilder.sessionUpdateEvent(
            configuration: configuration,
            authorizationProvider: { _ in nil }
        )
        let session = try XCTUnwrap(event["session"] as? [String: Any])
        let tools = try XCTUnwrap(session["tools"] as? [[String: Any]])
        let types = tools.compactMap { $0["type"] as? String }
        XCTAssertTrue(types.allSatisfy { $0 == "function" || $0 == "mcp" })
        let exa = tools.first { ($0["server_label"] as? String) == "exa" }
        XCTAssertEqual(exa?["type"] as? String, "mcp")
        XCTAssertEqual(exa?["server_url"] as? String, OpenAIRealtimeRequestBuilder.exaWebSearchServerURL)
        XCTAssertEqual(exa?["require_approval"] as? String, "never")
        // Exa is listed before the user's own MCP servers.
        XCTAssertEqual(tools.first?["server_label"] as? String, "exa")
    }

    func testStoredWebSearchFlagFalseStillInjectsExa() throws {
        var configuration = VoiceSessionConfiguration(
            providerID: .openAIRealtime,
            model: "gpt-realtime-2-test",
            voice: "marin",
            instructions: "Keep it concise."
        )
        configuration.webSearchEnabled = false
        let event = OpenAIRealtimeRequestBuilder.sessionUpdateEvent(
            configuration: configuration,
            authorizationProvider: { _ in nil }
        )
        let session = try XCTUnwrap(event["session"] as? [String: Any])
        let tools = try XCTUnwrap(
            session["tools"] as? [[String: Any]]
        )
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(
            tools.first?["server_label"] as? String,
            "exa"
        )
    }

    func testCustomProtocolDoesNotReceiveOpenAIWebSearch() throws {
        let configuration = VoiceSessionConfiguration(
            providerID: .custom,
            model: "custom-model",
            voice: "custom-voice",
            instructions: "Keep it concise."
        )
        let event = OpenAIRealtimeRequestBuilder.sessionUpdateEvent(
            configuration: configuration,
            authorizationProvider: { _ in nil }
        )
        let session = try XCTUnwrap(
            event["session"] as? [String: Any]
        )
        XCTAssertNil(session["tools"])
    }
}
