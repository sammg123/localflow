import AppKit

/// One question and its finished answer, as kept in the chat log.
struct AskChatTurn: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    let question: String
    let answer: String
    let askedAt: Date
}

/// A conversation with Ask: questions asked close together, or picked back up on purpose.
struct AskChat: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let turns: [AskChatTurn]

    var title: String { turns.first?.question ?? "" }
    var updatedAt: Date { turns.last?.askedAt ?? .distantPast }

    func adding(_ turn: AskChatTurn) -> AskChat {
        AskChat(id: id, turns: turns + [turn])
    }
}

/// Every chat Ask has had, newest activity first, and which one the next question joins.
/// Values only: each change returns a new log.
struct AskChatLog: Codable, Equatable, Sendable {
    /// A chat quiet this long is over; the next question starts a new one, so an
    /// unrelated question doesn't drag in old context.
    static let conversationGap: TimeInterval = 30 * 60
    /// Oldest chats go past this, so the file stays small.
    static let maxChats = 2_000

    private(set) var chats: [AskChat] = []
    private(set) var currentID: UUID?
    /// When a chat was picked back up from the history, which restarts its quiet clock.
    private(set) var resumedAt: Date?

    /// The chat the next question joins, if it hasn't gone quiet.
    func currentChat(at now: Date) -> AskChat? {
        guard let currentID, let chat = chats.first(where: { $0.id == currentID }) else { return nil }
        let lastActive = max(chat.updatedAt, resumedAt ?? .distantPast)
        return now.timeIntervalSince(lastActive) < Self.conversationGap ? chat : nil
    }

    /// What the model is shown for a follow-up: the current chat's last `limit` turns.
    func memory(at now: Date, limit: Int) -> [AskTurn] {
        guard limit > 0, let chat = currentChat(at: now) else { return [] }
        return chat.turns.suffix(limit).map { AskTurn(question: $0.question, answer: $0.answer) }
    }

    /// Adds a finished answer to the current chat, or as a new one.
    func recording(question: String, answer: String, at now: Date, joinsConversation: Bool = true) -> AskChatLog {
        recording(question: question, answer: answer, at: now, in: currentChat(at: now)?.id,
                  joinsConversation: joinsConversation)
    }

    /// Adds a finished answer to the chat it was asked in (`chat`: the current one when
    /// the question was sent), even if another chat was picked up meanwhile. With no chat,
    /// it starts one, which becomes current unless another chat already has. Left out of
    /// the conversation (`joinsConversation` false), it's logged as a chat of its own.
    func recording(question: String, answer: String, at now: Date, in chat: UUID?,
                   joinsConversation: Bool = true) -> AskChatLog {
        let turn = AskChatTurn(question: question, answer: answer, askedAt: now)
        var next = self
        if joinsConversation, let chat, let existing = chats.first(where: { $0.id == chat }) {
            next.chats = [existing.adding(turn)] + chats.filter { $0.id != chat }
            if currentID == chat { next.resumedAt = nil }
            return next
        }
        let started = AskChat(id: UUID(), turns: [turn])
        next.chats = Array(([started] + chats).prefix(Self.maxChats))
        if joinsConversation, currentChat(at: now) == nil {
            next.currentID = started.id
            next.resumedAt = nil
        }
        return next
    }

    func startingNewChat() -> AskChatLog {
        var next = self
        next.currentID = nil
        next.resumedAt = nil
        return next
    }

    /// Picks an old chat back up: the next question joins it.
    func continuing(_ id: UUID, at now: Date) -> AskChatLog {
        guard chats.contains(where: { $0.id == id }) else { return self }
        var next = self
        next.currentID = id
        next.resumedAt = now
        return next
    }

    func deleting(_ id: UUID) -> AskChatLog {
        var next = self
        next.chats = chats.filter { $0.id != id }
        if currentID == id {
            next.currentID = nil
            next.resumedAt = nil
        }
        return next
    }
}

/// Finding chats by what was said in them.
enum AskChatSearch {
    /// Characters of answer shown around a hit in the list.
    static let snippetLength = 100
    private static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    static func words(_ query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Chats where every word of the query appears, in a question or an answer.
    static func matching(_ chats: [AskChat], query: String) -> [AskChat] {
        let words = words(query)
        guard !words.isEmpty else { return chats }
        return chats.filter { chat in
            words.allSatisfy { word in
                chat.turns.contains { $0.question.range(of: word, options: options) != nil
                    || $0.answer.range(of: word, options: options) != nil }
            }
        }
    }

    /// A line of text around the first word's first hit, on one line.
    static func snippet(in chat: AskChat, query: String) -> String? {
        guard let word = words(query).first else { return nil }
        for text in chat.turns.flatMap({ [$0.question, $0.answer] }) {
            guard let hit = text.range(of: word, options: options) else { continue }
            let lead = snippetLength / 3
            let start = text.index(hit.lowerBound, offsetBy: -lead, limitedBy: text.startIndex) ?? text.startIndex
            let end = text.index(start, offsetBy: snippetLength, limitedBy: text.endIndex) ?? text.endIndex
            let body = text[start..<end].split(whereSeparator: \.isNewline).joined(separator: " ")
            return (start > text.startIndex ? "…" : "") + body + (end < text.endIndex ? "…" : "")
        }
        return nil
    }
}

/// The history list's sections, by when each chat last had a question.
enum AskChatGroups {
    struct Group: Equatable, Identifiable {
        let title: String
        let chats: [AskChat]
        var id: String { title }
    }

    static func grouped(_ chats: [AskChat], now: Date = Date(), calendar: Calendar = .current) -> [Group] {
        let today = calendar.startOfDay(for: now)
        let month = DateFormatter()
        month.calendar = calendar
        month.timeZone = calendar.timeZone
        month.setLocalizedDateFormatFromTemplate("MMMM yyyy")

        func title(for date: Date) -> String {
            if calendar.isDate(date, inSameDayAs: now) { return "Today" }
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: today).day ?? 0
            if days == 1 { return "Yesterday" }
            if days <= 7 { return "Previous 7 Days" }
            if days <= 30 { return "Previous 30 Days" }
            return month.string(from: date)
        }

        // One section per name, in the order first seen (newest first).
        var order: [String] = []
        var members: [String: [AskChat]] = [:]
        for chat in chats {
            let name = title(for: chat.updatedAt)
            if members[name] == nil { order.append(name) }
            members[name, default: []].append(chat)
        }
        return order.map { Group(title: $0, chats: members[$0] ?? []) }
    }
}

/// A chat as plain text, for the clipboard and the history list.
enum AskChatText {
    static func transcript(_ chat: AskChat) -> String {
        chat.turns.map { "Q: \($0.question)\n\n\($0.answer)" }.joined(separator: "\n\n")
    }

    /// "3:42 PM · 2 questions" today, "Oct 24 · 1 question" before (the list's section
    /// headers already say which day).
    static func subtitle(_ chat: AskChat, now: Date = Date(), calendar: Calendar = .current) -> String {
        let count = chat.turns.count
        let date = chat.updatedAt
        let when = calendar.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.month(.abbreviated).day())
        return "\(when) · \(count) question\(count == 1 ? "" : "s")"
    }

    @MainActor
    static func copy(_ chat: AskChat) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcript(chat), forType: .string)
    }
}
