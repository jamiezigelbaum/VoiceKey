@testable import VoiceKey
import Foundation
import XCTest

final class OpenAIResponsesWebSearchClientTests: XCTestCase {
    func testRequestUsesResponsesWebSearchModelAndChannelKey() throws {
        let request = try XCTUnwrap(
            OpenAIResponsesWebSearchClient.request(
                query: "latest space launch",
                apiKey: "channel-openai-key"
            )
        )

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertEqual(request.url?.host, "api.openai.com")
        XCTAssertEqual(request.url?.path, "/v1/responses")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer channel-openai-key"
        )
        XCTAssertEqual(
            request.timeoutInterval,
            OpenAIResponsesWebSearchClient.timeout
        )
        let body = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: XCTUnwrap(request.httpBody)
            ) as? [String: Any]
        )
        XCTAssertEqual(
            body["model"] as? String,
            OpenAIResponsesWebSearchClient.model
        )
        XCTAssertEqual(
            body["input"] as? String,
            "latest space launch"
        )
        let tools = try XCTUnwrap(
            body["tools"] as? [[String: Any]]
        )
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0]["type"] as? String, "web_search")
    }

    func testSearchReturnsAssistantOutputTextThroughFakeHTTPTransport()
        throws {
        let transport = FakeOpenAIWebSearchHTTPTransport()
        let client = OpenAIResponsesWebSearchClient(
            transport: transport
        )
        var result: OpenAIWebSearchResult?

        client.search(
            query: "current answer",
            apiKey: "test-key"
        ) {
            result = $0
        }
        transport.complete(
            statusCode: 200,
            body:
                #"{"output":[{"type":"web_search_call"},{"type":"message","content":[{"type":"output_text","text":"Answer with sources"}]}]}"#
        )

        XCTAssertEqual(
            result,
            .success("Answer with sources")
        )
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testRateLimitAndMissingTextReturnCategorizedFailures() {
        let rateLimitTransport =
            FakeOpenAIWebSearchHTTPTransport()
        let rateLimitClient = OpenAIResponsesWebSearchClient(
            transport: rateLimitTransport
        )
        var rateLimitResult: OpenAIWebSearchResult?
        rateLimitClient.search(query: "query", apiKey: "key") {
            rateLimitResult = $0
        }
        rateLimitTransport.complete(
            statusCode: 429,
            body: #"{"error":{"message":"too many"}}"#
        )
        XCTAssertEqual(
            rateLimitResult,
            .failure(.rateLimited)
        )

        let emptyTransport = FakeOpenAIWebSearchHTTPTransport()
        let emptyClient = OpenAIResponsesWebSearchClient(
            transport: emptyTransport
        )
        var emptyResult: OpenAIWebSearchResult?
        emptyClient.search(query: "query", apiKey: "key") {
            emptyResult = $0
        }
        emptyTransport.complete(
            statusCode: 200,
            body:
                #"{"output":[{"type":"message","content":[]}]}"#
        )
        XCTAssertEqual(
            emptyResult,
            .failure(.invalidResponse)
        )
    }

    func testTransportTimeoutIsReportedAsTimeout() {
        let transport = FakeOpenAIWebSearchHTTPTransport()
        let client = OpenAIResponsesWebSearchClient(
            transport: transport
        )
        var result: OpenAIWebSearchResult?

        client.search(query: "query", apiKey: "key") {
            result = $0
        }
        transport.complete(
            error: URLError(.timedOut)
        )

        XCTAssertEqual(result, .failure(.timedOut))
    }
}

private final class FakeOpenAIWebSearchHTTPTransport:
    OpenAIWebSearchHTTPTransport {
    private(set) var requests: [URLRequest] = []
    private var completions: [
        (Result<(Data, HTTPURLResponse), Error>) -> Void
    ] = []

    func perform(
        _ request: URLRequest,
        completion: @escaping (
            Result<(Data, HTTPURLResponse), Error>
        ) -> Void
    ) {
        requests.append(request)
        completions.append(completion)
    }

    func complete(statusCode: Int, body: String) {
        guard let url = requests.first?.url,
              let completion = completions.first,
              let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        ) else {
            XCTFail("Fake transport has no pending request")
            return
        }
        completion(
            .success((Data(body.utf8), response))
        )
    }

    func complete(error: Error) {
        guard let completion = completions.first else {
            XCTFail("Fake transport has no pending request")
            return
        }
        completion(.failure(error))
    }
}
