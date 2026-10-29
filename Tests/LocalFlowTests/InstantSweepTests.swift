import Foundation
import Testing
@testable import LocalFlow

/// The one quick check before an Instant run: UI or not, small or not, which project,
/// and a line saying what will change. No test here launches Claude Code or touches the
/// network: the run is a closure, or a stand-in script.
@Suite("Instant Edits: the sweep")
struct InstantSweepTests {
    private static let request = "make the save button on the invoice screen round"
    private static let memory = "Sundial: folder ~/code/sundial, repo Sundial/sundial, domain app.sundial.example, logo R1"
    private static let input = InstantSweepInput(request: request, screenshotPNGBase64: "iVBORw0K",
                                                 memory: memory, recent: ["Sundial: made the calendar header bold"])

    private func resultLine(_ text: String, isError: Bool = false) -> String {
        let object: [String: Any] = ["type": "result", "subtype": "success", "is_error": isError, "result": text]
        return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private static let smallJSON = #"""
    {"verdict":"small","reason":"One button's shape.","project":{"name":"Sundial","path":"~/code/sundial"},"change":"Making the Save button round instead of square"}
    """#

    /// Records each log line and what the run was given.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        private var given: [(arguments: [String], input: Data)] = []

        var lines: [String] { lock.withLock { stored } }
        var runs: [(arguments: [String], input: Data)] { lock.withLock { given } }
        func log(_ line: String) { lock.withLock { stored.append(line) } }
        func ran(_ arguments: [String], _ input: Data) { lock.withLock { given.append((arguments, input)) } }
    }

    private func sweep(_ recorder: Recorder, answer: @escaping @Sendable () throws -> String) -> InstantSweep {
        InstantSweep(run: { arguments, input in
            recorder.ran(arguments, input)
            return try answer()
        }, log: recorder.log)
    }

    // MARK: The prompt and how Claude Code is run

    @Test("the prompt puts the UI-only rule first, then the three inputs, size and the project")
    func prompt() throws {
        let prompt = InstantSweepPrompt.instructions
        let uiRule = try #require(prompt.range(of: "only changes what the user sees"))
        let sizeRule = try #require(prompt.range(of: "\"small\""))
        #expect(uiRule.lowerBound < sizeRule.lowerBound)
        for needle in ["not_ui", "too_big", "Google Calendar", "upload to S3", "fix the login bug",
                       "disabled until the form is valid", "rename the button label", "design profile",
                       "address bar", "logo", "window", "page title", "memory", "\"project\"", "\"change\"",
                       "null", "80 characters", "Making the Save button round instead of square"] {
            #expect(prompt.contains(needle), "\(needle)")
        }
    }

    @Test("Claude Code runs headless with no tools, on Sonnet at low effort, saving nothing")
    func arguments() {
        let arguments = InstantSweepPrompt.arguments()
        #expect(arguments.first == "-p")
        let pairs = Dictionary(zip(arguments, arguments.dropFirst()), uniquingKeysWith: { first, _ in first })
        #expect(pairs["--model"] == "claude-sonnet-5-5")
        #expect(pairs["--effort"] == "low")
        #expect(pairs["--tools"] == "")
        #expect(pairs["--input-format"] == "stream-json")
        #expect(pairs["--output-format"] == "stream-json")
        #expect(pairs["--system-prompt"] == InstantSweepPrompt.instructions)
        for flag in ["--strict-mcp-config", "--disable-slash-commands", "--no-session-persistence", "--verbose"] {
            #expect(arguments.contains(flag), "\(flag)")
        }
        #expect(!arguments.joined().contains("invoice"))
    }

    @Test("the message carries the memory, recent runs and the request, after the screenshot")
    func message() throws {
        let data = InstantSweepPrompt.input(for: Self.input)
        let line = try #require(AgentJSON.decode(data))
        let content = try #require(line["message"]?["content"]?.array)
        #expect(content.first?["type"]?.string == "image")
        #expect(content.first?["source"]?["data"]?.string == "iVBORw0K")
        let text = try #require(content.last?["text"]?.string)
        #expect(text.contains(Self.memory))
        #expect(text.contains("Sundial: made the calendar header bold"))
        #expect(text.contains(Self.request))
        let bare = InstantSweepPrompt.message(for: InstantSweepInput(request: "x", screenshotPNGBase64: nil,
                                                                     memory: " ", recent: []))
        #expect(bare.contains("doesn't know any projects yet"))
    }

    // MARK: Reading the answer

    @Test("a small edit comes back with its project and change line")
    func parsesSmall() {
        let result = InstantSweepPrompt.result(from: "```json\n\(Self.smallJSON)\n```")
        #expect(result.verdict == .small)
        #expect(result.project == InstantProject(name: "Sundial", path: "~/code/sundial"))
        #expect(result.change == "Making the Save button round instead of square")
    }

    @Test("verdicts are read from plain, fenced or wrapped JSON", arguments: [
        (#"{"verdict":"small","reason":"x","project":null,"change":"Making it blue"}"#, InstantVerdict.small),
        ("```json\n{\"verdict\": \"too_big\", \"reason\": \"It rebuilds a whole screen.\"}\n```",
         .tooBig("It rebuilds a whole screen.")),
        ("Sure: {\"verdict\":\"not_ui\",\"reason\":\"It changes what Send does.\"} Hope that helps.",
         .notUI("It changes what Send does.")),
        (#"{"verdict":"TOO BIG","reason":"  Many   files.  "}"#, .tooBig("Many files.")),
        (#"{"verdict":"not ui","reason":"Logic."}"#, .notUI("Logic.")),
        (#"Looking at {"screen":1} first. {"verdict":"small","change":"Making it blue"}"#, .small),
    ])
    func parses(text: String, verdict: InstantVerdict) {
        #expect(InstantSweepPrompt.result(from: text).verdict == verdict)
    }

    @Test("an unknown project, or one without a folder, comes back as none")
    func noProject() {
        let none = InstantSweepPrompt.result(from: #"{"verdict":"small","project":null,"change":"Making it blue"}"#)
        #expect(none.project == nil)
        let noPath = InstantSweepPrompt.result(from: #"{"verdict":"small","project":{"name":"X"},"change":"y"}"#)
        #expect(noPath.project == nil)
        let named = InstantSweepPrompt.result(from: #"{"verdict":"small","project":{"name":"","path":"/a/b"},"change":"y"}"#)
        #expect(named.project == InstantProject(name: "b", path: "/a/b"))
    }

    @Test("the change line is one short line, with a default")
    func changeLine() {
        let long = String(repeating: "Making things ", count: 20)
        let clipped = InstantSweepPrompt.result(from: "{\"verdict\":\"small\",\"change\":\"\(long)\"}").change
        #expect(clipped.count <= InstantSweepPrompt.changeLimit)
        let missing = InstantSweepPrompt.result(from: #"{"verdict":"small"}"#).change
        #expect(missing == InstantSweepPrompt.defaultChange)
        let lines = InstantSweepPrompt.result(from: #"{"verdict":"small","change":"Making\nit blue"}"#).change
        #expect(lines == "Making it blue")
    }

    @Test("a missing reason gets a plain default")
    func defaults() {
        #expect(InstantSweepPrompt.result(from: #"{"verdict":"too_big","reason":""}"#).verdict
                == .tooBig(InstantSweepPrompt.tooBigReason))
        #expect(InstantSweepPrompt.result(from: #"{"verdict":"not_ui"}"#).verdict == .notUI(InstantSweepPrompt.notUIReason))
        #expect(InstantSweepPrompt.notUIReason.contains("only changes how things look"))
    }

    @Test("anything unusable reads as unavailable", arguments: [
        "", "small", "I think it's small.", "{\"verdict\":\"maybe\",\"reason\":\"x\"}", "{\"verdict\": 3}",
        "```\nnot json\n```", "[1, 2]", "{broken",
    ])
    func unusable(text: String) {
        let result = InstantSweepPrompt.result(from: text)
        #expect(result.verdict == .unavailable(InstantSweep.unavailableMessage))
        #expect(result.project == nil)
    }

    @Test("a long reason is cut to one short line")
    func longReason() {
        let long = String(repeating: "word ", count: 100)
        let verdict = InstantSweepPrompt.result(from: "{\"verdict\":\"too_big\",\"reason\":\"\(long)\"}").verdict
        guard case .tooBig(let reason) = verdict else {
            Issue.record("not too big")
            return
        }
        #expect(reason.count <= InstantSweepPrompt.reasonLimit)
    }

    // MARK: Checking

    @Test("a check sends the screenshot and message and reads Claude Code's result line")
    func check() async {
        let recorder = Recorder()
        let output = [#"{"type":"system","subtype":"init"}"#, resultLine(Self.smallJSON)].joined(separator: "\n")
        let result = await sweep(recorder) { output }.check(Self.input)
        #expect(result.verdict == .small)
        #expect(result.project?.name == "Sundial")
        #expect(recorder.runs.first?.arguments == InstantSweepPrompt.arguments())
        #expect(recorder.runs.first?.input == InstantSweepPrompt.input(for: Self.input))
    }

    @Test("plain text output works too")
    func plainOutput() async {
        let recorder = Recorder()
        let result = await sweep(recorder) { #"{"verdict":"too_big","reason":"A whole new screen."}"# }.check(Self.input)
        #expect(result.verdict == .tooBig("A whole new screen."))
    }

    @Test("failures read as unavailable, with the fix when there is one")
    func failures() async {
        let recorder = Recorder()
        let signedOut = await sweep(recorder) { throw AskError.claudeSignedOut }.check(Self.input)
        #expect(signedOut.verdict == .unavailable(InstantSweep.signedOutMessage))
        let missing = await sweep(recorder) { throw AskError.claudeMissing }.check(Self.input)
        #expect(missing.verdict == .unavailable(InstantSweep.missingMessage))
        let slow = await sweep(recorder) { throw AskError.timedOut }.check(Self.input)
        #expect(slow.verdict == .unavailable(InstantSweep.unavailableMessage))
        let loggedOut = resultLine("Not logged in · Please run /login", isError: true)
        let failed = await sweep(recorder) { loggedOut }.check(Self.input)
        #expect(failed.verdict == .unavailable(InstantSweep.signedOutMessage))
        let blank = InstantSweepInput(request: "   ", screenshotPNGBase64: nil, memory: "", recent: [])
        let empty = await sweep(recorder) { Self.smallJSON }.check(blank)
        #expect(empty.verdict == .unavailable(InstantSweep.unavailableMessage))
    }

    @Test("the log has the verdict and timing, never the request, memory or project")
    func logging() async {
        let recorder = Recorder()
        let output = resultLine(Self.smallJSON)
        _ = await sweep(recorder) { output }.check(Self.input)
        #expect(recorder.lines.count == 1)
        let line = recorder.lines.first ?? ""
        #expect(line.contains("small"))
        for secret in ["invoice", "Sundial", "sundial", "round", "Save"] {
            #expect(!line.contains(secret), "\(secret)")
        }
    }

    // MARK: The process, with a stand-in for Claude Code

    private func fakeClaude(printing text: String, sleep: Int = 0) throws -> (path: String, dir: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fake-sweep-claude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" > "\(dir.path)/args"
        cat > "\(dir.path)/stdin"
        sleep \(sleep)
        cat <<'OUT'
        \(text)
        OUT
        """
        let path = dir.appendingPathComponent("claude").path
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return (path, dir)
    }

