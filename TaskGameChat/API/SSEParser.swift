import Foundation

struct SSEFrame: Equatable, Sendable {
    var id: String
    var event: String
    var data: String
}

/// Incremental parser for the LF frames emitted by `internal/handler/events/streamHandler.go`.
/// Comment heartbeats (`: ping`) have no data field and are dropped. CRLF is accepted.
struct SSEParser {
    private var buffer = ""

    mutating func append(_ chunk: String) -> [SSEFrame] {
        buffer += chunk
        let text = buffer.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var parts = text.components(separatedBy: "\n\n")
        buffer = parts.popLast() ?? ""
        return parts.compactMap(Self.parseBlock)
    }

    static func parseBlock(_ block: String) -> SSEFrame? {
        var id = ""
        var event = ""
        var data: [String] = []
        for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
            let raw = String(line)
            if raw.isEmpty || raw.hasPrefix(":") { continue }
            let field: String
            let value: String
            if let colon = raw.firstIndex(of: ":") {
                field = String(raw[..<colon])
                var rest = String(raw[raw.index(after: colon)...])
                if rest.hasPrefix(" ") { rest.removeFirst() }
                value = rest
            } else {
                field = raw
                value = ""
            }
            switch field {
            case "id":
                id = value
            case "event":
                event = value
            case "data":
                data.append(value)
            default:
                break
            }
        }
        guard !data.isEmpty else { return nil }
        return SSEFrame(id: id, event: event, data: data.joined(separator: "\n"))
    }
}
