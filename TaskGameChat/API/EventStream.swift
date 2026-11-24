import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum StreamPhase: Equatable {
    case idle
    case connecting
    case live
    case reconnecting
}

/// `GET /v1/events/stream` with `Authorization: Bearer` and `Accept: text/event-stream`.
/// EventSource cannot set that header, so this uses a `URLSession` data task.
/// `bytes.lines` drops the blank line that ends a frame and can hold small chunks until the
/// request times out, so a phone pointed at a LAN API never saw `chat.message`.
/// A non-empty `Last-Event-ID` makes the server open with `resync` instead of `hello`.
final class EventStream: @unchecked Sendable {
    var onSignal: ((StreamSignal) -> Void)?
    var onPhase: ((StreamPhase) -> Void)?
    var onUnauthorized: (() -> Void)?

    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var session: URLSession?
    private var lastEventID = ""

    func start(baseURL: String, token: String) {
        stop()
        let configuration = URLSessionConfiguration.ephemeral
        // `URLSession.bytes` plus a short `timeoutIntervalForRequest` never leaves this GET open:
        // the system waits for a finished body, times out, and the API sees no held connection.
        // The stream has no end. Heartbeats reset an idle timer; the resource timeout is a day.
        configuration.timeoutIntervalForRequest = 60 * 60 * 24
        configuration.timeoutIntervalForResource = 60 * 60 * 24
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldUsePipelining = false
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.httpAdditionalHeaders = ["Accept-Encoding": "identity"]
        lock.lock()
        task = Task.detached { [weak self] in
            await self?.run(baseURL: baseURL, token: token, configuration: configuration)
        }
        lock.unlock()
    }

    func stop(resetCursor: Bool = false) {
        lock.lock()
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
        if resetCursor { lastEventID = "" }
        lock.unlock()
        onPhase?(.idle)
    }

    private func currentCursor() -> String {
        lock.lock()
        defer { lock.unlock() }
        return lastEventID
    }

    private func rememberCursor(_ id: String) {
        lock.lock()
        lastEventID = id
        lock.unlock()
    }

    private func rememberSession(_ session: URLSession) {
        lock.lock()
        self.session?.invalidateAndCancel()
        self.session = session
        lock.unlock()
    }

