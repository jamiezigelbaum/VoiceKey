@testable import VoiceKey
import XCTest

final class CustomEndpointProviderTests: XCTestCase {
    func testWebSocketRequestUsesCustomBaseURLAndPreservesModelAndAuth() throws {
        let request = try XCTUnwrap(OpenAIRealtimeRequestBuilder.webSocketRequest(
            baseURL: "wss://assistant.local:8443/v1/realtime",
            apiKey: "custom-key",
            configuration: testConfiguration
        ))

        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.scheme, "wss")
        XCTAssertEqual(url.host, "assistant.local")
        XCTAssertEqual(url.port, 8443)
        XCTAssertEqual(url.path, "/v1/realtime")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems, [
            URLQueryItem(name: "model", value: "gpt-realtime-2-test")
        ])
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer custom-key")
        XCTAssertEqual(request.timeoutInterval, 30)
    }

    func testWebSocketRequestOmitsAuthorizationHeaderWhenAPIKeyIsEmpty() throws {
        let request = try XCTUnwrap(OpenAIRealtimeRequestBuilder.webSocketRequest(
            apiKey: "",
            configuration: testConfiguration
        ))

        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testNormalizedBaseURLConvertsHTTPSSchemeAndAppendsRealtimePath() {
        XCTAssertEqual(
            OpenAIRealtimeRequestBuilder.normalizedBaseURL(for: "https://assistant.local"),
            "wss://assistant.local/v1/realtime"
        )
    }

    func testNormalizedBaseURLAddsSecureSchemeToHostAndPort() {
        XCTAssertEqual(
            OpenAIRealtimeRequestBuilder.normalizedBaseURL(for: "assistant.local:8443"),
            "wss://assistant.local:8443/v1/realtime"
        )
    }

    func testNormalizedBaseURLConvertsHTTPSchemeAndKeepsPort() {
        XCTAssertEqual(
            OpenAIRealtimeRequestBuilder.normalizedBaseURL(for: "http://assistant.local:9000"),
            "ws://assistant.local:9000/v1/realtime"
        )
    }

    func testNormalizedBaseURLReplacesRootOnlyPath() {
        XCTAssertEqual(
            OpenAIRealtimeRequestBuilder.normalizedBaseURL(for: "wss://assistant.local/"),
            "wss://assistant.local/v1/realtime"
        )
    }

    func testNormalizedBaseURLKeepsCustomPath() {
        XCTAssertEqual(
            OpenAIRealtimeRequestBuilder.normalizedBaseURL(for: "https://assistant.local/custom/realtime"),
            "wss://assistant.local/custom/realtime"
        )
    }

    func testNormalizedBaseURLFallsBackToDefaultWhenEndpointIsEmpty() {
        XCTAssertEqual(
            OpenAIRealtimeRequestBuilder.normalizedBaseURL(for: ""),
            OpenAIRealtimeRequestBuilder.defaultBaseURL
        )
        XCTAssertEqual(
            OpenAIRealtimeRequestBuilder.normalizedBaseURL(for: "  \n"),
            OpenAIRealtimeRequestBuilder.defaultBaseURL
        )
    }

    func testWebSocketRequestReplacesExistingModelQueryItem() throws {
        let request = try XCTUnwrap(OpenAIRealtimeRequestBuilder.webSocketRequest(
            baseURL: "wss://assistant.local/v1/realtime?organization=example&model=old-model",
            apiKey: "custom-key",
            configuration: testConfiguration
        ))

        let queryItems = try XCTUnwrap(
            URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
        )
        XCTAssertEqual(queryItems.filter { $0.name == "model" }, [
            URLQueryItem(name: "model", value: "gpt-realtime-2-test")
        ])
        XCTAssertEqual(queryItems.filter { $0.name == "organization" }, [
            URLQueryItem(name: "organization", value: "example")
        ])
    }

    func testFactoryReturnsOpenAIRealtimeProviderForCustomEndpoint() {
        let provider = VoiceProviderFactory.makeProvider(
            for: testConfiguration,
            apiKeyStore: APIKeyStore()
        )

        XCTAssertTrue(provider is OpenAIRealtimeProvider)
        XCTAssertEqual(provider.id, .custom)
    }

    func testCustomProviderMetadata() {
        let custom = VoiceProviderID.custom
        XCTAssertEqual(custom.displayName, "Custom Realtime Endpoint")
        XCTAssertTrue(custom.isImplemented)
        XCTAssertFalse(custom.requiresAPIKey)
        XCTAssertEqual(custom.credentialLabel, "API Key (optional)")
        XCTAssertTrue(custom.supportsModelSetting)
        XCTAssertTrue(custom.supportsVoiceSetting)
        XCTAssertTrue(custom.supportsEndpointSetting)
        XCTAssertTrue(custom.usesRealtimeWebSocket)
        XCTAssertTrue(custom.voiceOptions.isEmpty)
        XCTAssertEqual(custom.defaultModel, "gpt-realtime-2")
        XCTAssertEqual(custom.defaultVoice, "marin")
    }

    func testCustomProviderIsReadyWithoutAPIKey() {
        XCTAssertEqual(VoiceProviderID.custom.readiness(hasAPIKey: false), .ready)
        XCTAssertEqual(VoiceProviderID.custom.readiness(hasAPIKey: true), .ready)
    }

    func testEndpointSettingsAreLimitedToRealtimeWebSocketProviders() {
        XCTAssertTrue(VoiceProviderID.openAIRealtime.supportsEndpointSetting)
        XCTAssertTrue(VoiceProviderID.openAIRealtime.usesRealtimeWebSocket)
        XCTAssertFalse(VoiceProviderID.chatGPTWeb.supportsEndpointSetting)
        XCTAssertFalse(VoiceProviderID.chatGPTWeb.usesRealtimeWebSocket)
        XCTAssertFalse(VoiceProviderID.geminiLive.supportsEndpointSetting)
        XCTAssertFalse(VoiceProviderID.deepgramVoiceAgent.supportsEndpointSetting)
    }

    func testCustomProviderIDCodableRoundTrip() throws {
        let data = try JSONEncoder().encode(VoiceProviderID.custom)
        XCTAssertEqual(String(data: data, encoding: .utf8), "\"custom\"")
        XCTAssertEqual(try JSONDecoder().decode(VoiceProviderID.self, from: data), .custom)
    }

    private var testConfiguration: VoiceSessionConfiguration {
        VoiceSessionConfiguration(
            providerID: .custom,
            model: "gpt-realtime-2-test",
            voice: "marin-test",
            instructions: "Keep it concise.",
            endpointURL: "https://assistant.local"
        )
    }
}
