import SwiftUI

enum Theme {
    static let paper = Color(red: 0.965, green: 0.945, blue: 0.910)
    static let ink = Color(red: 0.110, green: 0.098, blue: 0.082)
    static let persimmon = Color(red: 0.886, green: 0.357, blue: 0.165)
    static let pine = Color(red: 0.122, green: 0.420, blue: 0.290)
    static let card = Color(red: 1, green: 0.988, blue: 0.969)
    static let mist = Color(red: 0.91, green: 0.88, blue: 0.83)
}

struct NoticeBanner: View {
    var message: String?

    var body: some View {
        if let message, !message.isEmpty {
            Text(message)
                .font(.footnote)
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Theme.persimmon.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

struct UnreadBadge: View {
    var count: Int

    var body: some View {
        if count > 0 {
            Text(count > 99 ? "99+" : "\(count)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Theme.persimmon, in: Capsule())
                .accessibilityLabel("\(count) 条未读")
        }
    }
}

struct UserAvatar: View {
    var userId: String
    var name: String
    var baseURL: String
    var version: Int
    var size: CGFloat = 40

    var body: some View {
        Group {
            if let url = avatarURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    private var avatarURL: URL? {
        guard !userId.isEmpty, let urls = try? ServiceURLs.resolve(baseURL) else { return nil }
        guard let encoded = userId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        var string = "\(urls.apiBase)/users/\(encoded)/avatar"
        if version > 0 { string += "?v=\(version)" }
        return URL(string: string)
    }

    private var placeholder: some View {
        Text(initial)
            .font(.system(size: size * 0.38, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(color)
    }

    private var initial: String {
        let chars = Array(name.trimmingCharacters(in: .whitespacesAndNewlines))
        if let first = chars.first { return String(first).uppercased() }
        return "?"
    }

    private var color: Color {
        let palette: [Color] = [
            Color(red: 0.357, green: 0.561, blue: 0.976),
            Color(red: 0.380, green: 0.867, blue: 0.667),
            Color(red: 0.396, green: 0.471, blue: 0.608),
            Color(red: 0.965, green: 0.741, blue: 0.086),
            Color(red: 0.447, green: 0.384, blue: 0.992),
            Color(red: 0.471, green: 0.827, blue: 0.973),
            Color(red: 0.588, green: 0.380, blue: 0.737),
            Color(red: 0.941, green: 0.561, blue: 0.337),
        ]
        var hash = 0
        for scalar in userId.unicodeScalars {
            hash = hash &* 31 &+ Int(scalar.value)
        }
        let index = Int(UInt(bitPattern: hash) % UInt(palette.count))
        return palette[index]
    }
}

struct StreamDot: View {
    var phase: StreamPhase

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch phase {
        case .live: return Theme.pine
        case .connecting, .reconnecting: return Theme.persimmon
        case .idle: return .secondary
        }
    }

    private var label: String {
        switch phase {
        case .live: return "实时"
        case .connecting: return "连接中"
        case .reconnecting: return "重连中"
        case .idle: return "未连接"
        }
    }
}

struct EmptyHint: View {
    var title: String
    var detail: String
    var systemImage: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(detail)
        }
    }
}
