import Foundation

enum OpenAIWebSearchFailure: Equatable {
    case missingAPIKey
    case timedOut
    case network
    case authentication
    case rateLimited
    case server
    case invalidResponse

    var diagnosticCategory: String {
        switch self {
        case .missingAPIKey:
            return "missing_key"
        case .timedOut:
            return "timeout"
        case .network:
            return "network"
        case .authentication:
            return "authentication"
        case .rateLimited:
            return "rate_limit"
        case .server:
            return "http_error"
        case .invalidResponse:
            return "invalid_response"
        }
    }

    var functionOutput: String {
        switch self {
        case .missingAPIKey:
            return "Web search failed because no OpenAI API key is available."
        case .timedOut:
            return "Web search timed out before a result was available."
        case .network:
            return "Web search failed because the network request could not be completed."
        case .authentication:
            return "Web search failed because OpenAI rejected the API key."
        case .rateLimited:
            return "Web search is temporarily unavailable because OpenAI's rate limit was reached."
        case .server:
            return "Web search failed because OpenAI returned an HTTP error."
        case .invalidResponse:
            return "Web search failed because OpenAI returned no usable answer."
        }
    }
}

enum OpenAIWebSearchResult: Equatable {
    case success(String)
    case failure(OpenAIWebSearchFailure)
}

protocol OpenAIWebSearching {
    func search(
        query: String,
        apiKey: String,
        completion: @escaping (OpenAIWebSearchResult) -> Void
    )
}

protocol OpenAIWebSearchHTTPTransport {
    func perform(
        _ request: URLRequest,
        completion: @escaping (Result<(Data, HTTPURLResponse), Error>) -> Void
    )
}

final class URLSessionOpenAIWebSearchTransport:
    OpenAIWebSearchHTTPTransport {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func perform(
        _ request: URLRequest,
        completion: @escaping (
            Result<(Data, HTTPURLResponse), Error>
        ) -> Void
    ) {
        session.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let data,
                  let response = response as? HTTPURLResponse else {
                completion(.failure(OpenAIWebSearchTransportError.noResponse))
                return
            }
            completion(.success((data, response)))
        }.resume()
    }
}

private enum OpenAIWebSearchTransportError: Error {
    case noResponse
}

final class OpenAIResponsesWebSearchClient: OpenAIWebSearching {
    static let model = "gpt-4.1-mini"
    static let timeout: TimeInterval = 15

    private let transport: OpenAIWebSearchHTTPTransport

    init(
        transport: OpenAIWebSearchHTTPTransport =
            URLSessionOpenAIWebSearchTransport()
    ) {
        self.transport = transport
    }

    func search(
        query: String,
        apiKey: String,
        completion: @escaping (OpenAIWebSearchResult) -> Void
    ) {
        guard let request = Self.request(
            query: query,
            apiKey: apiKey
        ) else {
            completion(.failure(.invalidResponse))
            return
        }
        transport.perform(request) { result in
            switch result {
            case let .failure(error):
                if (error as? URLError)?.code == .timedOut {
                    completion(.failure(.timedOut))
                } else {
                    completion(.failure(.network))
                }
            case let .success((data, response)):
                guard (200..<300).contains(response.statusCode) else {
                    completion(.failure(
                        Self.failure(forHTTPStatus: response.statusCode)
                    ))
                    return
                }
                guard let text = Self.assistantText(from: data) else {
                    completion(.failure(.invalidResponse))
                    return
                }
                completion(.success(text))
            }
        }
    }

    static func request(
        query: String,
        apiKey: String
    ) -> URLRequest? {
        guard let url = URL(
            string: "https://api.openai.com/v1/responses"
        ) else {
            return nil
        }
        let body: [String: Any] = [
            "model": model,
            "input": query,
            "tools": [["type": "web_search"]]
        ]
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(
                withJSONObject: body
              ) else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue(
            "Bearer \(apiKey)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = data
        return request
    }

    static func assistantText(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(
            with: data
        ) as? [String: Any],
              let output = object["output"] as? [[String: Any]]
        else {
            return nil
        }
        let text = output
            .filter { $0["type"] as? String == "message" }
            .compactMap { $0["content"] as? [[String: Any]] }
            .flatMap { $0 }
            .filter { $0["type"] as? String == "output_text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func failure(
        forHTTPStatus statusCode: Int
    ) -> OpenAIWebSearchFailure {
        switch statusCode {
        case 401, 403:
            return .authentication
        case 408:
            return .timedOut
        case 429:
            return .rateLimited
        default:
            return .server
        }
    }
}
