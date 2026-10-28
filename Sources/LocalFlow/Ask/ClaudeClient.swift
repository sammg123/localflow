import Foundation

/// How the Claude tool (Claude Code) is run for one answer.
enum ClaudeInvocation {
    /// Where Claude Code's installers put it. Unlike the Codex tool, which ships inside
    /// a signed app, these are folders the user can write to; anything that can replace a
    /// file there can already run as the user, including their own Claude Code.
    static func candidates(home: String = NSHomeDirectory()) -> [String] {
        [home + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
    }

    static func locate(home: String = NSHomeDirectory()) -> String? {
        candidates(home: home).first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// LocalFlow's own Claude sign-in, apart from the user's Claude Code setup: it can be
    /// a different account, and none of their settings, hooks, plugins or CLAUDE.md load.
    static func configDirectory(home: String = NSHomeDirectory()) -> String {
        home + "/Library/Application Support/LocalFlow/claude"
    }

    /// Just enough to run and find LocalFlow's sign-in; no API keys or proxies from the
    /// app's environment. Non-essential traffic (updates, telemetry) is off. The tool's
    /// own folder goes on PATH so an npm install finds the node beside it.
    static func environment(home: String = NSHomeDirectory(), tmp: String, configDirectory: String,
                            toolFolder: String? = nil) -> [String: String] {
        let path = ([toolFolder].compactMap { $0 } + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
        return ["HOME": home, "CLAUDE_CONFIG_DIR": configDirectory, "PATH": path,
                "TMPDIR": tmp, "LANG": "en_US.UTF-8", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"]
    }

    static func folder(of executable: String) -> String {
        URL(fileURLWithPath: executable).deletingLastPathComponent().path
    }

    /// Headless, streaming word by word, with no tools, no MCP servers, no slash commands
    /// and nothing saved, so text on the screen can't get it to do anything but answer.
    /// Low effort: answers are short and speed matters. The message comes on stdin.
    static func arguments(model: String) -> [String] {
        [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--include-partial-messages",
            "--verbose",
            "--model", model,
            "--effort", "low",
            "--tools", "",
            "--strict-mcp-config",
            "--disable-slash-commands",
            "--no-session-persistence",
            "--system-prompt", AskToolPrompt.instructions,
        ]
    }

    /// One stream-json user message: the screenshot, then the text.
    static func input(text: String, imageBase64: String) -> Data {
        let line: [String: Any] = ["type": "user", "message": ["role": "user", "content": [
            ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": imageBase64]],
            ["type": "text", "text": text],
        ]]]
        let data = (try? JSONSerialization.data(withJSONObject: line)) ?? Data()
        return data + Data("\n".utf8)
    }
}

/// The lines of Claude Code's stream-json output that matter to Ask.
enum ClaudeStreamEvent: Equatable {
    case text(String)
    /// An error code on an assistant message, such as authentication_failed.
    case apiError(String)
    /// The run ended; `failure` is what it said when it failed.
    case finished(failure: String?)

    static func parse(line: String) -> ClaudeStreamEvent? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        switch object["type"] as? String {
        case "stream_event":
            guard let event = object["event"] as? [String: Any], event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String, !text.isEmpty else { return nil }
            return .text(text)
        case "assistant":
            return (object["error"] as? String).map(ClaudeStreamEvent.apiError)
        case "result":
            let failed = object["is_error"] as? Bool ?? false
            return .finished(failure: failed ? (object["result"] as? String ?? "it stopped without saying why") : nil)
        default:
            return nil
        }
    }
}

/// Answers Ask with Claude on the user's own Claude plan, through Claude Code signed in
/// just for LocalFlow. The screenshot and question go to Anthropic; the answer streams
/// back word by word.
struct ClaudeClient: AskModelClient {
    static let defaultTimeout: Duration = .seconds(120)

    private let executable: String?
    private let model: String
    private let configDirectory: String
    private let timeout: Duration

    init(executable: String? = ClaudeInvocation.locate(), model: String,
         configDirectory: String = ClaudeInvocation.configDirectory(), timeout: Duration = defaultTimeout) {
        self.executable = executable
        self.model = model
        self.configDirectory = configDirectory
        self.timeout = timeout
    }

    /// Nothing to warm: the model runs at Anthropic.
    func preload(model: String) async {}

    func stream(_ body: OllamaChatBody) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    try await answer(body) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func answer(_ body: OllamaChatBody, onText: (String) -> Void) async throws {
        guard let executable else { throw AskError.claudeMissing }
        guard AskTool.isValidModel(model) else {
            throw AskError.claude("the model name in Settings (\(model)) isn't valid")
        }
        guard let image = body.messages.last?.images?.first,
              let png = Data(base64Encoded: image), !png.isEmpty else {
            throw AskError.screenCaptureFailed("no screenshot to send")
        }
        let files = FileManager.default
        let dir = try AskTool.makeFolder()
        defer { try? files.removeItem(at: dir) } // the screenshot never outlives the answer

        let input = dir.appendingPathComponent("message.jsonl")
        let errors = dir.appendingPathComponent("stderr.txt")
        let message = ClaudeInvocation.input(text: AskToolPrompt.message(from: body), imageBase64: image)
        guard files.createFile(atPath: input.path, contents: message, attributes: AskTool.privateFile),
              files.createFile(atPath: errors.path, contents: nil, attributes: AskTool.privateFile) else {
            throw AskError.claude("couldn't write the screenshot to a temporary folder")
        }

        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ClaudeInvocation.arguments(model: model)
        process.environment = ClaudeInvocation.environment(tmp: files.temporaryDirectory.path,
                                                           configDirectory: configDirectory,
                                                           toolFolder: ClaudeInvocation.folder(of: executable))
        process.currentDirectoryURL = dir
        process.standardInput = try FileHandle(forReadingFrom: input)
        process.standardOutput = output
        process.standardError = try FileHandle(forWritingTo: errors)

        let reader = ToolOutputLines(reading: output.fileHandleForReading)
        defer { reader.finish() }
        var wroteText = false
        var errorCode: String?
        var ending: ClaudeStreamEvent?
        let status = try await AskTool.run(process, timeout: timeout,
                                           launchFailure: { .claude("couldn't start Claude Code: \($0)") },
                                           onExit: { reader.toolExited() }) {
            for await line in reader.lines {
                switch ClaudeStreamEvent.parse(line: line) {
                case .text(let text):
                    wroteText = true
                    onText(text)
                case .apiError(let code):
                    errorCode = code
                case .finished(let failure):
                    ending = .finished(failure: failure)
                case nil:
                    continue
                }
            }
        }
        try Task.checkCancellation()
        if case .finished(let failure?) = ending {
            throw AskError.fromClaude(code: errorCode, text: failure)
        }
        if ending == nil, status != 0 {
            throw AskError.fromClaude(code: errorCode,
                                      text: AskTool.lastLine(of: AskTool.tail(of: errors)) ?? "it stopped without saying why")
        }
        guard wroteText else { throw AskError.claude("no answer came back") }
    }
}

extension AskError {
    /// From what Claude Code said when it failed: a sign-in problem, or its own words
    /// (a usage limit says when it resets), minus the raw timestamp it sometimes appends.
    static func fromClaude(code: String?, text: String) -> AskError {
        let lower = text.lowercased()
        let signedOut = ["not logged in", "/login", "invalid api key"]
        if code == "authentication_failed" || signedOut.contains(where: lower.contains) {
            return .claudeSignedOut
        }
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let detail = firstLine.replacingOccurrences(of: #"\|\d+$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return .claude(String(detail.prefix(200)))
    }
}
