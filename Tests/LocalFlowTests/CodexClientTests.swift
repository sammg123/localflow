import Foundation
import Testing
@testable import LocalFlow

@Suite("Ask through ChatGPT (the Codex tool)")
struct CodexClientTests {
    private let body = OllamaChatBody.ask(
        model: "gpt-6-sol", question: "what about the second one?",
        imageBase64: Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString(),
        history: [AskTurn(question: "which is biggest?", answer: "The first bar, at 42.")]
    )

    /// A stand-in `codex` that answers without any network: it writes `answer` to the
    /// file after --output-last-message and records its arguments and stdin.
    private func fakeCodex(answer: String = "The second bar is 17.", exitCode: Int = 0,
                           stderr: String = "", sleep: Int = 0) throws -> (path: String, dir: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fake-codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" > "\(dir.path)/args"
        cat > "\(dir.path)/stdin"
        out=""
        image=""
        prev=""
        for a in "$@"; do
          [ "$prev" = "--output-last-message" ] && out="$a"
          [ "$prev" = "--image" ] && image="$a"
          prev="$a"
        done
        [ -f "$image" ] && cp "$image" "\(dir.path)/image"
        sleep \(sleep)
        printf '%s' '\(stderr)' >&2
        [ \(exitCode) -eq 0 ] && printf '%s' '\(answer)' > "$out"
        exit \(exitCode)
        """
        let path = dir.appendingPathComponent("codex").path
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return (path, dir)
    }

    private func collect(_ client: CodexClient) async throws -> String {
        var answer = ""
        for try await chunk in client.stream(body) { answer += chunk }
        return answer
    }

    @Test("the prompt carries the instructions, the chat so far and the question")
    func prompt() {
        let prompt = CodexPrompt.make(from: body)
        #expect(prompt.contains("screenshot of the user's screen"))
        #expect(prompt.contains("Do not run commands"))
        #expect(prompt.contains("which is biggest?"))
        #expect(prompt.contains("The first bar, at 42."))
        #expect(prompt.hasSuffix("what about the second one?"))
    }

    @Test("a first question has no earlier-chat section")
    func promptWithoutHistory() {
        let fresh = OllamaChatBody.ask(model: "m", question: "what is this?", imageBase64: "")
        #expect(!CodexPrompt.make(from: fresh).contains("Earlier in this chat"))
    }

    @Test("runs isolated: no user config, no saved session, read-only, the model, the image")
    func arguments() {
        let args = CodexInvocation.arguments(model: "gpt-6-sol", imagePath: "/t/screen.png",
                                             outputPath: "/t/answer.txt", workingDirectory: "/t")
        #expect(args.first == "exec")
        for flag in ["--ephemeral", "--ignore-user-config", "--ignore-rules", "--skip-git-repo-check"] {
            #expect(args.contains(flag))
        }
        #expect(args.adjacentPair("--sandbox", "read-only"))
        #expect(args.adjacentPair("--model", "gpt-6-sol"))
        #expect(args.adjacentPair("--image", "/t/screen.png"))
        #expect(args.adjacentPair("--output-last-message", "/t/answer.txt"))
        #expect(args.adjacentPair("--cd", "/t"))
        // The prompt comes on stdin, and never right after --image (which takes a list).
        #expect(args.last == "-")
        #expect(args[args.count - 2] != "/t/screen.png")
    }

    @Test("answers with what the tool wrote, sending the screenshot and the prompt")
    func answers() async throws {
        let fake = try fakeCodex()
        let answer = try await collect(CodexClient(executable: fake.path, model: "gpt-6-sol"))

        #expect(answer == "The second bar is 17.")
        let stdin = try String(contentsOf: fake.dir.appendingPathComponent("stdin"), encoding: .utf8)
        #expect(stdin.hasSuffix("what about the second one?"))
        let image = try Data(contentsOf: fake.dir.appendingPathComponent("image"))
        #expect(image == Data([0x89, 0x50, 0x4E, 0x47]))
    }

    @Test("leaves nothing behind: the screenshot is deleted after the answer")
    func cleansUp() async throws {
        let fake = try fakeCodex()
        _ = try await collect(CodexClient(executable: fake.path, model: "gpt-6-sol"))
        let args = try String(contentsOf: fake.dir.appendingPathComponent("args"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        let imageIndex = try #require(args.firstIndex(of: "--image"))
        #expect(!FileManager.default.fileExists(atPath: args[imageIndex + 1]))
    }

    @Test("signed out of ChatGPT says how to sign in")
    func signedOut() async throws {
        let fake = try fakeCodex(exitCode: 1, stderr: "Error: Not logged in. Run codex login")
        await #expect(throws: AskError.chatGPTSignedOut) {
            try await collect(CodexClient(executable: fake.path, model: "gpt-6-sol"))
        }
    }

    @Test("any other failure passes on the tool's last line")
    func otherFailure() async throws {
        let fake = try fakeCodex(exitCode: 1, stderr: "starting\nmodel gpt-x is not supported")
        await #expect(throws: AskError.chatGPT("model gpt-x is not supported")) {
            try await collect(CodexClient(executable: fake.path, model: "gpt-x"))
        }
    }

    @Test("no Codex tool on this Mac says where to get it")
    func missingTool() async throws {
        await #expect(throws: AskError.chatGPTMissing) {
            try await collect(CodexClient(executable: nil, model: "gpt-6-sol"))
        }
    }

    @Test("a stuck run is stopped at the time limit")
    func timesOut() async throws {
        let fake = try fakeCodex(sleep: 5)
        let started = ContinuousClock.now
        await #expect(throws: AskError.timedOut) {
            try await collect(CodexClient(executable: fake.path, model: "gpt-6-sol", timeout: .milliseconds(300)))
        }
        #expect(started.duration(to: .now) < .seconds(3))
    }

    @Test("the engine setting picks the client and the model name")
    @MainActor
    func engineChoice() {
        #expect(AskEngine.local.defaultModel == "qwen3.5:9b")
        #expect(AskEngine.chatGPT.defaultModel == "gpt-6-sol")
    }
}

private extension Array where Element == String {
    func adjacentPair(_ flag: String, _ value: String) -> Bool {
        guard let i = firstIndex(of: flag), i + 1 < count else { return false }
        return self[i + 1] == value
    }
}
