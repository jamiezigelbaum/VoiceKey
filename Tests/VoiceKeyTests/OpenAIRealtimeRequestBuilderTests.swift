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
        XCTAssertNil(session["tools"])

        let audio = try dictionary(session["audio"])
        let input = try dictionary(audio["input"])
        let inputFormat = try dictionary(input["format"])
        XCTAssertEqual(inputFormat["type"] as? String, "audio/pcm")
        XCTAssertEqual(inputFormat["rate"] as? Int, 24_000)

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
        XCTAssertEqual(tools.count, 2)
        XCTAssertEqual(tools[0]["type"] as? String, "mcp")
        XCTAssertEqual(tools[0]["server_label"] as? String, "calendar")
        XCTAssertEqual(
            tools[0]["server_url"] as? String,
            "https://mcp.example.com/calendar"
        )
        XCTAssertEqual(tools[0]["require_approval"] as? String, "never")
        XCTAssertEqual(
            tools[0]["allowed_tools"] as? [String],
            ["search_events", "create_event"]
        )
        XCTAssertEqual(tools[0]["authorization"] as? String, "secret-token")

        XCTAssertEqual(tools[1]["type"] as? String, "mcp")
        XCTAssertEqual(tools[1]["server_label"] as? String, "search")
        XCTAssertEqual(
            tools[1]["server_url"] as? String,
            "https://mcp.example.com/search"
        )
        XCTAssertEqual(tools[1]["require_approval"] as? String, "never")
        XCTAssertNil(tools[1]["allowed_tools"])
        XCTAssertNil(tools[1]["authorization"])
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
        XCTAssertNil(try XCTUnwrap(tools.first)["authorization"])
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

    func testWebSearchEnabledNeverEmitsInvalidHostedToolType() throws {
        // The Realtime API rejects tools whose type is not "function" or
        // "mcp"; enabling web search must not inject a "web_search" entry.
        var configuration = VoiceSessionConfiguration(
            providerID: .openAIRealtime,
            model: "gpt-realtime-2-test",
            voice: "marin",
            instructions: "Keep it concise."
        )
        configuration.webSearchEnabled = true
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
        XCTAssertFalse(types.contains("web_search"))
        XCTAssertTrue(types.allSatisfy { $0 == "function" || $0 == "mcp" })
    }

    func testWebSearchDisabledAndNoServersOmitsToolsKey() throws {
        let configuration = VoiceSessionConfiguration(
            providerID: .openAIRealtime,
            model: "gpt-realtime-2-test",
            voice: "marin",
            instructions: "Keep it concise."
        )
        let event = OpenAIRealtimeRequestBuilder.sessionUpdateEvent(
            configuration: configuration,
            authorizationProvider: { _ in nil }
        )
        let session = try XCTUnwrap(event["session"] as? [String: Any])
        XCTAssertNil(session["tools"])
    }
}
