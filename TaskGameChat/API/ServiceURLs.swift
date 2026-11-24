import Foundation

/// Same base-URL rules as `sdk/ts` `resolveServiceUrls` and `web/src/sse.ts` `streamUrl`.
/// A bare origin and an origin that already ends in `/v1` both talk to one API process.
struct ServiceURLs: Equatable, Sendable {
    var origin: String
    var apiBase: String

    var streamURL: URL {
        URL(string: apiBase + "/events/stream")!
    }

    var healthURL: URL {
        URL(string: origin + "/health")!
    }

    static let defaultBase = "http://127.0.0.1:8891"

    static func resolve(_ raw: String) throws -> ServiceURLs {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ClientError.invalidBaseURL("请填写服务器地址。")
        }
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty
        else {
            throw ClientError.invalidBaseURL("服务器地址需要是完整的 http 或 https URL。")
        }
        if components.user != nil || components.password != nil {
            throw ClientError.invalidBaseURL("服务器地址不能带用户名或密码。")
        }
        if let query = components.query, !query.isEmpty {
            throw ClientError.invalidBaseURL("服务器地址不能带查询参数。")
        }
        if components.fragment != nil {
            throw ClientError.invalidBaseURL("服务器地址不能带锚点。")
        }

        var path = components.percentEncodedPath
        if path == "/" {
            path = ""
        }
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }

        let originPath: String
        if path == "/v1" {
            originPath = ""
        } else if path.hasSuffix("/v1") {
            var trimmedPath = String(path.dropLast(3))
            while trimmedPath.hasSuffix("/") {
                trimmedPath.removeLast()
            }
            originPath = trimmedPath
        } else if !path.isEmpty {
            throw ClientError.invalidBaseURL("路径留空，或者以 /v1 结尾。例如 http://127.0.0.1:8891")
        } else {
            originPath = ""
        }

        var originComponents = URLComponents()
        originComponents.scheme = scheme
        originComponents.host = host
        originComponents.port = components.port
        guard let originRoot = originComponents.string else {
            throw ClientError.invalidBaseURL("服务器地址无法解析。")
        }
        let origin = originPath.isEmpty ? originRoot : originRoot + originPath
        return ServiceURLs(origin: origin, apiBase: origin + "/v1")
    }
}

enum ClientError: Error, Sendable {
    case invalidBaseURL(String)
    case transport(String)
    case api(APIFailure)
    case badResponse(String)
}

struct APIFailure: Error, Sendable {
    var status: Int
    var code: String
    var message: String
}

enum APIErrorText {
    static func describe(_ error: Error, baseURL: String) -> String {
        switch error {
        case let ClientError.invalidBaseURL(text):
            return text
        case let ClientError.transport(text):
            return text
        case let ClientError.badResponse(text):
            return text
        case let ClientError.api(failure):
            return "\(failure.status) \(failure.code)：\(failure.message)"
        case let failure as APIFailure:
            return "\(failure.status) \(failure.code)：\(failure.message)"
        case let url as URLError:
            return transport(url, baseURL: baseURL)
        default:
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain {
                return transport(URLError(URLError.Code(rawValue: ns.code)), baseURL: baseURL)
            }
            return "请求失败。"
        }
    }

    static func transport(_ error: URLError, baseURL: String) -> String {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .timedOut, .dnsLookupFailed:
            return "无法连接 \(baseURL)。请先在 Mac 上启动 task-game-api。模拟器里的 127.0.0.1 就是这台 Mac。"
        case .appTransportSecurityRequiresSecureConnection, .secureConnectionFailed:
            return "系统拦截了不安全的 HTTP。本地和局域网地址已在 ATS 里放行；公网请改用 https。"
        case .cancelled:
            return ""
        default:
            return "网络错误：\(error.localizedDescription)"
        }
    }

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let url = error as? URLError, url.code == .cancelled { return true }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && ns.code == URLError.cancelled.rawValue
    }

    static func isUnauthorized(_ error: Error) -> Bool {
        if case let ClientError.api(failure) = error, failure.status == 401 { return true }
        if let failure = error as? APIFailure, failure.status == 401 { return true }
        return false
    }
}
