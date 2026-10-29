import Foundation
import Testing
@testable import LocalFlow

@Suite("Agent mode: how Claude Code is run")
struct AgentInvocationTests {
    private let home = "/Users/me"

    private func json(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("runs headless, asks LocalFlow for permission over stdio, and loads only LocalFlow's own settings")
    func arguments() {
        let args = AgentInvocation.arguments(model: "claude-sonnet-5-5", effort: "medium",
                                             mcpConfigPath: "/tmp/x/mcp.json", home: home)
        #expect(args.first == "-p")
        #expect(args.pair("--input-format", "stream-json"))
        #expect(args.pair("--output-format", "stream-json"))
        #expect(args.pair("--model", "claude-sonnet-5-5"))
        #expect(args.pair("--effort", "medium"))
        #expect(args.pair("--permission-mode", "default"))
        #expect(args.pair("--permission-prompt-tool", "stdio"))
        #expect(args.pair("--setting-sources", "user"))
        #expect(args.pair("--mcp-config", "/tmp/x/mcp.json"))
        #expect(args.pair("--add-dir", home))
        #expect(args.pair("--append-system-prompt", AgentInvocation.instructions))
        #expect(args.pair("--tools", "Bash,Read,Write,Edit,Glob,Grep,WebFetch,WebSearch,TodoWrite"))
        for flag in ["--include-partial-messages", "--verbose", "--strict-mcp-config", "--no-session-persistence"] {
            #expect(args.contains(flag))
        }
        #expect(!args.contains("--dangerously-skip-permissions"))
        #expect(!args.contains("--system-prompt"))
        #expect(!args.contains("bypassPermissions"))
    }

    @Test("a different appended prompt replaces the default instructions")
    func appendedPrompt() {
        let args = AgentInvocation.arguments(model: "m", effort: "low", mcpConfigPath: "/x", home: home,
                                             appendPrompt: "be brief")
        #expect(args.pair("--append-system-prompt", "be brief"))
    }

    @Test("the agent's shell gets a real PATH and the login shell, and still no keys from the app")
    func environment() {
        let config = ClaudeInvocation.configDirectory(home: home)
        let env = AgentInvocation.environment(home: home, user: "me", tmp: "/tmp/x", configDirectory: config,
                                              toolFolder: "/Users/me/.npm/bin", shell: "/bin/bash")
        #expect(env["HOME"] == home)
        #expect(env["USER"] == "me")
        #expect(env["CLAUDE_CONFIG_DIR"] == config)
        #expect(env["TMPDIR"] == "/tmp/x")
        #expect(env["SHELL"] == "/bin/bash")
        #expect(env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] == "1")
        #expect(env["PATH"] == "/Users/me/.npm/bin:/Users/me/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin"
            + ":/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(Set(env.keys) == ["HOME", "USER", "CLAUDE_CONFIG_DIR", "PATH", "TMPDIR", "LANG", "SHELL",
                                  "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"])
    }

    @Test("the tool's folder isn't listed twice when it's already on the PATH")
    func pathWithoutRepeats() {
        let env = AgentInvocation.environment(home: home, user: "me", tmp: "/tmp", configDirectory: "/c",
                                              toolFolder: "/Users/me/.local/bin", shell: "/bin/zsh")
        #expect(env["PATH"] == "/Users/me/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin"
            + ":/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
    }

    @Test("the login shell is a real program")
    func loginShell() {
        let shell = AgentInvocation.loginShell()
        #expect(shell.hasPrefix("/"))
        #expect(FileManager.default.isExecutableFile(atPath: shell))
    }

    @Test("works in a neutral folder LocalFlow owns, so no project settings load")
    func workingDirectory() {
        #expect(AgentInvocation.workingDirectory(home: home)
            == "/Users/me/Library/Application Support/LocalFlow/agent")
    }

    @Test("the MCP config starts LocalFlow's screen tools for one display")
    func mcpConfig() throws {
        let data = AgentInvocation.mcpConfig(executable: "/Applications/LocalFlow.app/Contents/MacOS/LocalFlow",
                                             displayID: 69_733_632)
        let servers = try #require(json(data)["mcpServers"] as? [String: Any])
        #expect(servers.count == 1)
        let localflow = try #require(servers["localflow"] as? [String: Any])
        #expect(localflow["type"] as? String == "stdio")
        #expect(localflow["command"] as? String == "/Applications/LocalFlow.app/Contents/MacOS/LocalFlow")
        #expect(localflow["args"] as? [String] == ["--computer-mcp", "--display", "69733632"])
    }

    @Test("a user turn is one line: the screenshot if there is one, then the text")
    func userMessage() throws {
        let data = AgentInvocation.userMessage(text: "open\nmail", imagePNGBase64: "iVBORw==")
        #expect(data.last == UInt8(ascii: "\n"))
        #expect(data.dropLast().firstIndex(of: UInt8(ascii: "\n")) == nil)
        let line = try json(data)
        #expect(line["type"] as? String == "user")
        let message = try #require(line["message"] as? [String: Any])
        #expect(message["role"] as? String == "user")
        let content = try #require(message["content"] as? [[String: Any]])
        #expect(content.count == 2)
        #expect(content[0]["type"] as? String == "image")
        let source = try #require(content[0]["source"] as? [String: Any])
        #expect(source["type"] as? String == "base64")
        #expect(source["media_type"] as? String == "image/png")
        #expect(source["data"] as? String == "iVBORw==")
        #expect(content[1]["type"] as? String == "text")
        #expect(content[1]["text"] as? String == "open\nmail")

        let textOnly = try json(AgentInvocation.userMessage(text: "and then?", imagePNGBase64: nil))
        let only = try #require((textOnly["message"] as? [String: Any])?["content"] as? [[String: Any]])
        #expect(only.count == 1)
        #expect(only[0]["text"] as? String == "and then?")
    }

    @Test("the host says hello first and can interrupt a turn")
    func controlRequests() throws {
        let hello = try json(AgentInvocation.initialize(requestID: "init-1"))
        #expect(hello["type"] as? String == "control_request")
        #expect(hello["request_id"] as? String == "init-1")
        #expect((hello["request"] as? [String: Any])?["subtype"] as? String == "initialize")

        let stop = try json(AgentInvocation.interrupt(requestID: "int-1"))
        #expect(stop["type"] as? String == "control_request")
        #expect(stop["request_id"] as? String == "int-1")
        #expect((stop["request"] as? [String: Any])?["subtype"] as? String == "interrupt")
    }

    @Test("allowing a tool sends its input back unchanged")
    func allow() throws {
        let input: AgentJSON = ["command": "touch a.txt", "timeout": 1.5, "count": 2, "background": false,
                                "list": [1, "two", ["three": true]], "nothing": .null]
        let data = AgentInvocation.allow(requestID: "req-1", input: input)
        #expect(data.last == UInt8(ascii: "\n"))
        let line = try json(data)
        #expect(line["type"] as? String == "control_response")
        let response = try #require(line["response"] as? [String: Any])
        #expect(response["subtype"] as? String == "success")
        #expect(response["request_id"] as? String == "req-1")
        let decision = try #require(response["response"] as? [String: Any])
        #expect(decision["behavior"] as? String == "allow")
        let echoed = try #require(decision["updatedInput"])
        #expect(AgentJSON(any: echoed) == input)
    }

    @Test("denying a tool says why")
    func deny() throws {
        let line = try json(AgentInvocation.deny(requestID: "req-2", message: "The user said no."))
        let response = try #require(line["response"] as? [String: Any])
        #expect(response["request_id"] as? String == "req-2")
        let decision = try #require(response["response"] as? [String: Any])
        #expect(decision["behavior"] as? String == "deny")
        #expect(decision["message"] as? String == "The user said no.")
        #expect(decision["updatedInput"] == nil)
    }

    @Test("the instructions cover the screen, irreversible actions, injected requests and a short reply")
    func instructions() {
        let text = AgentInvocation.instructions
        for phrase in ["LocalFlow", "mcp__localflow__", "pixels in the latest screenshot", "irreversible: true",
                       "password", "payment", "didn't ask for", "under 80 words", "terminal"] {
            #expect(text.contains(phrase), "missing \(phrase)")
        }
        #expect(!text.contains("\u{2014}")) // no em dashes
    }

    @Test("JSON values round-trip exactly, booleans staying booleans")
    func jsonRoundTrip() throws {
        let raw = #"{"a":1,"b":true,"c":[0,false,"x",null],"d":{"e":2.25},"f":"/path/with/slashes"}"#
        let value = try #require(AgentJSON.decode(Data(raw.utf8)))
        #expect(value["b"] == .bool(true))
        #expect(value["a"] == .number(1))
        #expect(value["c"]?.array?[1] == .bool(false))
        #expect(value["f"]?.string == "/path/with/slashes")
        let again = try #require(AgentJSON.decode(value.encoded()))
        #expect(again == value)
        #expect(String(decoding: value.encoded(), as: UTF8.self).contains("/path/with/slashes"))
        #expect(AgentJSON.decode(Data("nope".utf8)) == nil)
    }
}

extension Array where Element == String {
    /// `flag` appears somewhere immediately followed by `value`.
    func pair(_ flag: String, _ value: String) -> Bool {
        zip(self, dropFirst()).contains { $0 == flag && $1 == value }
    }
}
