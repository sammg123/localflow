import Foundation

/// What a cloud model is told. The tools take one message, so the chat so far goes in
/// as text.
enum AskToolPrompt {
    static let instructions = OllamaChatBody.systemPrompt + """
     Do not run commands, read files or browse the web: answer only from the attached image \
    and this message.
    """


    /// The chat so far and the question, without the instructions.
    static func message(from body: OllamaChatBody) -> String {
        let messages = body.messages.filter { $0.role != "system" }
        let question = messages.last?.content ?? ""
        var parts: [String] = []
        let earlier = messages.dropLast()
        if !earlier.isEmpty {
            let lines = earlier.map { ($0.role == "user" ? "Q: " : "A: ") + $0.content }
            parts.append("Earlier in this chat, about earlier screenshots you can no longer see:\n"
                + lines.joined(separator: "\n"))
        }
        parts.append("The attached image is the screen right now. The question:\n" + question)
        return parts.joined(separator: "\n\n")
    }

    /// LocalFlow's memory when the body carries it, then the chat so far and the question.
    /// The memory goes with the message, never on a command line other programs can read.
    static func fullMessage(from body: OllamaChatBody) -> String {
        body.memory.isEmpty ? message(from: body) : body.memory + "\n\n" + message(from: body)
    }

    /// The instructions and the message together, for a tool with no system prompt.
    static func make(from body: OllamaChatBody) -> String {
        instructions + "\n\n" + fullMessage(from: body)
    }
}

/// Running a command-line tool (Codex, Claude Code) for one Ask answer: a private
/// folder that never outlives the answer, a time limit, and a clean stop.
enum AskTool {
    /// How long a tool gets to stop after being asked before it's killed.
    static let killGrace: Duration = .seconds(3)
    /// Folders older than this are leftovers from a crash or a quit mid-answer.
    static let leftoverAge: TimeInterval = 600
    /// Only the end of a tool's error output is read.
    static let stderrTailBytes = 8_192
    static let folderPrefix = "localflow-ask-"
    /// Owner read/write only.
    static let privateFile: [FileAttributeKey: Any] = [.posixPermissions: 0o600]

    /// Letters, digits and . _ : - only, so a model name can never read as a flag.
    static func isValidModel(_ model: String) -> Bool {
        !model.isEmpty && !model.hasPrefix("-")
            && model.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "._:-".unicodeScalars.contains($0) }
    }

    /// A fresh owner-only folder for one answer. The caller deletes it.
    static func makeFolder() throws -> URL {
        removeLeftovers()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(folderPrefix + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return dir
    }

    /// Clears folders a crash or a quit mid-answer left behind, screenshots included.
    static func removeLeftovers(in folder: URL = FileManager.default.temporaryDirectory, now: Date = Date()) {
        let files = FileManager.default
        let names = (try? files.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasPrefix(folderPrefix) {
            let url = folder.appendingPathComponent(name)
            let modified = (try? files.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date ?? now
            if now.timeIntervalSince(modified) > leftoverAge { try? files.removeItem(at: url) }
        }
    }

    /// Starts the tool, runs `during` while it runs (reading its output), then waits for
    /// it to end. Stops it at the time limit or when the ask is cancelled, and kills it if
    /// it doesn't stop when asked.
    static func run(_ process: Process, timeout: Duration,
                    launchFailure: (String) -> AskError,
                    onExit: @escaping @Sendable () -> Void = {},
                    during: () async throws -> Void = {}) async throws -> Int32 {
        let (exits, exited) = AsyncStream.makeStream(of: Int32.self, bufferingPolicy: .bufferingNewest(1))
        process.terminationHandler = {
            exited.yield($0.terminationStatus)
            exited.finish()
            onExit()
        }
        let timedOut = Flag()
        let timer = Task.detached {
            try await Task.sleep(for: timeout)
            timedOut.set()
            stop(process)
        }
        defer { timer.cancel() }
        let status: Int32 = try await withTaskCancellationHandler {
            do {
                try process.run()
            } catch {
                throw launchFailure(error.localizedDescription)
            }
            // A cancel that came while it was starting found nothing to stop.
            if Task.isCancelled { stop(process) }
            do {
                try await during()
            } catch {
                stop(process)
                throw error
            }
            for await status in exits { return status }
            return -1 // cancelled while waiting; the caller checks
        } onCancel: {
            stop(process)
        }
        if timedOut.isSet { throw AskError.timedOut }
        return status
    }

    /// SIGTERM, then SIGKILL if it's still running after the grace period.
    static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        Task.detached {
            try? await Task.sleep(for: killGrace)
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    /// The end of a tool's error output.
    static func tail(of file: URL) -> String {
        guard let data = try? Data(contentsOf: file) else { return "" }
        return String(decoding: data.suffix(stderrTailBytes), as: UTF8.self)
    }

    /// The last non-empty line, trimmed.
    static func lastLine(of text: String) -> String? {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
    }
}

/// A tool's output as lines. It ends at end-of-file, or a moment after the tool exits
/// even if something the tool started still holds the pipe open, and reading stops
/// when the ask is cancelled.
final class ToolOutputLines: @unchecked Sendable {
    /// How long lines already written get to arrive after the tool exits.
    static let drainGrace: Duration = .seconds(1)

    let lines: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let handle: FileHandle
    private let lock = NSLock()
    private var pending = Data()
    private var isFinished = false

    init(reading handle: FileHandle) {
        (lines, continuation) = AsyncStream.makeStream(of: String.self)
        self.handle = handle
        handle.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            if chunk.isEmpty { self.finish() } else { self.append(chunk) }
        }
    }

    /// The tool exited: finish once the last lines have had time to arrive.
    func toolExited() {
        Task.detached { [self] in
            try? await Task.sleep(for: Self.drainGrace)
            finish()
        }
    }

    /// Stops reading. Any unfinished last line is passed on first.
    func finish() {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return }
        isFinished = true
        handle.readabilityHandler = nil
        if !pending.isEmpty { continuation.yield(String(decoding: pending, as: UTF8.self)) }
        pending = Data()
        continuation.finish()
    }

    private func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return }
        pending.append(chunk)
        while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
            continuation.yield(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
            pending.removeSubrange(pending.startIndex...newline)
        }
    }
}

/// Set once from the timer, read after the process ends.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}
