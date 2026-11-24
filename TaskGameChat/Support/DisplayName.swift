import Foundation

/// Display names follow the official web client at this commit (`web/src/person.ts`).
/// A nickname is shown on its own. The older `昵称(...后6位)` form is no longer used.
/// Without a nickname the label is `...` plus the last 6 characters of the user id.
enum DisplayName {
    static func idSuffix(_ userId: String) -> String {
        if userId.isEmpty { return "" }
        if userId.count <= 6 { return userId }
        return String(userId.suffix(6))
    }

    static func personLabel(nickname: String?, userId: String) -> String {
        let name = nickname?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !name.isEmpty { return name }
        let suffix = idSuffix(userId)
        return suffix.isEmpty ? "未命名" : "...\(suffix)"
    }

    static func nicknameError(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "请填写昵称。去掉空白后不能为空。" }
        if name.unicodeScalars.count > 32 { return "昵称最长 32 个字符。" }
        if name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0.value == 127 }) {
            return "昵称不能包含控制字符。"
        }
        return nil
    }

    /// Server rule: trim, lowercase, ASCII address, no `..`, at most 254 characters.
    static func normalizedEmail(_ raw: String) -> String? {
        let email = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !email.isEmpty, email.count <= 254, !email.contains("..") else { return nil }
        let pattern = #"^[a-z0-9._%+\-]+@[a-z0-9](?:[a-z0-9\-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9\-]*[a-z0-9])?)+$"#
        guard email.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return email
    }

    /// Server rule: at least 8 Unicode scalars, at most 72 UTF-8 bytes. The password is not trimmed.
    static func passwordError(_ password: String) -> String? {
        if password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "请填写密码。"
        }
        if password.unicodeScalars.count < 8 {
            return "密码至少 8 个字符。"
        }
        if password.utf8.count > 72 {
            return "密码最长 72 字节。"
        }
        return nil
    }
}

enum ChatTime {
    static func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func format(_ raw: String) -> String {
        guard let date = parse(raw) else { return raw }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.setLocalizedDateFormatFromTemplate("yMMMdHm")
        return formatter.string(from: date)
    }

    static func parse(_ raw: String) -> Date? {
        if raw.isEmpty { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}

enum ChatKind {
    static func label(_ type: String) -> String {
        switch type {
        case "direct": return "一对一"
        case "task": return "任务会话"
        case "group": return "多人会话"
        default: return "会话"
        }
    }
}