    private func run(baseURL: String, token: String, configuration: URLSessionConfiguration) async {
        var attempt = 0
        while !Task.isCancelled {
            do {
                onPhase?(attempt == 0 ? .connecting : .reconnecting)
                try await connectOnce(baseURL: baseURL, token: token, configuration: configuration)
                attempt = 0
            } catch is CancellationError {
                return
            } catch let error as URLError where error.code == .cancelled {
                return
            } catch let ClientError.api(failure) where failure.status == 401 {
                onUnauthorized?()
                return
            } catch {
                if Task.isCancelled { return }
            }
            if Task.isCancelled { return }
            attempt = min(attempt + 1, 6)
            let seconds = min(pow(2.0, Double(attempt - 1)), 30)
            onPhase?(.reconnecting)
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    }

    private func connectOnce(baseURL: String, token: String, configuration: URLSessionConfiguration) async throws {
        let urls = try ServiceURLs.resolve(baseURL)
        var request = URLRequest(url: urls.streamURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 60 * 60 * 24
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let cursor = currentCursor()
        if !cursor.isEmpty {
            request.setValue(cursor, forHTTPHeaderField: "Last-Event-ID")
        }
        let pump = StreamPump()
        let session = URLSession(configuration: configuration, delegate: pump, delegateQueue: nil)
        rememberSession(session)
        let (http, chunks) = try await pump.open(session: session, request: request)
        guard http.statusCode == 200 else {
            session.invalidateAndCancel()
            throw ClientError.api(APIFailure(status: http.statusCode, code: "http_error", message: "事件流返回 \(http.statusCode)"))
        }
        onPhase?(.live)
        var parser = SSEParser()
        var pending = Data()
        do {
            for try await chunk in chunks {
                try Task.checkCancellation()
                pending.append(chunk)
                let text = SSEText.take(&pending)
                if !text.isEmpty {
                    deliver(parser.append(text))
                }
            }
        } catch {
            session.invalidateAndCancel()
            throw error
        }
        let tail = SSEText.take(&pending)
        if !tail.isEmpty {
            deliver(parser.append(tail))
        }
        deliver(parser.append("\n"))
    }

    private func deliver(_ frames: [SSEFrame]) {
        for frame in frames {
            if !frame.id.isEmpty { rememberCursor(frame.id) }
            guard let data = frame.data.data(using: .utf8),
                  let signal = try? JSONDecoder().decode(StreamSignal.self, from: data),
                  !signal.type.isEmpty
            else { continue }
            onSignal?(signal)
        }
    }
}

enum SSEText {
    /// Decode a complete UTF-8 prefix, leaving a split code unit in `data`.
    static func take(_ data: inout Data) -> String {
        if data.isEmpty { return "" }
        if let text = String(data: data, encoding: .utf8) {
            data.removeAll(keepingCapacity: true)
            return text
        }
        let limit = max(0, data.count - 3)
        var end = data.count
        while end > limit {
            end -= 1
            if let text = String(data: data.prefix(end), encoding: .utf8) {
                data.removeFirst(end)
                return text
            }
        }
        return ""
    }
}

/// Forwards each `URLSession` body chunk as soon as the socket delivers it.
private final class StreamPump: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var responseContinuation: CheckedContinuation<HTTPURLResponse, Error>?
    private var response: Result<HTTPURLResponse, Error>?
    private var chunks: AsyncThrowingStream<Data, Error>.Continuation?
    private var pending: [Data] = []
    private var streamReady = false
    private var completed = false

    func open(session: URLSession, request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            self.lock.lock()
            self.chunks = continuation
            let buffered = self.pending
            self.pending.removeAll()
            let completed = self.completed
            let response = self.response
            self.streamReady = true
            self.lock.unlock()
            for data in buffered {
                continuation.yield(data)
            }
            if completed {
                self.finish(continuation, response: response)
            }
        }
        let task = session.dataTask(with: request)
        task.resume()
        let http = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<HTTPURLResponse, Error>) in
                self.lock.lock()
                if let response = self.response {
                    self.lock.unlock()
                    cont.resume(with: response)
                } else {
                    self.responseContinuation = cont
                    self.lock.unlock()
                }
            }
        } onCancel: {
            task.cancel()
        }
        return (http, stream)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let result: Result<HTTPURLResponse, Error>
        if let http = response as? HTTPURLResponse {
            result = .success(http)
        } else {
            result = .failure(ClientError.badResponse("事件流没有返回 HTTP 响应。"))
        }
        lock.lock()
        self.response = result
        let waiter = responseContinuation
        responseContinuation = nil
        lock.unlock()
        waiter?.resume(with: result)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let ready = streamReady
        let chunks = self.chunks
        if ready, let chunks {
            lock.unlock()
            chunks.yield(data)
        } else {
            pending.append(data)
            lock.unlock()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        completed = true
        if response == nil {
            response = .failure(error ?? ClientError.badResponse("事件流没有返回 HTTP 响应。"))
        } else if let error, case .success = response {
            response = .failure(error)
        }
        let result = response
        let waiter = responseContinuation
        let chunks = self.chunks
        responseContinuation = nil
        lock.unlock()
        if let waiter, let result {
            waiter.resume(with: result)
        }
        finish(chunks, response: result)
    }

    private func finish(_ continuation: AsyncThrowingStream<Data, Error>.Continuation?, response: Result<HTTPURLResponse, Error>?) {
        switch response {
        case .failure(let error):
            continuation?.finish(throwing: error)
        default:
            continuation?.finish()
        }
    }
}
