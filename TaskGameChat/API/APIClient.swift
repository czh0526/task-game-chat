import Foundation

/// Hand-written client for the chat, friend, and profile routes.
/// Paths are relative to `{origin}/v1`, except `GET /health`.
/// Operations whose OpenAPI parameter list includes `Idempotency-Key` send a fresh key.
/// Register, login, `PATCH /me`, and `PUT /me/avatar` do not.
struct APIClient: Sendable {
    var urls: ServiceURLs
    var token: String?
    var session: URLSession

    init(baseURL: String, token: String?, session: URLSession = .shared) throws {
        self.urls = try ServiceURLs.resolve(baseURL)
        self.token = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
    }

    func health() async throws -> HealthStatus {
        try await send(method: "GET", url: urls.healthURL, body: nil, idempotency: false, auth: false, ok: [200])
    }

    /// `POST /v1/register` → 201. No auth header.
    func register(email: String, password: String, nickname: String?) async throws -> AuthSession {
        let body = RegisterBody(email: email, password: password, nickname: nickname)
        return try await send(method: "POST", path: "/register", body: body, idempotency: false, auth: false, ok: [201])
    }

    /// `POST /v1/login` → 200. No auth header.
    func login(email: String, password: String) async throws -> AuthSession {
        try await send(method: "POST", path: "/login", body: PasswordBody(email: email, password: password), idempotency: false, auth: false, ok: [200])
    }

    /// `GET /v1/me`
    func me() async throws -> UserSummary {
        try await send(method: "GET", path: "/me", body: nil, idempotency: false, auth: true, ok: [200])
    }

    /// `PATCH /v1/me`. No Idempotency-Key. Does not rotate the token.
    func updateMe(nickname: String) async throws -> UserSummary {
        try await send(method: "PATCH", path: "/me", body: ProfileUpdateBody(nickname: nickname), idempotency: false, auth: true, ok: [200])
    }

    /// `PUT /v1/me/avatar`. `image` is raw base64 or a data URL. No Idempotency-Key.
    func putAvatar(image: String) async throws -> AvatarSummary {
        try await send(method: "PUT", path: "/me/avatar", body: AvatarUploadBody(image: image), idempotency: false, auth: true, ok: [200])
    }

    /// Public `GET /v1/users/{userId}/avatar`. No Authorization header, so a stale token cannot hide the picture.
    func avatarURL(userId: String, version: Int = 0) -> URL? {
        guard let encoded = userId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        var string = "\(urls.apiBase)/users/\(encoded)/avatar"
        if version > 0 { string += "?v=\(version)" }
        return URL(string: string)
    }

    /// `GET /v1/users/{userId}/scores`. Public. Used to learn a nickname outside the friend list.
    func userScores(userId: String) async throws -> UserScores {
        try await send(method: "GET", path: "/users/\(path(userId))/scores", body: nil, idempotency: false, auth: false, ok: [200])
    }

    /// `GET /v1/friends`
    func listFriends() async throws -> FriendList {
        try await send(method: "GET", path: "/friends", body: nil, idempotency: false, auth: true, ok: [200])
    }

    /// `POST /v1/friends/requests`. 201 creates a request. 200 accepts the reverse pending request.
    func createFriendRequest(userId: String) async throws -> FriendRequest {
        try await send(
            method: "POST",
            path: "/friends/requests",
            body: CreateFriendRequestBody(userId: userId),
            idempotency: true,
            auth: true,
            ok: [200, 201]
        )
    }

    /// `GET /v1/friend-requests?direction=incoming|outgoing`
    func listFriendRequests(direction: String) async throws -> FriendRequestList {
        let items = [URLQueryItem(name: "direction", value: direction)]
        return try await send(method: "GET", path: "/friend-requests", query: items, body: nil, idempotency: false, auth: true, ok: [200])
    }

    /// `POST /v1/friend-requests/{requestId}/accept` → 200
    func acceptFriendRequest(id: String) async throws -> FriendRequest {
        try await send(method: "POST", path: "/friend-requests/\(path(id))/accept", body: EmptyBody(), idempotency: true, auth: true, ok: [200])
    }

    /// `POST /v1/friend-requests/{requestId}/decline` → 200
    func declineFriendRequest(id: String) async throws -> FriendRequest {
        try await send(method: "POST", path: "/friend-requests/\(path(id))/decline", body: EmptyBody(), idempotency: true, auth: true, ok: [200])
    }

    /// `DELETE /v1/friend-requests/{requestId}` → 200
    func cancelFriendRequest(id: String) async throws -> FriendRequest {
        try await send(method: "DELETE", path: "/friend-requests/\(path(id))", body: nil, idempotency: true, auth: true, ok: [200])
    }

    /// `DELETE /v1/friends/{userId}` → 200
    func unfriend(userId: String) async throws -> RemovedFriend {
        try await send(method: "DELETE", path: "/friends/\(path(userId))", body: nil, idempotency: true, auth: true, ok: [200])
    }

    /// `PUT /v1/friends/{userId}/group`. `groupId == nil` ungroups.
    func setFriendGroup(userId: String, groupId: String?) async throws -> FriendPlacement {
        try await send(
            method: "PUT",
            path: "/friends/\(path(userId))/group",
            body: SetFriendGroupBody(groupId: groupId),
            idempotency: true,
            auth: true,
            ok: [200]
        )
    }

    /// `POST /v1/friend-groups` → 201
    func createFriendGroup(name: String) async throws -> FriendGroup {
        try await send(method: "POST", path: "/friend-groups", body: CreateFriendGroupBody(name: name), idempotency: true, auth: true, ok: [201])
    }

