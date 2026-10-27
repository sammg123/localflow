import Foundation

/// The Ask chat log, kept on disk so chats survive a restart and can be looked back
/// through and searched. Only your account can read the file; nothing from it goes in
/// the event log. Without a file (tests) it lives in memory only.
@MainActor
final class AskChatStore: ObservableObject {
    @Published private(set) var log: AskChatLog

    private let fileURL: URL?
    private let now: () -> Date
    /// Off when the file is there but couldn't be read: saving would wipe it.
    private let canSave: Bool
    /// Saves happen off the main thread, in order.
    private let writer = DispatchQueue(label: "io.github.sammg123.localflow.ask-chats", qos: .utility)

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalFlow", isDirectory: true)
            .appendingPathComponent("ask-chats.json")
    }

    init(fileURL: URL?, now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.now = now
        let loaded = fileURL.map(Self.load) ?? (log: AskChatLog(), canSave: true)
        log = loaded.log
        canSave = loaded.canSave
    }

    var currentChat: AskChat? { log.currentChat(at: now()) }

    func memory(limit: Int) -> [AskTurn] { log.memory(at: now(), limit: limit) }

    func record(question: String, answer: String, joinsConversation: Bool = true) {
        update(log.recording(question: question, answer: answer, at: now(), joinsConversation: joinsConversation))
    }

    /// Into the chat the question was asked in (see `AskChatLog.recording(...in:)`).
    func record(question: String, answer: String, in chat: UUID?, joinsConversation: Bool = true) {
        update(log.recording(question: question, answer: answer, at: now(), in: chat,
                             joinsConversation: joinsConversation))
    }

    func startNewChat() { update(log.startingNewChat()) }

    func continueChat(_ id: UUID) { update(log.continuing(id, at: now())) }

    func delete(_ id: UUID) { update(log.deleting(id)) }

    func deleteAll() { update(AskChatLog()) }

    private func update(_ next: AskChatLog) {
        guard next != log else { return }
        log = next
        save()
    }

    /// Waits for saves already queued (quitting, tests).
    func flush() {
        writer.sync {}
    }

    private func save() {
        guard let fileURL, canSave else { return }
        let snapshot = log
        writer.async { Self.write(snapshot, to: fileURL) }
    }

    private nonisolated static func write(_ log: AskChatLog, to url: URL) {
        do {
            let manager = FileManager.default
            let folder = url.deletingLastPathComponent()
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            // Also tightens a folder that already existed.
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(log).write(to: url, options: [.atomic])
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            FlowLog.shared.write("ask chats save failed: \(String(describing: type(of: error)))")
        }
    }

    /// No file yet is an empty log. A file that can't be read turns saving off for the
    /// session; one that can't be decoded is moved aside first, so the next save can't
    /// overwrite it.
    private static func load(from url: URL) -> (log: AskChatLog, canSave: Bool) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (AskChatLog(), true) }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            FlowLog.shared.write("ask chats file unreadable, not saving this session: \(String(describing: type(of: error)))")
            return (AskChatLog(), false)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return (try decoder.decode(AskChatLog.self, from: data), true)
        } catch {
            let name = "ask-chats.damaged-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).json"
            let aside = url.deletingLastPathComponent().appendingPathComponent(name)
            do {
                try FileManager.default.moveItem(at: url, to: aside)
                FlowLog.shared.write("ask chats file damaged, moved aside: \(String(describing: type(of: error)))")
                return (AskChatLog(), true)
            } catch {
                FlowLog.shared.write("ask chats file damaged and couldn't be moved, not saving this session")
                return (AskChatLog(), false)
            }
        }
    }
}
