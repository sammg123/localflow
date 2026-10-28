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
    /// USER is needed: Claude Code finds its saved sign-in in the keychain by it.
    static func environment(home: String = NSHomeDirectory(), user: String = NSUserName(), tmp: String,
                            configDirectory: String, toolFolder: String? = nil) -> [String: String] {
        let path = ([toolFolder].compactMap { $0 } + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
        return ["HOME": home, "USER": user, "CLAUDE_CONFIG_DIR": configDirectory, "PATH": path,
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
    /// The plan's usage limit is hit and no extra usage is covering it.
    case usageLimit(resetsAt: Date?)

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
        case "rate_limit_event":
            // Extra usage (overage) can still pay for the answer, so that's not a stop.
            guard let info = object["rate_limit_info"] as? [String: Any], info["status"] as? String == "rejected",
                  info["isUsingOverage"] as? Bool != true, info["overageStatus"] as? String != "allowed" else { return nil }
            return .usageLimit(resetsAt: (info["resetsAt"] as? Double).map(Date.init(timeIntervalSince1970:)))
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
        var outOfUsage: AskError?
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
                case .usageLimit(let resetsAt) where !wroteText:
                    // Say so now rather than wait on a run that can't answer.
                    outOfUsage = .claudeOutOfUsage(resetsAt: resetsAt, detail: nil)
                    AskTool.stop(process)
                case .usageLimit:
                    continue // already answering
                case nil:
                    continue
                }
            }
        }
        try Task.checkCancellation()
        if let outOfUsage { throw outOfUsage }
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
    /// Words Claude Code uses when the plan's usage is used up.
    static let usageLimitWords = ["usage limit", "hit your limit", "out of usage", "out of extra usage",
                                  "credit balance", "weekly limit", "session limit", "5-hour limit",
                                  "opus limit", "sonnet limit"]

    /// From what Claude Code said when it failed: a sign-in problem, the plan's usage
    /// used up, or its own words, minus the raw timestamp it sometimes appends.
    static func fromClaude(code: String?, text: String) -> AskError {
        let lower = text.lowercased()
        let signedOut = ["not logged in", "/login", "invalid api key"]
        if code == "authentication_failed" || signedOut.contains(where: lower.contains) {
            return .claudeSignedOut
        }
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let stamp = firstLine.range(of: #"\|\d{9,11}$"#, options: .regularExpression) // a Unix time
        let detail = String((stamp.map { String(firstLine[..<$0.lowerBound]) } ?? firstLine)
            .trimmingCharacters(in: .whitespaces).prefix(200))
        // A plain rate_limit is often a brief throttle that a retry fixes, so it only
        // counts with the plan's own usage words; billing_error is credits used up.
        if code == "billing_error" || usageLimitWords.contains(where: lower.contains) {
            let resetsAt = stamp.flatMap { Double(firstLine[$0].dropFirst()) }.map(Date.init(timeIntervalSince1970:))
            return .claudeOutOfUsage(resetsAt: resetsAt, detail: resetsAt == nil ? detail : nil)
        }
        return .claude(detail)
    }

    /// When a usage limit resets, said the way a person would: "at 3:00 PM",
    /// "tomorrow at 9:00 AM", "on Monday, Nov 2 at 9:00 AM".
    static func resetPhrase(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard date > now else { return "shortly" }
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return "at \(time)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "tomorrow at \(time)"
        }
        return "on \(date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())) at \(time)"
    }
}