    /// `PATCH /v1/friend-groups/{groupId}` → 200
    func renameFriendGroup(id: String, name: String) async throws -> FriendGroup {
        try await send(method: "PATCH", path: "/friend-groups/\(path(id))", body: PatchFriendGroupBody(name: name, sortOrder: nil), idempotency: true, auth: true, ok: [200])
    }

    /// `DELETE /v1/friend-groups/{groupId}` → 200. Friends stay friends and become ungrouped.
    func deleteFriendGroup(id: String) async throws -> FriendGroup {
        try await send(method: "DELETE", path: "/friend-groups/\(path(id))", body: nil, idempotency: true, auth: true, ok: [200])
    }

    /// `GET /v1/chats?task_id=`. This is the only chat list. It returns task chats, not direct or group chats.
    func listTaskChats(taskId: String) async throws -> ChatList {
        let items = [URLQueryItem(name: "task_id", value: taskId)]
        return try await send(method: "GET", path: "/chats", query: items, body: nil, idempotency: false, auth: true, ok: [200])
    }

    /// `GET /v1/chats/{chatId}`
    func getChat(id: String) async throws -> Chat {
        try await send(method: "GET", path: "/chats/\(path(id))", body: nil, idempotency: false, auth: true, ok: [200])
    }

    /// `POST /v1/chats` `{type: direct, user_id}` → 201, including when the pair already has a thread.
    func openDirectChat(userId: String) async throws -> Chat {
        try await send(method: "POST", path: "/chats", body: DirectChatBody(userId: userId), idempotency: true, auth: true, ok: [201])
    }

    /// `GET /v1/chats/{chatId}/messages`. Each page is oldest first; `cursor` walks forward.
    func listMessages(chatId: String, limit: Int = 100, cursor: String? = nil) async throws -> MessageList {
        var items = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor, !cursor.isEmpty {
            items.append(URLQueryItem(name: "cursor", value: cursor))
        }
        return try await send(method: "GET", path: "/chats/\(path(chatId))/messages", query: items, body: nil, idempotency: false, auth: true, ok: [200])
    }

    /// Walks oldest-first pages, matching the web client cap of 20 × 100.
    func messageHistory(chatId: String) async throws -> (messages: [Message], truncated: Bool) {
        var messages: [Message] = []
        var cursor: String?
        var truncated = false
        let maxPages = 20
        for page in 0..<maxPages {
            let list = try await listMessages(chatId: chatId, limit: 100, cursor: cursor)
            messages.append(contentsOf: list.items)
            guard let next = list.nextCursor, !next.isEmpty else {
                truncated = false
                break
            }
            cursor = next
            truncated = page == maxPages - 1
        }
        return (messages, truncated)
    }

    /// `POST /v1/chats/{chatId}/messages` → 201. `type` is `text` or `sticker`.
    func postMessage(chatId: String, type: String, text: String) async throws -> Message {
        try await send(
            method: "POST",
            path: "/chats/\(path(chatId))/messages",
            body: MessageCreateBody(type: type, text: text),
            idempotency: true,
            auth: true,
            ok: [201]
        )
    }

    /// `POST /v1/chats/{chatId}/read`. Omit `messageId` to cover the newest message.
    /// Does not emit a webhook. A repeated Idempotency-Key would replay and miss later messages, so the key is always new.
    func markRead(chatId: String, messageId: String?) async throws -> ChatRead {
        try await send(
            method: "POST",
            path: "/chats/\(path(chatId))/read",
            body: MarkChatReadBody(messageId: messageId),
            idempotency: true,
            auth: true,
            ok: [200]
        )
    }

    private struct EmptyBody: Encodable {}

    private func path(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }

    private func send<Response: Decodable>(
        method: String,
        path: String = "",
        url: URL? = nil,
        query: [URLQueryItem] = [],
        body: (any Encodable)? = nil,
        idempotency: Bool,
        auth: Bool,
        ok: Set<Int>
    ) async throws -> Response {
        let target: URL
        if let url {
            target = url
        } else {
            guard var components = URLComponents(string: urls.apiBase + path) else {
                throw ClientError.badResponse("地址无法拼接。")
            }
            if !query.isEmpty { components.queryItems = query }
            guard let built = components.url else {
                throw ClientError.badResponse("地址无法拼接。")
            }
            target = built
        }
        return try await perform(method: method, url: target, body: body, idempotency: idempotency, auth: auth, ok: ok)
    }

    private func perform<Response: Decodable>(
        method: String,
        url: URL,
        body: (any Encodable)?,
        idempotency: Bool,
        auth: Bool,
        ok: Set<Int>
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if auth, let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if idempotency {
            request.setValue(Idempotency.key(method.lowercased()), forHTTPHeaderField: "Idempotency-Key")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(AnyEncodable(body))
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            if error.code == .cancelled { throw error }
            throw ClientError.transport(APIErrorText.transport(error, baseURL: urls.origin))
        }
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.badResponse("服务器没有返回 HTTP 响应。")
        }
        if !ok.contains(http.statusCode) {
            throw ClientError.api(Self.failure(status: http.statusCode, data: data))
        }
        if data.isEmpty {
            throw ClientError.badResponse("服务器返回了空响应。")
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw ClientError.badResponse("响应无法解析。")
        }
    }

    private static func failure(status: Int, data: Data) -> APIFailure {
        if let body = try? JSONDecoder().decode(APIErrorBody.self, from: data) {
            return APIFailure(status: status, code: body.code, message: body.message)
        }
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let message = text.isEmpty ? "HTTP \(status)" : String(text.prefix(500))
        return APIFailure(status: status, code: "http_error", message: message)
    }
}

private struct AnyEncodable: Encodable {
    var value: any Encodable
    init(_ value: any Encodable) { self.value = value }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}
