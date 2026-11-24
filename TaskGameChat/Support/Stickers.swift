import Foundation

struct EmojiSticker: Identifiable, Hashable {
    var char: String
    var label: String
    var id: String { char }
}

/// Same palette as `web/src/emojis.ts`. A sticker is `type: sticker` with the emoji in `text`.
enum Stickers {
    static let all: [EmojiSticker] = [
        .init(char: "😀", label: "笑"),
        .init(char: "😂", label: "笑哭"),
        .init(char: "🤣", label: "笑翻"),
        .init(char: "😊", label: "微笑"),
        .init(char: "😍", label: "喜欢"),
        .init(char: "😎", label: "酷"),
        .init(char: "🥳", label: "庆祝"),
        .init(char: "😭", label: "哭"),
        .init(char: "😡", label: "生气"),
        .init(char: "😱", label: "震惊"),
        .init(char: "🤔", label: "思考"),
        .init(char: "😴", label: "困"),
        .init(char: "👍", label: "赞"),
        .init(char: "👎", label: "踩"),
        .init(char: "👏", label: "鼓掌"),
        .init(char: "🙏", label: "谢谢"),
        .init(char: "💪", label: "加油"),
        .init(char: "🤝", label: "合作"),
        .init(char: "❤️", label: "爱心"),
        .init(char: "🔥", label: "火"),
        .init(char: "🎉", label: "恭喜"),
        .init(char: "💰", label: "钱"),
        .init(char: "✅", label: "完成"),
        .init(char: "❓", label: "疑问"),
    ]

    static func label(for text: String) -> String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return all.first { $0.char == value }?.label ?? text
    }

    /// A message that is exactly one built-in emoji is sent as a sticker. Anything else stays text.
    static func stickerChar(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return all.contains { $0.char == value } ? value : nil
    }
}

enum Idempotency {
    /// Fresh key on every call. Reusing a key replays the first response and, for read cursors,
    /// does not cover messages that arrived later. The server allows up to 200 characters.
    static func key(_ prefix: String) -> String {
        let raw = "\(prefix)-\(UUID().uuidString.lowercased())"
        if raw.count <= 200 { return raw }
        return String(raw.prefix(200))
    }
}
