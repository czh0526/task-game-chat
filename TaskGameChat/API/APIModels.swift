import Foundation

/// JSON shapes for the chat surface of Task Game Open Protocol 0.1.0.
/// Field names match `api/openapi.yaml` at `563503d3579f413285291a657dafbbfbd4f37c63`.
/// The browser SSE channel is not part of that document; see `StreamSignal`.

struct APIErrorBody: Decodable, Sendable {
    var code: String
    var message: String
}

struct AuthSession: Decodable, Sendable {
    var accessToken: String
    var expiresIn: Int
    var user: UserSummary

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case user
    }
}

struct UserSummary: Decodable, Sendable, Equatable {
    var id: String
    var email: String
    var nickname: String
    var isArbiter: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case nickname
        case isArbiter = "is_arbiter"
    }

    init(id: String, email: String, nickname: String, isArbiter: Bool) {
        self.id = id
        self.email = email
        self.nickname = nickname
        self.isArbiter = isArbiter
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        email = try container.decodeIfPresent(String.self, forKey: .email) ?? ""
        nickname = try container.decodeIfPresent(String.self, forKey: .nickname) ?? ""
        isArbiter = try container.decodeIfPresent(Bool.self, forKey: .isArbiter) ?? false
    }
}

struct AvatarSummary: Decodable, Sendable {
    var userId: String
    var avatarURL: String
    var width: Int
    var height: Int
    var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case avatarURL = "avatar_url"
        case width
        case height
        case updatedAt = "updated_at"
    }
}

struct UserScores: Decodable, Sendable {
    var userId: String
    var nickname: String
    var integrity: Int
    var ability: Int

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case nickname
        case integrity
        case ability
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userId = try container.decode(String.self, forKey: .userId)
        nickname = try container.decodeIfPresent(String.self, forKey: .nickname) ?? ""
        integrity = try container.decodeIfPresent(Int.self, forKey: .integrity) ?? 0
        ability = try container.decodeIfPresent(Int.self, forKey: .ability) ?? 0
    }
}

struct HealthStatus: Decodable, Sendable {
    var status: String
}

struct Friend: Decodable, Identifiable, Sendable, Hashable {
    var userId: String
    var nickname: String
    var integrity: Int
    var ability: Int
    var since: String
    var unreadCount: Int
    var directChatId: String?

    var id: String { userId }

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case nickname
        case integrity
        case ability
        case since
        case unreadCount = "unread_count"
        case directChatId = "direct_chat_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userId = try container.decode(String.self, forKey: .userId)
        nickname = try container.decodeIfPresent(String.self, forKey: .nickname) ?? ""
        integrity = try container.decodeIfPresent(Int.self, forKey: .integrity) ?? 0
        ability = try container.decodeIfPresent(Int.self, forKey: .ability) ?? 0
        since = try container.decodeIfPresent(String.self, forKey: .since) ?? ""
        unreadCount = try container.decodeIfPresent(Int.self, forKey: .unreadCount) ?? 0
        directChatId = try container.decodeIfPresent(String.self, forKey: .directChatId)
    }
}

struct FriendGroupWithFriends: Decodable, Identifiable, Sendable {
    var id: String
    var name: String
    var sortOrder: Int
    var friends: [Friend]

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case sortOrder = "sort_order"
        case friends
    }
}

struct FriendList: Decodable, Sendable {
    var groups: [FriendGroupWithFriends]
    var ungrouped: [Friend]

    var everyone: [Friend] {
        groups.flatMap(\.friends) + ungrouped
    }
}

struct FriendGroup: Decodable, Identifiable, Sendable {
    var id: String
    var name: String
    var sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case sortOrder = "sort_order"
    }
}

struct FriendRequest: Decodable, Identifiable, Sendable {
    var id: String
    var fromUserId: String
    var toUserId: String
    var fromNickname: String
    var toNickname: String
    var status: String
    var createdAt: String
    var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case fromUserId = "from_user_id"
        case toUserId = "to_user_id"
        case fromNickname = "from_nickname"
        case toNickname = "to_nickname"
        case status
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        fromUserId = try container.decode(String.self, forKey: .fromUserId)
        toUserId = try container.decode(String.self, forKey: .toUserId)
        fromNickname = try container.decodeIfPresent(String.self, forKey: .fromNickname) ?? ""
        toNickname = try container.decodeIfPresent(String.self, forKey: .toNickname) ?? ""
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? ""
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
    }
}

struct FriendRequestList: Decodable, Sendable {
    var items: [FriendRequest]
}

