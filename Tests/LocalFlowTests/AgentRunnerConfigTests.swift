import Foundation
import Testing
@testable import LocalFlow

@Suite("Agent mode: the MCP config, which can hold connector tokens, goes once Claude Code has read it")
final class AgentRunnerConfigTests {
    private let fakes = AgentFakeClaudes()

    @Test("the config file is removed when Claude Code says hello, and the session goes on")
    func configRemovedAfterHello() async throws {
        let fake = try fakes.make(#"""
        echo '{"type":"system","subtype":"init","session_id":"s-1"}'
        while IFS= read -r line; do :; done
        """#)
        let agent = fakes.runner(fake)
        let events = AgentEventLog(agent)
        agent.start(task: "look", imagePNGBase64: nil)
        #expect(await events.wait { if case .sessionStarted = $0 { true } else { false } } != nil)

        let folder = fake.file("folder").trimmingCharacters(in: .whitespacesAndNewlines)
        let config = folder + "/" + AgentRunner.configName
        let gone = await events.poll(seconds: 5) { FileManager.default.fileExists(atPath: config) ? nil : true }
        #expect(gone == true)
        #expect(!fake.file("mcp.json").isEmpty)
        #expect(FileManager.default.fileExists(atPath: folder + "/stderr.txt"))
        #expect(!events.all.contains { if case .ended = $0 { true } else { false } })

        agent.close()
        #expect(await events.ended() != nil)
    }

    @Test("the instructions and memory reach Claude Code in a private file, never in its arguments")
    func promptInPrivateFile() async throws {
        let fake = try fakes.make(#"""
        prev=""
        for arg in "$@"; do
          if [ "$prev" = "--append-system-prompt-file" ]; then
            cat "$arg" > "$out/prompt"
            stat -f '%Lp' "$arg" > "$out/prompt-mode"
          fi
          prev="$arg"
        done
        echo '{"type":"system","subtype":"init","session_id":"s-1"}'
        while IFS= read -r line; do :; done
        """#)
        let agent = fakes.runner(fake, options: AgentRunOptions(appendPrompt: "Instructions\n\nNorthwind: app.northwind.example"))
        let events = AgentEventLog(agent)
        agent.start(task: "look", imagePNGBase64: nil)
        #expect(await events.wait { if case .sessionStarted = $0 { true } else { false } } != nil)

        #expect(fake.file("prompt") == "Instructions\n\nNorthwind: app.northwind.example")
        #expect(fake.file("prompt-mode").trimmingCharacters(in: .whitespacesAndNewlines) == "600")
        #expect(!fake.file("args").contains("Northwind"))

        agent.close()
        #expect(await events.ended() != nil)
    }
}
