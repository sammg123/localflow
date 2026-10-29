import Foundation
import Testing
@testable import LocalFlow

/// Everything a runner sent, collected off its stream so tests can wait on it.
final class AgentEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AgentEvent] = []

    init(_ runner: AgentRunner) {
        Task.detached { [self] in
            for await event in runner.events { append(event) }
        }
    }

    var all: [AgentEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    private func append(_ event: AgentEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    /// Polls until `find` returns something, up to `seconds`. Generous, since a fresh
    /// script can be slow to start while the whole suite runs at once.
    func poll<T>(seconds: Double = 15, _ find: () -> T?) async -> T? {
        let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1_000))
        while ContinuousClock.now < deadline {
            if let hit = find() { return hit }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    /// Waits until an event matches, up to `seconds`.
    @discardableResult
    func wait(seconds: Double = 15, for match: (AgentEvent) -> Bool) async -> AgentEvent? {
        await poll(seconds: seconds) { all.first(where: match) }
    }

    func ended(seconds: Double = 15) async -> AskError?? {
        await poll(seconds: seconds) {
            all.lazy.compactMap { event -> AskError?? in
                if case .ended(let error) = event { return .some(error) }
                return nil
            }.first
        }
    }

    /// The `number`th permission prompt, once it has come.
    func permission(_ number: Int = 1) async -> (id: String, input: AgentJSON)? {
        await poll {
            let requests = all.compactMap { event -> (id: String, input: AgentJSON)? in
                if case .permissionRequest(let id, _, let input, _, _) = event { return (id, input) }
                return nil
            }
            return requests.count >= number ? requests[number - 1] : nil
        }
    }

    func finalTexts() -> [String] {
        all.compactMap { if case .turnFinished(_, let text?) = $0 { text } else { nil } }
    }
}

/// Log lines a runner wrote.
final class AgentLogLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    func write(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }
}

/// Stand-in `claude` scripts for one test, and the folders they live in, removed when
/// the test is done.
final class AgentFakeClaudes {
    private var made: [URL] = []

    deinit {
        for dir in made { try? FileManager.default.removeItem(at: dir) }
    }

    static let mcpExecutable = "/Applications/LocalFlow.app/Contents/MacOS/LocalFlow"
    static let toolInput = #"{"command":"touch probe-file.txt","description":"Create empty probe file","timeout":1.5,"flags":[true,null,2]}"#

    struct Fake {
        let path: String
        let dir: URL
        let home: String

        func file(_ name: String) -> String {
            (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? ""
        }

        func stdinLines() -> [String] {
            file("stdin").split(separator: "\n").map(String.init)
        }
    }

