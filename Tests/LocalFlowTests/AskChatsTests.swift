import Foundation
import Testing
@testable import LocalFlow

@Suite("Ask: chat log")
struct AskChatLogTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func minutes(_ count: Double) -> Date { start.addingTimeInterval(count * 60) }

    @Test("the first question starts a chat named after it")
    func firstQuestionStartsChat() {
        let log = AskChatLog().recording(question: "What's this slide?", answer: "Nash equilibrium.", at: start)

        #expect(log.chats.count == 1)
        #expect(log.chats[0].title == "What's this slide?")
        #expect(log.currentChat(at: minutes(1))?.id == log.chats[0].id)
    }

    @Test("a follow-up within half an hour joins the same chat")
    func followUpJoins() {
        let log = AskChatLog()
            .recording(question: "What's this slide?", answer: "Nash equilibrium.", at: start)
            .recording(question: "Give me an example", answer: "Prisoner's dilemma.", at: minutes(29))

        #expect(log.chats.count == 1)
        #expect(log.chats[0].turns.map(\.question) == ["What's this slide?", "Give me an example"])
    }

    @Test("a question after half an hour quiet starts a new chat, newest first")
    func idleStartsNewChat() {
        let log = AskChatLog()
            .recording(question: "What's this slide?", answer: "Nash equilibrium.", at: start)
            .recording(question: "Fix this error", answer: "Restart Ollama.", at: minutes(31))

        #expect(log.chats.map(\.title) == ["Fix this error", "What's this slide?"])
        #expect(log.currentChat(at: minutes(32))?.title == "Fix this error")
    }

    @Test("New Chat makes the next question its own chat")
    func newChat() {
        let log = AskChatLog()
            .recording(question: "One?", answer: "1", at: start)
            .startingNewChat()
            .recording(question: "Two?", answer: "2", at: minutes(1))

        #expect(log.chats.map(\.title) == ["Two?", "One?"])
    }

    @Test("continuing an old chat puts the next question in it and moves it to the top")
    func continueOldChat() throws {
        let first = AskChatLog()
            .recording(question: "Old chat?", answer: "Old.", at: start)
            .recording(question: "Newer chat?", answer: "Newer.", at: minutes(60))
        let old = try #require(first.chats.last)

        let log = first
            .continuing(old.id, at: minutes(600))
            .recording(question: "Back to it", answer: "Sure.", at: minutes(610))

        #expect(log.chats.map(\.title) == ["Old chat?", "Newer chat?"])
        #expect(log.chats[0].turns.map(\.question) == ["Old chat?", "Back to it"])
    }

    @Test("memory is the last N turns of the current chat only")
    func memoryIsCurrentChat() {
        let log = AskChatLog()
            .recording(question: "Other chat", answer: "x", at: start)
            .startingNewChat()
            .recording(question: "One?", answer: "1", at: minutes(1))
            .recording(question: "Two?", answer: "2", at: minutes(2))
            .recording(question: "Three?", answer: "3", at: minutes(3))

        #expect(log.memory(at: minutes(4), limit: 2) == [AskTurn(question: "Two?", answer: "2"),
                                                         AskTurn(question: "Three?", answer: "3")])
        #expect(log.memory(at: minutes(4), limit: 0).isEmpty)
        // Half an hour quiet: the next question starts fresh, so it remembers nothing.
        #expect(log.memory(at: minutes(40), limit: 5).isEmpty)
    }

    @Test("an answer kept out of memory still goes in the log, as its own chat")
    func outsideMemory() {
        let log = AskChatLog()
            .recording(question: "One?", answer: "1", at: start)
            .startingNewChat()
            .recording(question: "Still typing", answer: "done", at: minutes(1), joinsConversation: false)

        #expect(log.chats.map(\.title) == ["Still typing", "One?"])
        #expect(log.currentChat(at: minutes(2)) == nil)
    }

    @Test("deleting a chat removes it, and the current one stops being current")
    func delete() throws {
        let log = AskChatLog()
            .recording(question: "Keep", answer: "k", at: start)
            .startingNewChat()
            .recording(question: "Drop", answer: "d", at: minutes(1))
        let dropped = try #require(log.chats.first)

        let after = log.deleting(dropped.id)

        #expect(after.chats.map(\.title) == ["Keep"])
        #expect(after.currentChat(at: minutes(2)) == nil)
    }

    @Test("the oldest chats go once there are too many")
    func cap() {
        var log = AskChatLog()
        for index in 0..<(AskChatLog.maxChats + 3) {
            log = log.startingNewChat().recording(question: "Q\(index)", answer: "A", at: minutes(Double(index)))
        }

        #expect(log.chats.count == AskChatLog.maxChats)
        #expect(log.chats.last?.title == "Q3")
    }
}

