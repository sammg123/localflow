/// One step of typing: a run of text posted as one key event, or a Return press.
enum TypingChunk: Equatable, Sendable {
    case text(String)
    case returnKey
}

/// Splits text for typing. A key event carries at most 20 UTF-16 units, and a
/// character (an emoji, an accented letter) is never cut in half.
enum TypingChunks {
    static let maxUnits = 20

    static func split(_ text: String, maxUnits: Int = maxUnits) -> [TypingChunk] {
        var chunks: [TypingChunk] = []
        var pending = ""
        for character in text {
            if character.isNewline {
                if !pending.isEmpty { chunks.append(.text(pending)) }
                pending = ""
                chunks.append(.returnKey)
                continue
            }
            if !pending.isEmpty, pending.utf16.count + character.utf16.count > maxUnits {
                chunks.append(.text(pending))
                pending = ""
            }
            pending.append(character)
        }
        if !pending.isEmpty { chunks.append(.text(pending)) }
        return chunks
    }
}
