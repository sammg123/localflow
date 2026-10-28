import Foundation
import Testing
@testable import LocalFlow

@Suite("Ask through Claude (the Claude Code tool)")
struct ClaudeClientTests {
    private let body = OllamaChatBody.ask(
        model: "claude-sonnet-5-5", question: "what about the second one?",
        imageBase64: Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString(),
        history: [AskTurn(question: "which is biggest?", answer: "The first bar, at 42.")]
    )

    // MARK: Lines the tool prints (stream-json)

    private func delta(_ text: String) -> String {
        let event: [String: Any] = ["type": "stream_event", "event": [
            "type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": text],
        ]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: event), as: UTF8.self)
    }

    private func result(error: String? = nil) -> String {
        let event: [String: Any] = ["type": "result", "subtype": "success", "is_error": error != nil,
                                    "result": error ?? "The second bar is 17."]
        return String(decoding: try! JSONSerialization.data(withJSONObject: event), as: UTF8.self)
    }

    private let authFailed = #"{"type":"assistant","message":{"model":"<synthetic>","content":[]},"error":"authentication_failed"}"#
    private let initLine = #"{"type":"system","subtype":"init","tools":[],"mcp_servers":[],"model":"claude-sonnet-5-5"}"#

    /// A stand-in `claude` that answers without any network: it records its arguments,
    /// stdin and sign-in folder, then prints `lines`.
    private func fakeClaude(lines: [String], exitCode: Int = 0, stderr: String = "",
                            sleep: Int = 0, sleepAfter: Int = 0) throws -> (path: String, dir: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fake-claude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" > "\(dir.path)/args"
        cat > "\(dir.path)/stdin"
        printf '%s' "$CLAUDE_CONFIG_DIR" > "\(dir.path)/configdir"
        sleep \(sleep)
        printf '%s' '\(stderr)' >&2
        cat <<'LINES'
        \(lines.joined(separator: "\n"))
        LINES
        sleep \(sleepAfter)
        exit \(exitCode)
        """
        let path = dir.appendingPathComponent("claude").path
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return (path, dir)
    }

    private func client(_ path: String?, model: String = "claude-sonnet-5-5",
                        timeout: Duration = ClaudeClient.defaultTimeout) -> ClaudeClient {
        ClaudeClient(executable: path, model: model, configDirectory: "/tmp/localflow-claude-test", timeout: timeout)
    }

    private func collect(_ client: ClaudeClient) async throws -> [String] {
        var chunks: [String] = []
        for try await chunk in client.stream(body) { chunks.append(chunk) }
        return chunks
    }

    // MARK: How it's run

    @Test("runs headless with no tools, no MCP servers, no slash commands and no saved session")
    func arguments() {
        let args = ClaudeInvocation.arguments(model: "claude-sonnet-5-5")
        #expect(args.first == "-p")
        #expect(args.adjacentPair("--input-format", "stream-json"))
        #expect(args.adjacentPair("--output-format", "stream-json"))
        #expect(args.adjacentPair("--model", "claude-sonnet-5-5"))
        #expect(args.adjacentPair("--effort", "low"))
        #expect(args.adjacentPair("--tools", ""))
        for flag in ["--include-partial-messages", "--verbose", "--strict-mcp-config",
                     "--disable-slash-commands", "--no-session-persistence"] {
            #expect(args.contains(flag))
        }
        #expect(args.adjacentPair("--system-prompt", AskToolPrompt.instructions))
        #expect(!args.contains("--dangerously-skip-permissions"))
        #expect(!args.contains("--mcp-config"))
    }

    @Test("the tool gets its own sign-in folder and nothing else from the environment")
    func environment() {
        let config = ClaudeInvocation.configDirectory(home: "/Users/me")
        #expect(config == "/Users/me/Library/Application Support/LocalFlow/claude")
        let env = ClaudeInvocation.environment(home: "/Users/me", tmp: "/tmp/x", configDirectory: config)
        #expect(env["CLAUDE_CONFIG_DIR"] == config)
        #expect(env["HOME"] == "/Users/me")
        #expect(env["ANTHROPIC_API_KEY"] == nil)
        #expect(env["ANTHROPIC_AUTH_TOKEN"] == nil)
        #expect(Set(env.keys) == ["HOME", "USER", "CLAUDE_CONFIG_DIR", "PATH", "TMPDIR", "LANG",
                                  "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"])
        // Claude Code finds its saved sign-in by the Mac username; without it, it reads as signed out.
        #expect(env["USER"] == NSUserName())
        #expect(env["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
        let npm = ClaudeInvocation.environment(home: "/Users/me", tmp: "/tmp/x", configDirectory: config,
                                               toolFolder: ClaudeInvocation.folder(of: "/opt/homebrew/bin/claude"))
        #expect(npm["PATH"] == "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin")
    }

    @Test("a helper left holding the output open can't keep the answer waiting")
    func leftoverHelper() async throws {
        // The fake answers, then leaves a background child holding stdout for 30 seconds.
        let fake = try fakeClaude(lines: [delta("Done."), result()])
        let script = try String(contentsOfFile: fake.path, encoding: .utf8)
            .replacingOccurrences(of: "exit 0", with: "sleep 30 &\nexit 0")
        try script.write(toFile: fake.path, atomically: true, encoding: .utf8)
        let started = ContinuousClock.now

        let chunks = try await collect(client(fake.path))

        #expect(chunks == ["Done."])
        #expect(started.duration(to: .now) < .seconds(10)) // not the helper's 30
    }

    @Test("the question goes in as one message: the screenshot, then the chat so far and the question")
    func input() throws {
        let data = ClaudeInvocation.input(text: "the question", imageBase64: "iVBORw==")
        #expect(data.last == UInt8(ascii: "\n"))
        let line = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(line["type"] as? String == "user")
        let message = try #require(line["message"] as? [String: Any])
        #expect(message["role"] as? String == "user")
        let content = try #require(message["content"] as? [[String: Any]])
        #expect(content.count == 2)
        let source = try #require(content[0]["source"] as? [String: Any])
        #expect(content[0]["type"] as? String == "image")
        #expect(source["media_type"] as? String == "image/png")
        #expect(source["data"] as? String == "iVBORw==")
        #expect(content[1]["text"] as? String == "the question")
    }

    @Test("the message carries the chat so far and the question; the instructions go in the system prompt")
    func message() {
        let text = AskToolPrompt.message(from: body)
        #expect(text.contains("which is biggest?"))
        #expect(text.contains("The first bar, at 42."))
        #expect(text.hasSuffix("what about the second one?"))
        #expect(!text.contains(AskToolPrompt.instructions))
    }

    // MARK: Reading what comes back

    @Test("reads words as they stream, the end, and failures")
    func parse() {
        #expect(ClaudeStreamEvent.parse(line: delta("Hi")) == .text("Hi"))
        #expect(ClaudeStreamEvent.parse(line: result()) == .finished(failure: nil))
        #expect(ClaudeStreamEvent.parse(line: result(error: "Not logged in")) == .finished(failure: "Not logged in"))
        #expect(ClaudeStreamEvent.parse(line: authFailed) == .apiError("authentication_failed"))
        #expect(ClaudeStreamEvent.parse(line: initLine) == nil)
        #expect(ClaudeStreamEvent.parse(line: "not json") == nil)
    }

    @Test("streams the answer word by word, sending the screenshot, question and sign-in folder")
    func answers() async throws {
        let fake = try fakeClaude(lines: [initLine, delta("The second"), delta(" bar is 17."), result()])
        let chunks = try await collect(client(fake.path))

        #expect(chunks == ["The second", " bar is 17."])
        let stdin = try Data(contentsOf: fake.dir.appendingPathComponent("stdin"))
        let line = try #require(JSONSerialization.jsonObject(with: stdin) as? [String: Any])
        let content = try #require((line["message"] as? [String: Any])?["content"] as? [[String: Any]])
        #expect((content[0]["source"] as? [String: Any])?["data"] as? String == Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString())
        #expect((content[1]["text"] as? String)?.hasSuffix("what about the second one?") == true)
        let config = try String(contentsOf: fake.dir.appendingPathComponent("configdir"), encoding: .utf8)
        #expect(config == "/tmp/localflow-claude-test")
    }

    @Test("not signed in says how to sign in")
    func signedOut() async throws {
        let fake = try fakeClaude(lines: [authFailed, result(error: "Not logged in · Please run /login")], exitCode: 1)
        await #expect(throws: AskError.claudeSignedOut) { try await collect(client(fake.path)) }
    }

    @Test("any other failure passes on what the tool said, without a trailing timestamp")
    func otherFailure() async throws {
        let fake = try fakeClaude(lines: [result(error: "API Error: 529 Overloaded|1700000000")], exitCode: 1)
        await #expect(throws: AskError.claude("API Error: 529 Overloaded")) { try await collect(client(fake.path)) }
    }

    // MARK: Out of usage

    private func rateLimit(status: String, resetsAt: Int = 1_793_229_600, overage: Bool = false) -> String {
        let event: [String: Any] = ["type": "rate_limit_event", "rate_limit_info": [
            "status": status, "resetsAt": resetsAt, "rateLimitType": "five_hour", "isUsingOverage": overage,
        ]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: event), as: UTF8.self)
    }

    @Test("reads a usage limit that's been hit, and ignores one that still allows the ask")
    func parseUsageLimit() {
        #expect(ClaudeStreamEvent.parse(line: rateLimit(status: "rejected"))
            == .usageLimit(resetsAt: Date(timeIntervalSince1970: 1_793_229_600)))
        #expect(ClaudeStreamEvent.parse(line: rateLimit(status: "allowed")) == nil)
        #expect(ClaudeStreamEvent.parse(line: rateLimit(status: "allowed_warning")) == nil)
        #expect(ClaudeStreamEvent.parse(line: rateLimit(status: "rejected", overage: true)) == nil)
        let overageAllowed = #"{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":1793229600,"isUsingOverage":false,"overageStatus":"allowed"}}"#
        #expect(ClaudeStreamEvent.parse(line: overageAllowed) == nil)
    }

    @Test("a limit notice after the answer has started doesn't cut it off")
    func limitAfterAnswering() async throws {
        let fake = try fakeClaude(lines: [delta("The second bar is 17."), rateLimit(status: "rejected"), result()])
        let chunks = try await collect(client(fake.path))
        #expect(chunks == ["The second bar is 17."])
    }

    @Test("out of usage says so right away, with when it resets, instead of waiting")
    func outOfUsage() async throws {
        // The fake would sit there for 30 seconds after saying the limit is hit.
        let fake = try fakeClaude(lines: [initLine, rateLimit(status: "rejected")], sleepAfter: 30)
        let started = ContinuousClock.now
        await #expect(throws: AskError.claudeOutOfUsage(resetsAt: Date(timeIntervalSince1970: 1_793_229_600), detail: nil)) {
            try await collect(client(fake.path))
        }
        #expect(started.duration(to: .now) < .seconds(10)) // not the fake's 30
    }

    @Test("a usage-limit failure in the tool's words is out of usage too", arguments: [
        ("Claude AI usage limit reached|1793229600", "rate_limit", Date(timeIntervalSince1970: 1_793_229_600)),
        ("You've hit your limit · resets 3pm (America/Los_Angeles)", nil, nil),
        ("Out of usage credits", "billing_error", nil),
        ("You're out of extra usage · resets Nov 3", nil, nil),
        ("Opus limit reached ∙ resets 9am", nil, nil),
    ] as [(String, String?, Date?)])
    func outOfUsageWords(text: String, code: String?, resetsAt: Date?) {
        guard case .claudeOutOfUsage(let when, _) = AskError.fromClaude(code: code, text: text) else {
            Issue.record("expected out of usage for \(text)")
            return
        }
        #expect(when == resetsAt)
    }

    @Test("a context-length error or a brief throttle is not mistaken for running out of usage")
    func notUsage() {
        #expect(AskError.fromClaude(code: nil, text: "Context limit reached") == .claude("Context limit reached"))
        #expect(AskError.fromClaude(code: "rate_limit", text: "Request rate limit exceeded, retry shortly")
            == .claude("Request rate limit exceeded, retry shortly"))
        #expect(AskError.fromClaude(code: nil, text: "Took 3 steps|42") == .claude("Took 3 steps|42"))
    }

    @Test("the out-of-usage message says when it resets and how to keep going")
    func outOfUsageMessage() throws {
        let calendar = Calendar.current
        let now = try #require(calendar.date(bySettingHour: 12, minute: 0, second: 0, of: Date()))
        let later = now.addingTimeInterval(3 * 3_600)
        let tomorrow = now.addingTimeInterval(26 * 3_600)
        let nextWeek = now.addingTimeInterval(4 * 86_400)
        #expect(AskError.resetPhrase(for: later, now: now).hasPrefix("at "))
        #expect(AskError.resetPhrase(for: tomorrow, now: now).hasPrefix("tomorrow at "))
        #expect(AskError.resetPhrase(for: nextWeek, now: now).hasPrefix("on "))
        #expect(AskError.resetPhrase(for: now.addingTimeInterval(-60), now: now) == "shortly")

        let message = AskError.claudeOutOfUsage(resetsAt: later, detail: nil).message
        #expect(message.contains("out of Claude usage"))
        #expect(message.contains("resets"))
        #expect(message.contains("local model"))
        let worded = AskError.claudeOutOfUsage(resetsAt: nil, detail: "resets 3pm").message
        #expect(worded.contains("resets 3pm"))
        #expect(!AskError.claudeOutOfUsage(resetsAt: nil, detail: "Out of usage credits.").message.contains(".."))
        #expect(AskError.claudeOutOfUsage(resetsAt: nil, detail: nil).logName == "claudeOutOfUsage")
    }

    @Test("a crash with no result passes on the tool's last error line")
    func crash() async throws {
        let fake = try fakeClaude(lines: [], exitCode: 1, stderr: "starting\nsomething broke")
        await #expect(throws: AskError.claude("something broke")) { try await collect(client(fake.path)) }
    }

    @Test("a run that ends without words says so instead of an empty bubble")
    func emptyAnswer() async throws {
        let fake = try fakeClaude(lines: [initLine, result()])
        await #expect(throws: AskError.claude("no answer came back")) { try await collect(client(fake.path)) }
    }

    @Test("no Claude tool on this Mac says where to get it")
    func missingTool() async throws {
        await #expect(throws: AskError.claudeMissing) { try await collect(client(nil)) }
    }

    @Test("a stuck run is stopped at the time limit")
    func timesOut() async throws {
        let fake = try fakeClaude(lines: [result()], sleep: 5)
        let started = ContinuousClock.now
        await #expect(throws: AskError.timedOut) {
            try await collect(client(fake.path, timeout: .milliseconds(300)))
        }
        #expect(started.duration(to: .now) < .seconds(3))
    }

    @Test("a model name that could read as a flag is refused before anything runs")
    func modelName() async throws {
        let fake = try fakeClaude(lines: [result()])
        await #expect(throws: AskError.claude("the model name in Settings (--verbose) isn't valid")) {
            try await collect(client(fake.path, model: "--verbose"))
        }
        #expect(!FileManager.default.fileExists(atPath: fake.dir.appendingPathComponent("args").path))
    }

    @Test("the engine setting knows Claude and its default model")
    @MainActor
    func engineChoice() {
        #expect(AskEngine.claude.defaultModel == "claude-sonnet-5-5")
        #expect(AskEngine.allCases.contains(.claude))
    }

    // MARK: Signing in

    @Test("reads which account LocalFlow's Claude sign-in is on")
    func account() {
        let signedIn = Data(#"{"loggedIn":true,"authMethod":"claude.ai","email":"me@example.com","subscriptionType":"pro"}"#.utf8)
        #expect(ClaudeAccount.parse(status: signedIn) == .signedIn(email: "me@example.com", plan: "pro"))
        #expect(ClaudeAccount.signedIn(email: "me@example.com", plan: "pro").summary == "Signed in as me@example.com (Pro plan)")
        #expect(ClaudeAccount.parse(status: Data(#"{"loggedIn":false,"authMethod":"none"}"#.utf8)) == .signedOut)
        #expect(ClaudeAccount.parse(status: Data("garbage".utf8)) == nil)
    }

    @Test("the sign-in script uses LocalFlow's own folder and quotes every path")
    func signInScript() {
        let script = ClaudeSignIn.script(executable: "/Users/o'neil/.local/bin/claude",
                                         configDirectory: "/Users/o'neil/Library/Application Support/LocalFlow/claude")
        #expect(script.hasPrefix("#!/bin/sh\n"))
        #expect(script.contains("export CLAUDE_CONFIG_DIR='/Users/o'\\''neil/Library/Application Support/LocalFlow/claude'"))
        #expect(script.contains("'/Users/o'\\''neil/.local/bin/claude' auth login --claudeai"))
        for variable in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_OAUTH_TOKEN"] {
            #expect(script.contains("unset ") && script.contains(variable))
        }
    }
}

private extension Array where Element == String {
    /// `flag` appears somewhere immediately followed by `value`.
    func adjacentPair(_ flag: String, _ value: String) -> Bool {
        zip(self, dropFirst()).contains { $0 == flag && $1 == value }
    }
}