@Suite("Ask: chat search and groups")
struct AskChatSearchTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func chat(_ question: String, _ answer: String, daysAgo: Double = 0) -> AskChat {
        AskChat(id: UUID(), turns: [AskChatTurn(question: question, answer: answer,
                                                askedAt: now.addingTimeInterval(-daysAgo * 86_400))])
    }

    @Test("every word must appear somewhere in the chat, any case, any order, accents ignored")
    func search() {
        let chats = [chat("Why is Ollama down?", "Run brew services restart ollama."),
                     chat("What's on this slide?", "A café menu with prices."),
                     chat("Résumé tips", "Keep it to one page.")]

        #expect(AskChatSearch.matching(chats, query: "restart OLLAMA").map(\.title) == ["Why is Ollama down?"])
        #expect(AskChatSearch.matching(chats, query: "cafe").map(\.title) == ["What's on this slide?"])
        #expect(AskChatSearch.matching(chats, query: "resume page").map(\.title) == ["Résumé tips"])
        #expect(AskChatSearch.matching(chats, query: "ollama café").isEmpty)
        #expect(AskChatSearch.matching(chats, query: "  ").count == 3)
    }

    @Test("a match shows a snippet around the first hit")
    func snippet() {
        let long = String(repeating: "filler words ", count: 20) + "the dominant strategy is Bottom" + String(repeating: " more", count: 20)
        let found = chat("Game theory", long)

        let snippet = AskChatSearch.snippet(in: found, query: "dominant")

        #expect(snippet?.contains("dominant strategy") == true)
        #expect((snippet?.count ?? 0) <= AskChatSearch.snippetLength + 2)
        #expect(AskChatSearch.snippet(in: found, query: "") == nil)
    }

    @Test("chats out of order still give one section per day name")
    func groupsMerge() {
        let chats = [chat("today", "", daysAgo: 0), chat("long ago", "", daysAgo: 90), chat("also today", "", daysAgo: 0)]

        let groups = AskChatGroups.grouped(chats, now: now)

        #expect(groups.map { $0.chats.map(\.title) } == [["today", "also today"], ["long ago"]])
    }

    @Test("chats group into Today, Yesterday, the last week, the last month, then by month")
    func groups() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let chats = [chat("today", "", daysAgo: 0), chat("yesterday", "", daysAgo: 1),
                     chat("this week", "", daysAgo: 4), chat("this month", "", daysAgo: 20),
                     chat("long ago", "", daysAgo: 90)]

        let groups = AskChatGroups.grouped(chats, now: now, calendar: calendar)

        #expect(groups.map(\.title).prefix(4) == ["Today", "Yesterday", "Previous 7 Days", "Previous 30 Days"])
        #expect(groups.count == 5)
        #expect(groups.map { $0.chats.map(\.title) } == [["today"], ["yesterday"], ["this week"], ["this month"], ["long ago"]])
    }
}

@MainActor
@Suite("Ask: chat store on disk")
struct AskChatStoreTests {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("localflow-chats-\(UUID())", isDirectory: true)
            .appendingPathComponent("ask-chats.json")
    }

    @Test("chats and the current chat come back after a restart, in a file only you can read")
    func roundTrip() throws {
        let file = tempFile()
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let store = AskChatStore(fileURL: file, now: { clock })

        store.record(question: "What's this?", answer: "A slide.")
        store.flush()
        clock.addTimeInterval(60)
        let reopened = AskChatStore(fileURL: file, now: { clock })

        #expect(reopened.log == store.log)
        #expect(reopened.memory(limit: 5) == [AskTurn(question: "What's this?", answer: "A slide.")])
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test("a damaged file is set aside, not overwritten, and the log starts empty")
    func corruptFile() throws {
        let file = tempFile()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file)

        let store = AskChatStore(fileURL: file)

        #expect(store.log.chats.isEmpty)
        let aside = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
        #expect(aside.contains { $0.hasPrefix("ask-chats.damaged-") })
    }

    @Test("a file that can't be read is never overwritten")
    func unreadableFile() throws {
        let file = tempFile()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"chats\":[]}".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }

        let store = AskChatStore(fileURL: file)
        store.record(question: "Hi?", answer: "Hello.")
        store.flush()

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #expect(try String(contentsOf: file, encoding: .utf8) == "{\"chats\":[]}")
        #expect(store.log.chats.count == 1) // still works for this session, in memory
    }

    @Test("the folder is private too")
    func privateFolder() throws {
        let file = tempFile()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        let store = AskChatStore(fileURL: file)

        store.record(question: "Hi?", answer: "Hello.")
        store.flush()

        let folder = try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)
        #expect(folder[.posixPermissions] as? Int == 0o700)
    }

    @Test("without a file the log lives in memory only")
    func inMemory() {
        let store = AskChatStore(fileURL: nil)

        store.record(question: "Hi?", answer: "Hello.")

        #expect(store.log.chats.count == 1)
    }
}

@Suite("Ask: chat text")
struct AskChatTextTests {
    @Test("Copy Chat gives every question and answer in order")
    func transcript() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let chat = AskChat(id: UUID(), turns: [AskChatTurn(question: "What's this?", answer: "A slide.", askedAt: at),
                                               AskChatTurn(question: "Example?", answer: "Prisoner's dilemma.", askedAt: at)])

        #expect(AskChatText.transcript(chat) == "Q: What's this?\n\nA slide.\n\nQ: Example?\n\nPrisoner's dilemma.")
    }

    @Test("the list says how many questions a chat has")
    func subtitle() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let one = AskChat(id: UUID(), turns: [AskChatTurn(question: "Q", answer: "A", askedAt: at)])
        let two = one.adding(AskChatTurn(question: "Q2", answer: "A2", askedAt: at))

        #expect(AskChatText.subtitle(one).hasSuffix("· 1 question"))
        #expect(AskChatText.subtitle(two).hasSuffix("· 2 questions"))
    }
}
