import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum HTTPChunk: Sendable {
    case status(Int)
    case data(Data)
}

public struct APIError: LocalizedError, Equatable {
    public var status: Int
    public var message: String

    public var errorDescription: String? { "HTTP \(status): \(message)" }

    /// Pulls `error.message` out of an OpenAI-style error body, falling back to the raw text.
    static func from(status: Int, body: Data) -> APIError {
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
                return APIError(status: status, message: message)
            }
            if let message = (object["error"] as? String) ?? (object["message"] as? String) {
                return APIError(status: status, message: message)
            }
        }
        let text = String(data: body.prefix(400), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return APIError(status: status, message: text.isEmpty ? "request failed" : text)
    }
}

/// Delegate-based streaming, because `URLSession.bytes(for:)` is not available on every platform we build for.
enum HTTP {
    private final class StreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let continuation: AsyncThrowingStream<HTTPChunk, Error>.Continuation

        init(continuation: AsyncThrowingStream<HTTPChunk, Error>.Continuation) {
            self.continuation = continuation
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            continuation.yield(.status((response as? HTTPURLResponse)?.statusCode ?? 0))
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            continuation.yield(.data(data))
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error {
                continuation.finish(throwing: error)
            } else {
                continuation.finish()
            }
            session.finishTasksAndInvalidate()
        }
    }

    static func stream(_ request: URLRequest) -> AsyncThrowingStream<HTTPChunk, Error> {
        AsyncThrowingStream { continuation in
            let delegate = StreamDelegate(continuation: continuation)
            let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
            let task = session.dataTask(with: request)
            continuation.onTermination = { _ in task.cancel() }
            task.resume()
        }
    }

    /// Reads a whole response, stopping once `limit` bytes have arrived.
    static func collect(_ request: URLRequest, limit: Int = 4_000_000) async throws -> (status: Int, body: Data) {
        var status = 0
        var body = Data()
        for try await chunk in stream(request) {
            switch chunk {
            case .status(let code): status = code
            case .data(let data): body.append(data)
            }
            if body.count >= limit { break }
        }
        try Task.checkCancellation()
        return (status, body)
    }
}
