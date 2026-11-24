import Foundation

enum StreamPhase: Equatable {
    case idle
    case connecting
    case live
    case reconnecting
}

/// `GET /v1/events/stream` with `Authorization: Bearer` and `Accept: text/event-stream`.
/// EventSource cannot set that header, so this uses `URLSession` bytes, the same idea as `web/src/eventStream.ts`.
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
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 60 * 60 * 24
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        lock.lock()
        self.session = session
        task = Task { [weak self] in
            await self?.run(baseURL: baseURL, token: token, session: session)
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

    private func run(baseURL: String, token: String, session: URLSession) async {
        var attempt = 0
        while !Task.isCancelled {
            do {
                onPhase?(attempt == 0 ? .connecting : .reconnecting)
                try await connectOnce(baseURL: baseURL, token: token, session: session)
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

    private func connectOnce(baseURL: String, token: String, session: URLSession) async throws {
        let urls = try ServiceURLs.resolve(baseURL)
        var request = URLRequest(url: urls.streamURL)
        request.httpMethod = "GET"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let cursor = currentCursor()
        if !cursor.isEmpty {
            request.setValue(cursor, forHTTPHeaderField: "Last-Event-ID")
        }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.badResponse("事件流没有返回 HTTP 响应。")
        }
        guard http.statusCode == 200 else {
            throw ClientError.api(APIFailure(status: http.statusCode, code: "http_error", message: "事件流返回 \(http.statusCode)"))
        }
        onPhase?(.live)
        var parser = SSEParser()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            deliver(parser.append(line + "\n"))
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
