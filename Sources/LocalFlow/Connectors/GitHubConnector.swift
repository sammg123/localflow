import Foundation

/// GitHub's official remote MCP server (github/github-mcp-server), signed in with a
/// personal access token or the GitHub CLI's sign-in, sent as a bearer token.
enum GitHubConnector {
    static let name = "GitHub"
    static let address = "https://api.githubcopilot.com/mcp/"
    static let host = "api.githubcopilot.com"

    /// With a pasted token, or nil to use the GitHub CLI's sign-in.
    static func draft(token: String?) -> ConnectorDraft {
        ConnectorDraft(name: name, transport: .remote(url: address), secret: token.map { .token($0) } ?? .gitHubCLI)
    }

    /// Whether `url` is GitHub's server, the only place the GitHub CLI's token goes.
    static func isGitHub(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host(percentEncoded: false)?.lowercased() == host
            && url.user == nil && url.port == nil
    }
}

/// The GitHub CLI's sign-in for github.com, read with `gh auth token` when a session
/// starts. Never saved by LocalFlow.
enum GitHubCLI {
    static let timeout: Duration = .seconds(3)
    static let arguments = ["auth", "token", "--hostname", "github.com"]

    /// Homebrew on Apple silicon, Homebrew on Intel, then a user install.
    static func candidates(home: String) -> [String] {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", home + "/.local/bin/gh"]
    }

    static func locate(home: String = NSHomeDirectory(),
                       isExecutable: (String) -> Bool = ConnectorRules.isExecutableFile) -> String? {
        candidates(home: home).first(where: isExecutable)
    }

    /// Only what gh needs to find its sign-in. No tokens from LocalFlow's own environment.
    static func environment(home: String = NSHomeDirectory(), user: String = NSUserName()) -> [String: String] {
        ["HOME": home, "USER": user, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8",
         "GH_PROMPT_DISABLED": "1", "GH_NO_UPDATE_NOTIFIER": "1"]
    }

    /// The trimmed token, or nil when gh printed anything else.
    static func token(fromOutput output: String) -> String? {
        try? ConnectorRules.secret(output)
    }

    /// Asks gh for the token. Nil when gh isn't installed or signed in, or takes too long.
    static func token() async -> String? {
        guard let executable = locate() else { return nil }
        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let reader = ToolOutputLines(reading: output.fileHandleForReading)
        defer { reader.finish() }
        var lines: [String] = []
        let status = try? await AskTool.run(process, timeout: timeout, launchFailure: { .claude($0) },
                                            onExit: { reader.toolExited() }) {
            for await line in reader.lines { lines.append(line) }
        }
        guard status == 0 else { return nil }
        return token(fromOutput: lines.joined(separator: "\n"))
    }
}