struct FriendPlacement: Decodable, Sendable {
    var userId: String
    var groupId: String?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case groupId = "group_id"
    }
}

struct RemovedFriend: Decodable, Sendable {
    var userId: String

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
    }
}

struct Chat: Decodable, Identifiable, Sendable, Hashable {
    var id: String
    var type: String
    var taskId: String?
    var memberIds: [String]

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case taskId = "task_id"
        case memberIds = "member_ids"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? "group"
        taskId = try container.decodeIfPresent(String.self, forKey: .taskId)
        memberIds = try container.decodeIfPresent([String].self, forKey: .memberIds) ?? []
    }
}

struct ChatList: Decodable, Sendable {
    var items: [Chat]
}

struct Message: Decodable, Identifiable, Sendable, Hashable {
    var id: String
    var chatId: String
    var senderId: String
    var type: String
    var text: String
    var attachmentRef: String
    var createdAt: String

    init(
        id: String,
        chatId: String,
        senderId: String,
        type: String,
        text: String,
        attachmentRef: String,
        createdAt: String
    ) {
        self.id = id
        self.chatId = chatId
        self.senderId = senderId
        self.type = type
        self.text = text
        self.attachmentRef = attachmentRef
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case chatId = "chat_id"
        case senderId = "sender_id"
        case type
        case text
        case attachmentRef = "attachment_ref"
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        chatId = try container.decodeIfPresent(String.self, forKey: .chatId) ?? ""
        senderId = try container.decodeIfPresent(String.self, forKey: .senderId) ?? ""
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? "text"
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        attachmentRef = try container.decodeIfPresent(String.self, forKey: .attachmentRef) ?? ""
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
    }
}

struct MessageList: Decodable, Sendable {
    var items: [Message]
    var nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case items
        case nextCursor = "next_cursor"
    }
}

/// One full oldest-first walk of a thread, plus the cursor a live update should reuse.
struct MessageHistory: Sendable {
    var messages: [Message]
    var truncated: Bool
    /// Pass this to the next tail read. `nil` re-reads the first page.
    /// When the walk stopped early, this is the first page that was not loaded.
    var tailCursor: String?
}

struct ChatRead: Decodable, Sendable {
    var chatId: String
    var unreadCount: Int
    var readThroughMessageId: String?

    enum CodingKeys: String, CodingKey {
        case chatId = "chat_id"
        case unreadCount = "unread_count"
        case readThroughMessageId = "read_through_message_id"
    }
}

/// Frame payload from `GET /v1/events/stream`. Ids only; the body is fetched with REST.
struct StreamSignal: Decodable, Sendable, Equatable {
    var type: String
    var chatId: String?
    var messageId: String?
    var senderId: String?

    enum CodingKeys: String, CodingKey {
        case type
        case chatId = "chat_id"
        case messageId = "message_id"
        case senderId = "sender_id"
    }
}

struct RegisterBody: Encodable {
    var email: String
    var password: String
    var nickname: String?

    enum CodingKeys: String, CodingKey {
        case email
        case password
        case nickname
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(email, forKey: .email)
        try container.encode(password, forKey: .password)
        if let nickname, !nickname.isEmpty {
            try container.encode(nickname, forKey: .nickname)
        }
    }
}

struct PasswordBody: Encodable {
    var email: String
    var password: String
}

struct ProfileUpdateBody: Encodable {
    var nickname: String
}

struct AvatarUploadBody: Encodable {
    var image: String
}

struct CreateFriendRequestBody: Encodable {
    var userId: String

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
    }
}

struct CreateFriendGroupBody: Encodable {
    var name: String
}

struct PatchFriendGroupBody: Encodable {
    var name: String?
    var sortOrder: Int?

    enum CodingKeys: String, CodingKey {
        case name
        case sortOrder = "sort_order"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(sortOrder, forKey: .sortOrder)
    }
}

struct SetFriendGroupBody: Encodable {
    var groupId: String?

    enum CodingKeys: String, CodingKey {
        case groupId = "group_id"
    }

    /// `null` moves the friend back to the ungrouped bucket. Omitting the key would also do that;
    /// the explicit null matches the OpenAPI description.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(groupId, forKey: .groupId)
    }
}

struct DirectChatBody: Encodable {
    var type: String = "direct"
    var userId: String

    enum CodingKeys: String, CodingKey {
        case type
        case userId = "user_id"
    }
}

struct MessageCreateBody: Encodable {
    var type: String
    var text: String
}

struct MarkChatReadBody: Encodable {
    var messageId: String?

    enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let messageId, !messageId.isEmpty {
            try container.encode(messageId, forKey: .messageId)
        }
    }
}
