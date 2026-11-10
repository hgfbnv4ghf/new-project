import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ToolSpec: Equatable, Sendable {
    public var name: String
    public var description: String
    /// JSON Schema object for the arguments.
    public var parametersJSON: String

    public init(name: String, description: String, parametersJSON: String) {
        self.name = name
        self.description = description
        self.parametersJSON = parametersJSON
    }
}

public struct ChatRequest: Sendable {
    public var baseURL: String
    public var apiKey: String
    public var model: String
    public var messages: [ChatMessage]
    public var tools: [ToolSpec]

    public init(baseURL: String, apiKey: String, model: String, messages: [ChatMessage], tools: [ToolSpec] = []) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.messages = messages
        self.tools = tools
    }
}

public enum StreamEvent: Equatable, Sendable {
    case text(String)
    /// A fragment of a tool call; fragments with the same index belong together.
    case toolCallDelta(index: Int, id: String?, name: String?, arguments: String?)
    case usage(input: Int, output: Int)
}

public protocol ChatStreaming: Sendable {
    func streamChat(_ request: ChatRequest) -> AsyncThrowingStream<StreamEvent, Error>
}

public enum ClientError: LocalizedError, Equatable {
    case invalidBaseURL(String)

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let value): return "invalid base URL: \(value)"
        }
    }
}

/// Splits a server-sent-events byte stream into `data:` payloads.
public struct SSEParser {
    private var buffer = Data()

    public init() {}

    public mutating func feed(_ data: Data) -> [String] {
        buffer.append(data)
        var payloads: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = Data(buffer[buffer.startIndex..<newline])
            buffer = Data(buffer[buffer.index(after: newline)...])
            if line.last == 0x0D { line.removeLast() }
            guard let text = String(data: line, encoding: .utf8), text.hasPrefix("data:") else { continue }
            var payload = text.dropFirst(5)
            if payload.first == " " { payload = payload.dropFirst() }
            payloads.append(String(payload))
        }
        return payloads
    }
}

/// Client for OpenAI-compatible `/chat/completions` and `/models`.
public struct OpenAIClient: ChatStreaming {
    public init() {}

    static func endpoint(_ baseURL: String, _ path: String) throws -> URL {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + path), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else {
            throw ClientError.invalidBaseURL(baseURL)
        }
        return url
    }

    static func encodeMessage(_ message: ChatMessage) -> [String: Any] {
        var object: [String: Any] = ["role": message.role.rawValue, "content": message.content]
        if let calls = message.toolCalls, !calls.isEmpty {
            object["tool_calls"] = calls.map { call -> [String: Any] in
                ["id": call.id, "type": "function",
                 "function": ["name": call.name, "arguments": call.arguments.isEmpty ? "{}" : call.arguments]]
            }
        }
        if let id = message.toolCallID { object["tool_call_id"] = id }
        return object
    }

    static func body(for request: ChatRequest) throws -> Data {
        var object: [String: Any] = [
            "model": request.model,
            "stream": true,
            "stream_options": ["include_usage": true],
            "messages": request.messages.map(encodeMessage),
        ]
        if !request.tools.isEmpty {
            object["tools"] = request.tools.map { tool -> [String: Any] in
                let parameters = (try? JSONSerialization.jsonObject(with: Data(tool.parametersJSON.utf8))) ?? [String: Any]()
                return ["type": "function",
                        "function": ["name": tool.name, "description": tool.description, "parameters": parameters]]
            }
        }
        return try JSONSerialization.data(withJSONObject: object)
    }

    static func urlRequest(for request: ChatRequest) throws -> URLRequest {
        var urlRequest = URLRequest(url: try endpoint(request.baseURL, "/chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 300
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if !request.apiKey.isEmpty {
            urlRequest.setValue("Bearer \(request.apiKey)", forHTTPHeaderField: "Authorization")
        }
        urlRequest.httpBody = try body(for: request)
        return urlRequest
    }

    /// Decodes one `data:` payload of a streamed chat completion.
    public static func decode(_ payload: String) -> [StreamEvent] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { return [] }
        var events: [StreamEvent] = []
        if let choices = object["choices"] as? [[String: Any]], let delta = choices.first?["delta"] as? [String: Any] {
            if let text = delta["content"] as? String, !text.isEmpty {
                events.append(.text(text))
            }
            for (position, call) in ((delta["tool_calls"] as? [[String: Any]]) ?? []).enumerated() {
                let function = call["function"] as? [String: Any]
                events.append(.toolCallDelta(
                    index: (call["index"] as? NSNumber)?.intValue ?? position,
                    id: call["id"] as? String,
                    name: function?["name"] as? String,
                    arguments: function?["arguments"] as? String))
            }
        }
        if let usage = object["usage"] as? [String: Any] {
            let input = (usage["prompt_tokens"] as? NSNumber)?.intValue ?? 0
            let output = (usage["completion_tokens"] as? NSNumber)?.intValue ?? 0
            if input > 0 || output > 0 { events.append(.usage(input: input, output: output)) }
        }
        return events
    }

    public func streamChat(_ request: ChatRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlRequest = try Self.urlRequest(for: request)
                    var parser = SSEParser()
                    var status = 0
                    var errorBody = Data()
                    for try await chunk in HTTP.stream(urlRequest) {
                        switch chunk {
                        case .status(let code):
                            status = code
                        case .data(let data):
                            guard (200..<300).contains(status) else {
                                errorBody.append(data)
                                continue
                            }
                            for payload in parser.feed(data) where payload != "[DONE]" {
                                for event in Self.decode(payload) { continuation.yield(event) }
                            }
                        }
                    }
                    try Task.checkCancellation()
                    guard (200..<300).contains(status) else { throw APIError.from(status: status, body: errorBody) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Model IDs advertised by the endpoint's `/models`.
    public func listModels(baseURL: String, apiKey: String) async throws -> [String] {
        var urlRequest = URLRequest(url: try Self.endpoint(baseURL, "/models"))
        urlRequest.timeoutInterval = 30
        if !apiKey.isEmpty { urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        let (status, body) = try await HTTP.collect(urlRequest)
        guard (200..<300).contains(status) else { throw APIError.from(status: status, body: body) }
        let object = try? JSONSerialization.jsonObject(with: body)
        let entries = ((object as? [String: Any])?["data"] as? [[String: Any]]) ?? (object as? [[String: Any]]) ?? []
        return entries.compactMap { $0["id"] as? String }.sorted()
    }
}
