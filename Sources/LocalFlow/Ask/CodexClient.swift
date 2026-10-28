import Foundation

/// What Codex is told. Codex takes one message, so the chat so far goes in as text.
enum CodexPrompt {
    static let instructions = OllamaChatBody.systemPrompt + """
     Do not run commands, read files or browse the web: answer only from the attached image \
    and this message.
    """

    static func make(from body: OllamaChatBody) -> String {
        let messages = body.messages.filter { $0.role != "system" }
        let question = messages.last?.content ?? ""
        var parts = [instructions]
        let earlier = messages.dropLast()
        if !earlier.isEmpty {
            let lines = earlier.map { ($0.role == "user" ? "Q: " : "A: ") + $0.content }
            parts.append("Earlier in this chat, about earlier screenshots you can no longer see:\n"
                + lines.joined(separator: "\n"))
        }
        parts.append("The attached image is the screen right now. The question:\n" + question)
        return parts.joined(separator: "\n\n")
    }
}

/// How the Codex tool is run for one answer.
enum CodexInvocation {
    /// Where the tool lives: inside the ChatGPT app, or installed on its own.
    static var candidates: [String] {
        let home = NSHomeDirectory()
        return [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            home + "/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]
    }

    static func locate() -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Isolated from the user's own Codex setup (no config, hooks, MCP servers or rules),
    /// nothing saved to their Codex history, and a read-only sandbox in an empty folder.
    /// Low reasoning effort: answers are short and speed matters. The prompt comes on stdin.
    static func arguments(model: String, imagePath: String, outputPath: String,
                          workingDirectory: String) -> [String] {
        [
            "exec",
            "--ephemeral",
            "--skip-git-repo-check",
            "--ignore-user-config",
            "--ignore-rules",
            "--sandbox", "read-only",
            "--color", "never",
            "--model", model,
            "--config", "model_reasoning_effort=\"low\"",
            "--image", imagePath,
            "--output-last-message", outputPath,
            "--cd", workingDirectory,
            "-",
        ]
    }
}

/// Answers Ask with ChatGPT on the user's own plan, through the Codex tool signed in with
/// their ChatGPT account. The screenshot and question go to OpenAI; the answer comes
/// back whole (the tool doesn't stream), so the bubble shows Thinking until then.
struct CodexClient: AskModelClient {
    static let defaultTimeout: Duration = .seconds(120)

    private let executable: String?
    private let model: String
    private let timeout: Duration

    init(executable: String? = CodexInvocation.locate(), model: String, timeout: Duration = defaultTimeout) {
        self.executable = executable
        self.model = model
        self.timeout = timeout
    }

    /// Nothing to warm: the model runs at OpenAI.
    func preload(model: String) async {}

    func stream(_ body: OllamaChatBody) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    continuation.yield(try await answer(body))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func answer(_ body: OllamaChatBody) async throws -> String {
        guard let executable else { throw AskError.chatGPTMissing }
        let files = FileManager.default
        let dir = files.temporaryDirectory.appendingPathComponent("localflow-ask-\(UUID().uuidString)")
        try files.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: dir) } // the screenshot never outlives the answer

        let image = dir.appendingPathComponent("screen.png")
        let output = dir.appendingPathComponent("answer.txt")
        let errors = dir.appendingPathComponent("stderr.txt")
        let png = body.messages.last?.images?.first.flatMap { Data(base64Encoded: $0) } ?? Data()
        files.createFile(atPath: image.path, contents: png, attributes: [.posixPermissions: 0o600])
        files.createFile(atPath: errors.path, contents: nil, attributes: [.posixPermissions: 0o600])

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = CodexInvocation.arguments(model: model, imagePath: image.path,
                                                      outputPath: output.path, workingDirectory: dir.path)
        process.currentDirectoryURL = dir
        process.standardOutput = FileHandle.nullDevice
        process.standardError = try FileHandle(forWritingTo: errors)
        let input = Pipe()
        process.standardInput = input

        let status = try await run(process, input: input, prompt: Data(CodexPrompt.make(from: body).utf8))
        try Task.checkCancellation()
        guard status == 0 else {
            let stderr = (try? String(contentsOf: errors, encoding: .utf8)) ?? ""
            throw AskError.fromCodex(stderr: stderr)
        }
        let text = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs the tool to the end, stopping it at the time limit or when the ask is cancelled.
    private func run(_ process: Process, input: Pipe, prompt: Data) async throws -> Int32 {
        let timedOut = Flag()
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: AskError.chatGPT("couldn't start the Codex tool: \(error.localizedDescription)"))
                    return
                }
                input.fileHandleForWriting.write(prompt)
                try? input.fileHandleForWriting.close()
                let limit = timeout
                Task.detached {
                    try? await Task.sleep(for: limit)
                    guard process.isRunning else { return }
                    timedOut.set()
                    process.terminate()
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        if timedOut.isSet { throw AskError.timedOut }
        return status
    }
}

/// Set once from the timer, read after the process ends.
private final class Flag: @unchecked Sendable {
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

extension AskError {
    /// From what the Codex tool wrote when it failed. Only its last lines are read: earlier
    /// ones can echo the question.
    static func fromCodex(stderr: String) -> AskError {
        let lines = stderr.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let tail = lines.suffix(3).joined(separator: " ").lowercased()
        let signedOut = ["not logged in", "codex login", "unauthorized", "authentication"]
        if signedOut.contains(where: tail.contains) { return .chatGPTSignedOut }
        return .chatGPT(String((lines.last ?? "it stopped without saying why").prefix(200)))
    }
}
