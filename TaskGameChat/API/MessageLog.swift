import Foundation

/// List operations for the open conversation.
/// A slow history snapshot must not drop a row that was just sent, or one a newer tail read already showed.
enum MessageLog {
    static let localPrefix = "local-"

    static func isLocal(_ id: String) -> Bool {
        id.hasPrefix(localPrefix)
    }

    /// Full-history replace that keeps rows the snapshot has not caught up with, in their current order.
    static func applying(snapshot: [Message], keeping existing: [Message]) -> [Message] {
        var seen = Set(snapshot.map(\.id))
        var merged = snapshot
        for message in existing where seen.insert(message.id).inserted {
            merged.append(message)
        }
        return merged
    }

    /// Insert or refresh rows from one page. Known ids stay where they are.
    static func upserting(_ incoming: [Message], into existing: [Message]) -> [Message] {
        var merged = existing
        var index: [String: Int] = [:]
        index.reserveCapacity(merged.count)
        for (offset, message) in merged.enumerated() {
            index[message.id] = offset
        }
        for message in incoming {
            if let at = index[message.id] {
                merged[at] = message
            } else {
                index[message.id] = merged.count
                merged.append(message)
            }
        }
        return merged
    }

    /// Swap a pending local row for the server message without moving its neighbors.
    static func replacing(localID: String, with server: Message, in existing: [Message]) -> [Message] {
        var merged: [Message] = []
        merged.reserveCapacity(existing.count)
        var inserted = false
        for message in existing {
            if message.id == server.id || message.id == localID {
                if !inserted {
                    merged.append(server)
                    inserted = true
                }
                continue
            }
            merged.append(message)
        }
        if !inserted {
            merged.append(server)
        }
        return merged
    }
}

enum MessageCursor {
    /// Cursor the next tail read should pass to `listMessages` after this page.
    /// A page that still has a follower resumes there. The last page resumes at the cursor that re-reads it.
    static func resume(requested: String?, next: String?) -> String? {
        if let next, !next.isEmpty { return next }
        return requested
    }

    /// Folds oldest-first pages the same way `APIClient.messageHistory` does, capped at 20.
    static func fold(_ pages: [MessageList]) -> MessageHistory {
        var messages: [Message] = []
        var cursor: String?
        var requested: String?
        var truncated = false
        var lastNext: String?
        let maxPages = 20
        for (index, page) in pages.prefix(maxPages).enumerated() {
            requested = cursor
            messages.append(contentsOf: page.items)
            lastNext = page.nextCursor
            guard let next = page.nextCursor, !next.isEmpty else {
                truncated = false
                break
            }
            cursor = next
            truncated = index == maxPages - 1
            if truncated { break }
        }
        return MessageHistory(
            messages: messages,
            truncated: truncated,
            tailCursor: resume(requested: requested, next: truncated ? lastNext : nil)
        )
    }
}
