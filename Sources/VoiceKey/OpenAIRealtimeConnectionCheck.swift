import Foundation

enum OpenAIRealtimeConnectionCheckResult: Equatable {
    case success([String])
    case failure(String)
}

enum OpenAIRealtimeConnectionCheckEventResult: Equatable {
    case waiting(String)
    case succeeded(String)
    case failed(String)
}

enum OpenAIRealtimeConnectionCheckEventMapper {
    static func result(from text: String) -> OpenAIRealtimeConnectionCheckEventResult? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            return nil
        }

        if type == "session.updated" {
            return .succeeded(type)
        }

        if type == "error" {
            let error = object["error"] as? [String: Any]
            let message = error?["message"] as? String ?? "OpenAI Realtime API returned an error."
            return .failed(message)
        }

        return .waiting(type)
    }
}

final class OpenAIRealtimeConnectionCheck: NSObject {
    private let apiKey: String
    private let configuration: VoiceSessionConfiguration
    private let timeout: TimeInterval
    private var completion: ((OpenAIRealtimeConnectionCheckResult) -> Void)?
    private var urlSession: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private var timeoutWorkItem: DispatchWorkItem?
    private var eventTypes: [String] = []
    private var isFinished = false

    init(apiKey: String, configuration: VoiceSessionConfiguration, timeout: TimeInterval = 15) {
        self.apiKey = apiKey
        self.configuration = configuration
        self.timeout = timeout
    }

    func start(completion: @escaping (OpenAIRealtimeConnectionCheckResult) -> Void) {
        self.completion = completion

        guard let request = OpenAIRealtimeRequestBuilder.webSocketRequest(
            apiKey: apiKey,
            configuration: configuration
        ) else {
            finish(.failure("Could not build the OpenAI Realtime API URL."))
            return
        }

        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            self?.finish(.failure("OpenAI Realtime API check timed out."))
        }
        self.timeoutWorkItem = timeoutWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)

        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        urlSession = session
        webSocketTask = task
        task.resume()
    }

    private func sendSessionUpdate() {
        guard let webSocketTask,
              let data = try? JSONSerialization.data(
                withJSONObject: OpenAIRealtimeRequestBuilder.sessionUpdateEvent(configuration: configuration)
              ),
              let text = String(data: data, encoding: .utf8) else {
            finish(.failure("Could not encode the OpenAI Realtime API session update."))
            return
        }

        webSocketTask.send(.string(text)) { [weak self] error in
            if let error {
                self?.finish(.failure("OpenAI Realtime API check failed: \(error.localizedDescription)"))
                return
            }
            self?.receiveLoop()
        }
    }

    private func receiveLoop() {
        webSocketTask?.receive { [weak self] result in
            guard let self, self.isFinished == false else { return }
            switch result {
            case let .success(message):
                self.handle(message)
            case let .failure(error):
                self.finish(.failure("OpenAI Realtime API check failed: \(error.localizedDescription)"))
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let text: String?
        switch message {
        case let .string(value):
            text = value
        case let .data(data):
            text = String(data: data, encoding: .utf8)
        @unknown default:
            text = nil
        }

        guard let text,
              let result = OpenAIRealtimeConnectionCheckEventMapper.result(from: text) else {
            receiveLoop()
            return
        }

        switch result {
        case let .waiting(type):
            eventTypes.append(type)
            receiveLoop()
        case let .succeeded(type):
            eventTypes.append(type)
            finish(.success(eventTypes))
        case let .failed(message):
            finish(.failure("OpenAI Realtime API check failed: \(message)"))
        }
    }

    private func finish(_ result: OpenAIRealtimeConnectionCheckResult) {
        guard isFinished == false else { return }
        isFinished = true
        timeoutWorkItem?.cancel()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        urlSession?.invalidateAndCancel()
        DispatchQueue.main.async { [completion] in
            completion?(result)
        }
    }
}

extension OpenAIRealtimeConnectionCheck: URLSessionWebSocketDelegate {
    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        sendSessionUpdate()
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        guard isFinished == false,
              closeCode != .normalClosure,
              closeCode != .goingAway else {
            return
        }

        let status = OpenAIRealtimeConnectionDiagnostics.closeStatus(code: closeCode, reason: reason)
        finish(.failure(status.detail ?? status.menuTitle))
    }
}