    @Test("the real run feeds the message on stdin and reads what Claude Code printed")
    func realRun() async throws {
        let fake = try fakeClaude(printing: resultLine(Self.smallJSON))
        defer { try? FileManager.default.removeItem(at: fake.dir) }
        let run = InstantSweep.claudeCode(executable: fake.path, configDirectory: fake.dir.path, timeout: .seconds(10))
        let result = await InstantSweep(run: run, log: { _ in }).check(Self.input)
        #expect(result.verdict == .small)
        let stdin = try Data(contentsOf: fake.dir.appendingPathComponent("stdin"))
        #expect(stdin == InstantSweepPrompt.input(for: Self.input))
        let args = try String(contentsOf: fake.dir.appendingPathComponent("args"), encoding: .utf8)
        #expect(args.contains("--disable-slash-commands"))
        #expect(!args.contains("invoice"))
    }

    @Test("no Claude Code, or one too slow, reads as unavailable")
    func realRunFailures() async throws {
        let missing = InstantSweep(run: InstantSweep.claudeCode(executable: nil, configDirectory: "/nonexistent"),
                                   log: { _ in })
        #expect(await missing.check(Self.input).verdict == .unavailable(InstantSweep.missingMessage))
        let fake = try fakeClaude(printing: "{}", sleep: 5)
        defer { try? FileManager.default.removeItem(at: fake.dir) }
        let slow = InstantSweep(run: InstantSweep.claudeCode(executable: fake.path, configDirectory: fake.dir.path,
                                                              timeout: .seconds(1)), log: { _ in })
        #expect(await slow.check(Self.input).verdict == .unavailable(InstantSweep.unavailableMessage))
    }
}