    /// The fake prints these on each user turn: some words, a tool, then a permission prompt.
    private static let turn = #"""
          turn=$((turn+1))
          printf '%s\n' "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"turn $turn\"}}}"
          printf '%s\n' "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"toolu_$turn\",\"name\":\"Bash\",\"input\":$input}]}}"
          printf '%s\n' "{\"type\":\"control_request\",\"request_id\":\"req-$turn\",\"request\":{\"subtype\":\"can_use_tool\",\"tool_name\":\"Bash\",\"input\":$input,\"tool_use_id\":\"toolu_$turn\"}}"
    """#

    /// A stand-in `claude` that never touches the network. It records its arguments,
    /// environment, folder and MCP config, then runs `body` (sh).
    func make(_ body: String) throws -> Fake {
        let files = FileManager.default
        let dir = files.temporaryDirectory.appendingPathComponent("fake-agent-claude-\(UUID().uuidString)")
        let home = dir.appendingPathComponent("home")
        try files.createDirectory(at: home, withIntermediateDirectories: true)
        let script = #"""
        #!/bin/sh
        out='\#(dir.path)'
        input='\#(Self.toolInput)'
        printf '%s\n' "$@" > "$out/args"
        env > "$out/env"
        pwd > "$out/cwd"
        prev=""
        for a in "$@"; do
          if [ "$prev" = "--mcp-config" ]; then
            cp "$a" "$out/mcp.json"
            stat -f %Lp "$a" > "$out/mcp.mode"
            dirname "$a" > "$out/folder"
          fi
          prev="$a"
        done
        \#(body)
        """#
        made.append(dir)
        let path = dir.appendingPathComponent("claude").path
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return Fake(path: path, dir: dir, home: home.path)
    }

    /// Answers like Claude Code: hello, a permission prompt each turn, the host's answer in
    /// the result, an interrupt, and an exit when stdin closes.
    func conversing() throws -> Fake {
        try make(#"""
        echo '{"type":"system","subtype":"init","session_id":"s-1"}'
        turn=0
        while IFS= read -r line; do
          printf '%s\n' "$line" >> "$out/stdin"
          case "$line" in
            *'"subtype":"initialize"'*)
              echo '{"type":"control_response","response":{"subtype":"success","request_id":"init"}}' ;;
            *'"subtype":"interrupt"'*)
              echo '{"type":"result","subtype":"error_during_execution","is_error":true,"result":"interrupted"}' ;;
            *'"behavior":"allow"'*)
              printf '{"type":"result","subtype":"success","is_error":false,"result":"allowed %s"}\n' "$$" ;;
            *'"behavior":"deny"'*)
              printf '{"type":"result","subtype":"success","is_error":false,"result":"denied %s"}\n' "$$" ;;
            *'"type":"user"'*)
        \#(Self.turn)
              ;;
          esac
        done
        exit 0
        """#)
    }

    func runner(_ fake: Fake?, executable: String? = nil, options: AgentRunOptions = AgentRunOptions(effort: "medium"),
                log: AgentLogLines = AgentLogLines()) -> AgentRunner {
        AgentRunner(executable: executable ?? fake?.path, model: "claude-sonnet-5-5", options: options, displayID: 7,
                    mcpExecutable: Self.mcpExecutable, home: fake?.home ?? NSTemporaryDirectory(),
                    configDirectory: "/tmp/localflow-claude-test", closeGrace: .milliseconds(500),
                    log: { log.write($0) })
    }

    func json(_ text: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    }
}

@Suite("Agent mode: running Claude Code for one session")
final class AgentRunnerTests {
    private let fakes = AgentFakeClaudes()

    // MARK: How it's started

    @Test("starts with the agent's arguments, environment, folder and a private MCP config")
    func launch() async throws {
        let fake = try fakes.conversing()
        let agent = fakes.runner(fake)
        let events = AgentEventLog(agent)
        agent.start(task: "make a file", imagePNGBase64: nil)
        #expect(await events.permission() != nil)

        let args = fake.file("args").split(separator: "\n").map(String.init)
        #expect(args.first == "-p")
        #expect(args.pair("--setting-sources", "user"))
        #expect(args.pair("--permission-prompt-tool", "stdio"))
        #expect(args.pair("--permission-mode", "default"))
        #expect(args.pair("--model", "claude-sonnet-5-5"))
        #expect(args.pair("--effort", "medium"))
        #expect(args.pair("--add-dir", fake.home))
        #expect(args.contains("--strict-mcp-config"))

        let env = Set(fake.file("env").split(separator: "\n").map(String.init))
        #expect(env.contains("USER=\(NSUserName())"))
        #expect(env.contains("HOME=\(fake.home)"))
        #expect(env.contains("SHELL=\(AgentInvocation.loginShell())"))
        #expect(env.contains("CLAUDE_CONFIG_DIR=/tmp/localflow-claude-test"))
        #expect(env.contains { $0.hasPrefix("PATH=") && $0.contains("/opt/homebrew/bin") && $0.contains("/.local/bin") })
        #expect(!env.contains { $0.hasPrefix("ANTHROPIC_API_KEY=") })

        let cwd = fake.file("cwd").trimmingCharacters(in: .whitespacesAndNewlines)
        let expected = AgentInvocation.workingDirectory(home: fake.home)
        #expect(URL(fileURLWithPath: cwd).resolvingSymlinksInPath() == URL(fileURLWithPath: expected).resolvingSymlinksInPath())
        let cwdMode = try FileManager.default.attributesOfItem(atPath: cwd)[.posixPermissions] as? Int
        #expect(cwdMode == 0o700)

        #expect(fake.file("mcp.mode").trimmingCharacters(in: .whitespacesAndNewlines) == "600")
        let config = try #require(fakes.json(fake.file("mcp.json")))
        let server = try #require((config["mcpServers"] as? [String: Any])?["localflow"] as? [String: Any])
        #expect(server["command"] as? String == AgentFakeClaudes.mcpExecutable)
        #expect(server["args"] as? [String] == ["--computer-mcp", "--display", "7"])
        let folder = fake.file("folder").trimmingCharacters(in: .whitespacesAndNewlines)
        let folderMode = try FileManager.default.attributesOfItem(atPath: folder)[.posixPermissions] as? Int
        #expect(folderMode == 0o700)
        agent.close()
        #expect(await events.ended() != nil)
    }

    @Test("says hello first, then sends the task with the screenshot")
    func initializeFirst() async throws {
        let fake = try fakes.conversing()
        let agent = fakes.runner(fake)
        let events = AgentEventLog(agent)
        agent.start(task: "make a file", imagePNGBase64: "iVBORw==")
        #expect(await events.permission() != nil)

        let lines = fake.stdinLines()
        #expect(lines.count == 2)
        let hello = try #require(fakes.json(lines[0]))
        #expect(hello["type"] as? String == "control_request")
        #expect((hello["request"] as? [String: Any])?["subtype"] as? String == "initialize")
        let task = try #require(fakes.json(lines[1]))
        let content = try #require((task["message"] as? [String: Any])?["content"] as? [[String: Any]])
        #expect((content[0]["source"] as? [String: Any])?["data"] as? String == "iVBORw==")
        #expect(content[1]["text"] as? String == "make a file")
        #expect(events.all.contains(.sessionStarted(sessionID: "s-1")))
        #expect(events.all.contains(.textDelta("turn 1")))
        agent.close()
        #expect(await events.ended() != nil)
    }

    // MARK: Permission

    @Test("allowing sends the tool's input back exactly as it came")
    func allow() async throws {
        let fake = try fakes.conversing()
        let agent = fakes.runner(fake)
        let events = AgentEventLog(agent)
        agent.start(task: "make a file", imagePNGBase64: nil)
        let request = try #require(await events.permission())
        #expect(request.id == "req-1")
        #expect(request.input == AgentJSON.decode(Data(AgentFakeClaudes.toolInput.utf8)))

        agent.answer(requestID: request.id, allow: true, input: request.input, message: nil)
        #expect(await events.wait { if case .turnFinished(nil, let text?) = $0 { text.hasPrefix("allowed") } else { false } } != nil)

        let answer = try #require(fakes.json(fake.stdinLines()[2]))
        #expect(answer["type"] as? String == "control_response")
        let response = try #require(answer["response"] as? [String: Any])
        #expect(response["request_id"] as? String == "req-1")
        let decision = try #require(response["response"] as? [String: Any])
        #expect(decision["behavior"] as? String == "allow")
        #expect(AgentJSON(any: decision["updatedInput"] as Any) == AgentJSON.decode(Data(AgentFakeClaudes.toolInput.utf8)))
        agent.close()
        #expect(await events.ended() != nil)
    }

    @Test("denying sends the reason")
    func deny() async throws {
        let fake = try fakes.conversing()
        let agent = fakes.runner(fake)
        let events = AgentEventLog(agent)
        agent.start(task: "make a file", imagePNGBase64: nil)
        let request = try #require(await events.permission())

        agent.answer(requestID: request.id, allow: false, input: request.input, message: "The user said no.")
        #expect(await events.wait { if case .turnFinished(nil, let text?) = $0 { text.hasPrefix("denied") } else { false } } != nil)

        let answer = try #require(fakes.json(fake.stdinLines()[2]))
        let decision = try #require((answer["response"] as? [String: Any])?["response"] as? [String: Any])
        #expect(decision["behavior"] as? String == "deny")
        #expect(decision["message"] as? String == "The user said no.")
        agent.close()
        #expect(await events.ended() != nil)
    }

    // MARK: Turns

    @Test("a follow-up goes to the same running session")
    func followUp() async throws {
        let fake = try fakes.conversing()
        let agent = fakes.runner(fake)
        let events = AgentEventLog(agent)
        agent.start(task: "make a file", imagePNGBase64: nil)
        let first = try #require(await events.permission())
        agent.answer(requestID: first.id, allow: true, input: first.input, message: nil)
        #expect(await events.wait { if case .turnFinished = $0 { true } else { false } } != nil)

        agent.send(text: "now another", imagePNGBase64: nil)
        let second = try #require(await events.permission(2))
        #expect(second.id == "req-2")
        agent.answer(requestID: second.id, allow: true, input: second.input, message: nil)
        #expect(await events.wait { _ in events.finalTexts().count == 2 } != nil)

        let pids = events.finalTexts()
        #expect(pids.count == 2)
        #expect(pids[0] == pids[1]) // same process both turns
        #expect(events.all.filter { if case .sessionStarted = $0 { true } else { false } }.count == 1)
        let turn2 = try #require(fakes.json(fake.stdinLines()[3]))
        let content = try #require((turn2["message"] as? [String: Any])?["content"] as? [[String: Any]])
        #expect(content.count == 1)
        #expect(content[0]["text"] as? String == "now another")
        agent.close()
        #expect(await events.ended() != nil)
    }

    @Test("interrupting writes the interrupt request")
    func interrupt() async throws {
        let fake = try fakes.conversing()
        let agent = fakes.runner(fake)
        let events = AgentEventLog(agent)
        agent.start(task: "make a file", imagePNGBase64: nil)
        #expect(await events.permission() != nil)

        agent.interrupt()
        #expect(await events.wait { $0 == .turnFinished(failure: "interrupted", finalText: nil) } != nil)
        let line = try #require(fakes.json(fake.stdinLines()[2]))
        #expect(line["type"] as? String == "control_request")
        #expect((line["request"] as? [String: Any])?["subtype"] as? String == "interrupt")
        #expect(line["request_id"] as? String != nil)
        agent.close()
        #expect(await events.ended() != nil)
    }
}
