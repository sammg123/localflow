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
    /// Where the tool lives: inside the ChatGPT or Codex app only. User-writable spots
    /// (~/.local/bin, Homebrew) are left out, so a stray `codex` there never gets the screen.
    static let candidates = [
        "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
        "/Applications/Codex.app/Contents/Resources/codex",
    ]

    /// Tools Codex would otherwise have. Text on screen can ask the model to use them
    /// (prompt injection), so everything that runs commands, reads files, browses or
    /// controls the Mac is switched off; the screenshot comes in through --image.
    static let disabledFeatures = [
        "shell_tool", "unified_exec", "code_mode_host", "browser_use", "browser_use_external",
        "in_app_browser", "computer_use", "apps", "plugins", "hooks", "image_generation", "view_image",
    ]

    /// Letters, digits and . _ : - only, so a model name can never read as a flag.
    static func isValidModel(_ model: String) -> Bool {
        !model.isEmpty && !model.hasPrefix("-")
            && model.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "._:-".unicodeScalars.contains($0) }
    }

    /// Just enough for the tool to run and find the ChatGPT sign-in; nothing else from
    /// the app's environment (API keys, proxies, a different CODEX_HOME) is passed on.
    static func environment(home: String = NSHomeDirectory(), tmp: String) -> [String: String] {
        ["HOME": home, "CODEX_HOME": home + "/.codex", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
         "TMPDIR": tmp, "LANG": "en_US.UTF-8"]
    }

    static func locate() -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Isolated from the user's own Codex setup (no config, hooks, MCP servers or rules),
    /// nothing saved to their Codex history, no tools, and a read-only sandbox in an empty
    /// folder. Low reasoning effort: answers are short and speed matters. The prompt
    /// comes on stdin.
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
            "--config", "history.persistence=\"none\"",
        ]
            + disabledFeatures.flatMap { ["--disable", $0] }
            + [
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
    /// How long the tool gets to stop after being asked before it's killed.
    static let killGrace: Duration = .seconds(3)
    /// Folders older than this are leftovers from a crash or a quit mid-answer.
    static let leftoverAge: TimeInterval = 600
    /// Only the end of the tool's error output is read.
    static let stderrTailBytes = 8_192

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
        guard CodexInvocation.isValidModel(model) else {
            throw AskError.chatGPT("the model name in Settings (\(model)) isn't valid")
        }
        guard let png = body.messages.last?.images?.first.flatMap({ Data(base64Encoded: $0) }), !png.isEmpty else {
            throw AskError.screenCaptureFailed("no screenshot to send")
        }
        let files = FileManager.default
        Self.removeLeftovers()
        let dir = files.temporaryDirectory.appendingPathComponent("localflow-ask-\(UUID().uuidString)")
        try files.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: dir) } // the screenshot never outlives the answer

        let image = dir.appendingPathComponent("screen.png")
        let prompt = dir.appendingPathComponent("prompt.txt")
        let output = dir.appendingPathComponent("answer.txt")
        let errors = dir.appendingPathComponent("stderr.txt")
        let private600: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
        // The prompt goes in from a file, not a pipe: no write can block, or fail if the
        // tool exits early.
        guard files.createFile(atPath: image.path, contents: png, attributes: private600),
              files.createFile(atPath: prompt.path, contents: Data(CodexPrompt.make(from: body).utf8), attributes: private600),
              files.createFile(atPath: errors.path, contents: nil, attributes: private600) else {
            throw AskError.chatGPT("couldn't write the screenshot to a temporary folder")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = CodexInvocation.arguments(model: model, imagePath: image.path,
                                                      outputPath: output.path, workingDirectory: dir.path)
        process.environment = CodexInvocation.environment(tmp: files.temporaryDirectory.path)
        process.currentDirectoryURL = dir
        process.standardOutput = FileHandle.nullDevice
        process.standardError = try FileHandle(forWritingTo: errors)
        process.standardInput = try FileHandle(forReadingFrom: prompt)

        let status = try await run(process)
        try Task.checkCancellation()
        guard status == 0 else {
            throw AskError.fromCodex(stderr: Self.tail(of: errors))
        }
        let text = ((try? String(contentsOf: output, encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw AskError.chatGPT("no answer came back")
        }
        return text
    }

    /// Runs the tool to the end, stopping it at the time limit or when the ask is
    /// cancelled, and killing it if it doesn't stop when asked.
    private func run(_ process: Process) async throws -> Int32 {
        let timedOut = Flag()
        let limit = timeout
        let timer = Task.detached {
            try await Task.sleep(for: limit)
            timedOut.set()
            Self.stop(process)
        }
        defer { timer.cancel() }
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: AskError.chatGPT("couldn't start the Codex tool: \(error.localizedDescription)"))
                    return
                }
                // A cancel that came while it was starting found nothing to stop.
                if Task.isCancelled { Self.stop(process) }
            }
        } onCancel: {
            Self.stop(process)
        }
        if timedOut.isSet { throw AskError.timedOut }
        return status
    }

    /// SIGTERM, then SIGKILL if it's still running after the grace period.
    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        Task.detached {
            try? await Task.sleep(for: killGrace)
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    private static func tail(of file: URL) -> String {
        guard let data = try? Data(contentsOf: file) else { return "" }
        return String(decoding: data.suffix(stderrTailBytes), as: UTF8.self)
    }

    /// Clears folders a crash or a quit mid-answer left behind, screenshots included.
    static func removeLeftovers(in folder: URL = FileManager.default.temporaryDirectory, now: Date = Date()) {
        let files = FileManager.default
        let names = (try? files.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasPrefix("localflow-ask-") {
            let url = folder.appendingPathComponent(name)
            let modified = (try? files.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date ?? now
            if now.timeIntervalSince(modified) > leftoverAge { try? files.removeItem(at: url) }
        }
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
        let signedOut = ["not logged in", "codex login", "unauthorized"]
        if signedOut.contains(where: tail.contains) { return .chatGPTSignedOut }
        return .chatGPT(String((lines.last ?? "it stopped without saying why").prefix(200)))
    }
}
