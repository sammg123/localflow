import Foundation
import Testing
@testable import LocalFlow

@Suite("Connectors: names, addresses and commands")
struct ConnectorRulesTests {
    // MARK: Server names

    @Test("a server name is the name in lowercase letters, digits and dashes", arguments: [
        ("GitHub", "github"), ("My Server!", "my-server"), ("  Linear  ", "linear"), ("Café Notes", "caf-notes"),
        ("a__b", "a-b"), ("--x--", "x"), ("Jira 2", "jira-2"),
    ])
    func serverNameSanitized(name: String, expected: String) {
        #expect(ConnectorRules.serverName(for: name, taken: []) == expected)
    }

    @Test("a name with nothing usable still gets a server name", arguments: ["!!!", "東京", "   "])
    func serverNameFallback(name: String) {
        #expect(ConnectorRules.serverName(for: name, taken: []) == "connector")
    }

    @Test("server names are unique")
    func serverNameUnique() {
        #expect(ConnectorRules.serverName(for: "GitHub", taken: ["github"]) == "github-2")
        #expect(ConnectorRules.serverName(for: "GitHub", taken: ["github", "github-2"]) == "github-3")
        #expect(ConnectorRules.serverName(for: "GitHub", taken: ["linear"]) == "github")
    }

    @Test("no connector can be the screen tools' server")
    func serverNameNeverLocalFlow() {
        #expect(ConnectorRules.serverName(for: "LocalFlow", taken: []) == "localflow-2")
        #expect(ConnectorRules.serverName(for: " localflow ", taken: ["localflow-2"]) == "localflow-3")
        #expect(!ConnectorRules.isValidServerName(AgentInvocation.serverName))
    }

    @Test("long names are cut short, never ending on a dash")
    func serverNameLength() {
        let long = ConnectorRules.serverName(for: String(repeating: "a", count: 80), taken: [])
        #expect(long.count == ConnectorRules.maxServerNameLength)
        let short = ConnectorRules.maxServerNameLength - 1
        let cut = ConnectorRules.serverName(for: String(repeating: "a", count: short) + " b", taken: [])
        #expect(cut == String(repeating: "a", count: short))
        #expect(ConnectorRules.maxServerNameLength <= 20)
        let numbered = ConnectorRules.serverName(for: String(repeating: "a", count: 80), taken: [long])
        #expect(numbered.count <= ConnectorRules.maxServerNameLength)
        #expect(numbered.hasSuffix("-2"))
    }

    @Test("server names read back from settings are checked", arguments: [
        ("github", true), ("jira-2", true), ("", false), ("Git", false), ("a__b", false), ("a_b", false),
        ("-a", false), ("a-", false), ("localflow", false),
    ])
    func serverNameValid(name: String, valid: Bool) {
        #expect(ConnectorRules.isValidServerName(name) == valid)
    }

    // MARK: Addresses

    @Test("remote servers use https", arguments: [
        "https://api.githubcopilot.com/mcp/", "https://mcp.example.com", "  https://x.example.com/mcp  ",
    ])
    func httpsAddress(text: String) throws {
        let url = try ConnectorRules.remoteURL(text)
        #expect(url.absoluteString == text.trimmingCharacters(in: .whitespaces))
    }

    @Test("plain http only for a server on this Mac", arguments: ["http://localhost:3000/mcp", "http://127.0.0.1:8080"])
    func localHTTP(text: String) throws {
        #expect(try ConnectorRules.remoteURL(text).absoluteString == text)
    }

    @Test("other addresses are turned down", arguments: [
        ("http://example.com/mcp", ConnectorProblem.notHTTPS), ("http://localhost.example.com", .notHTTPS),
        ("ftp://example.com", .notHTTPS), ("example.com", .badURL), ("", .badURL), ("https://", .badURL),
        ("https://exa mple.com", .badURL), ("https://user:pw@example.com/mcp", .credentialsInURL),
        (#"https://evil.example.com\@api.githubcopilot.com/mcp/"#, .badURL), ("https://例え.jp/mcp", .badURL),
    ])
    func badAddress(text: String, problem: ConnectorProblem) {
        #expect(throws: problem) { try ConnectorRules.remoteURL(text) }
    }

    // MARK: Commands

    @Test("a command is a full path to a program or a plain command name")
    func goodCommands() throws {
        let program = "/opt/tools/server"
        let isProgram: (String) -> Bool = { $0 == program }
        #expect(try ConnectorRules.command("npx", isExecutable: isProgram) == "npx")
        #expect(try ConnectorRules.command(" uvx ", isExecutable: isProgram) == "uvx")
        #expect(try ConnectorRules.command("my-server_2.1", isExecutable: isProgram) == "my-server_2.1")
        #expect(try ConnectorRules.command(program, isExecutable: isProgram) == program)
    }

    @Test("other commands are turned down", arguments: [
        "", "npx -y server", "../server", "./server", "-rf", "rm;ls", "/opt/tools/missing", "server/bin", "~/bin/server",
        "$(evil)", "..", ".",
    ])
    func badCommands(text: String) {
        #expect(throws: ConnectorProblem.badCommand) {
            try ConnectorRules.command(text, isExecutable: { $0 == "/opt/tools/server" })
        }
    }

    @Test("a folder isn't a program")
    func folderIsNotProgram() {
        #expect(!ConnectorRules.isExecutableFile("/usr/bin"))
        #expect(ConnectorRules.isExecutableFile("/bin/sh"))
    }

    @Test("arguments split on spaces, with quotes keeping spaces in")
    func arguments() {
        #expect(ConnectorRules.arguments(from: #"-y @scope/server "/Users/me/My Files""#)
            == ["-y", "@scope/server", "/Users/me/My Files"])
        #expect(ConnectorRules.arguments(from: "'a b'  c") == ["a b", "c"])
        #expect(ConnectorRules.arguments(from: #"--name="" x"#) == ["--name=", "x"])
        #expect(ConnectorRules.arguments(from: "   ") == [])
        #expect(ConnectorRules.arguments(from: #"-y "my server"#) == nil)
    }

    // MARK: Secrets

    @Test("environment variable names", arguments: [
        ("GITHUB_TOKEN", true), ("API_KEY_2", true), ("_X", true), ("", false), ("2X", false), ("MY-KEY", false),
        ("A B", false), ("KEY=", false), ("PATH", false), ("HOME", false), ("DYLD_INSERT_LIBRARIES", false),
        ("LD_PRELOAD", false), ("NODE_OPTIONS", false), ("path", true),
    ])
    func environmentName(name: String, valid: Bool) {
        if valid {
            #expect((try? ConnectorRules.environmentName(name)) == name)
        } else {
            #expect(throws: ConnectorProblem.self) { try ConnectorRules.environmentName(name) }
        }
    }

    @Test("variables that change how programs run can't hold a secret")
    func reservedEnvironmentNames() {
        #expect(throws: ConnectorProblem.reservedEnvironmentName) { try ConnectorRules.environmentName("PATH") }
        #expect(throws: ConnectorProblem.reservedEnvironmentName) { try ConnectorRules.environmentName("DYLD_X") }
        #expect(throws: ConnectorProblem.badEnvironmentName) { try ConnectorRules.environmentName("MY-KEY") }
    }

    @Test("a secret is trimmed and can't hold spaces or line breaks")
    func secrets() throws {
        #expect(try ConnectorRules.secret("  ghp_test \n") == "ghp_test")
        #expect(throws: ConnectorProblem.badSecret) { try ConnectorRules.secret("ghp test") }
        #expect(throws: ConnectorProblem.badSecret) { try ConnectorRules.secret("ghp_test\r\nX-Other: 1") }
        #expect(throws: ConnectorProblem.missingSecret) { try ConnectorRules.secret("   ") }
    }

    @Test("every problem reads as a plain sentence")
    func problemMessages() {
        let problems: [ConnectorProblem] = [.emptyName, .badURL, .notHTTPS, .credentialsInURL, .badCommand,
                                            .badEnvironmentName, .missingEnvironmentName, .missingSecret, .badSecret,
                                            .gitHubCLIOnlyForGitHub, .wrongSecretKind, .keychain(-25_293), .notFound,
                                            .reservedEnvironmentName, .badArguments]
        for problem in problems {
            #expect(problem.errorDescription?.hasSuffix(".") == true)
        }
    }

    // MARK: The add form

    @Test("the add form turns its fields into a draft")
    func addFormDrafts() throws {
        let gitHubCLI = ConnectorFields(kind: .gitHub, secret: "ignored")
        #expect(try gitHubCLI.draft() == GitHubConnector.draft(token: nil))
        let gitHubToken = ConnectorFields(kind: .gitHub, usesGitHubCLI: false, secret: "ghp_test")
        #expect(try gitHubToken.draft() == GitHubConnector.draft(token: "ghp_test"))

        let open = ConnectorFields(kind: .url, name: "Docs", url: "https://d.example.com", secret: "  ")
        #expect(try open.draft() == ConnectorDraft(name: "Docs", transport: .remote(url: "https://d.example.com"),
                                             secret: .noSecret))
        let withToken = ConnectorFields(kind: .url, name: "Docs", url: "https://d.example.com", secret: "tok_test")
        #expect(try withToken.draft().secret == .token("tok_test"))

        let command = ConnectorFields(kind: .command, name: "Files", command: "npx", arguments: "-y 'my server'")
        #expect(try command.draft() == ConnectorDraft(name: "Files", transport: .local(command: "npx", arguments: ["-y", "my server"]),
                                                secret: .noSecret))
        let variableOnly = ConnectorFields(kind: .command, name: "Files", command: "npx", variable: "API_KEY")
        #expect(try variableOnly.draft().secret == .environment(name: "API_KEY", value: ""))
        let withSecret = ConnectorFields(kind: .command, name: "Files", command: "npx", secret: "sk_test",
                                         variable: "API_KEY")
        #expect(try withSecret.draft().secret == .environment(name: "API_KEY", value: "sk_test"))
        let openQuote = ConnectorFields(kind: .command, name: "Files", command: "npx", arguments: #"-y "my server"#)
        #expect(throws: ConnectorProblem.badArguments) { try openQuote.draft() }
    }

    @Test("each kind of connector has its own add button")
    func addFormKinds() {
        #expect(ConnectorFields.Kind.allCases.map(\.addTitle) == ["Add GitHub", "Add by URL", "Add a command"])
        #expect(ConnectorFields().kind == .gitHub)
        #expect(ConnectorFields().usesGitHubCLI)
    }

    // MARK: GitHub

    @Test("the GitHub preset is GitHub's own remote server")
    func gitHubPreset() {
        #expect(GitHubConnector.draft(token: nil)
            == ConnectorDraft(name: "GitHub", transport: .remote(url: "https://api.githubcopilot.com/mcp/"),
                              secret: .gitHubCLI))
        #expect(GitHubConnector.draft(token: "ghp_test").secret == .token("ghp_test"))
    }

    @Test("the GitHub CLI's token is its trimmed output, or nothing")
    func gitHubCLIOutput() {
        #expect(GitHubCLI.token(fromOutput: "gho_test\n") == "gho_test")
        #expect(GitHubCLI.token(fromOutput: "") == nil)
        #expect(GitHubCLI.token(fromOutput: "  \n") == nil)
        #expect(GitHubCLI.token(fromOutput: "no oauth token found\nfor github.com") == nil)
    }

    @Test("gh is looked for where Homebrew and user installs put it")
    func gitHubCLILocation() {
        let home = "/Users/me"
        #expect(GitHubCLI.locate(home: home, isExecutable: { _ in true }) == "/opt/homebrew/bin/gh")
        #expect(GitHubCLI.locate(home: home, isExecutable: { $0 == "/usr/local/bin/gh" }) == "/usr/local/bin/gh")
        #expect(GitHubCLI.locate(home: home, isExecutable: { $0 == "/Users/me/.local/bin/gh" })
            == "/Users/me/.local/bin/gh")
        #expect(GitHubCLI.locate(home: home, isExecutable: { _ in false }) == nil)
    }

    @Test("gh is asked for github.com's token only, with a clean environment and a short time limit")
    func gitHubCLIRun() {
        #expect(GitHubCLI.arguments == ["auth", "token", "--hostname", "github.com"])
        #expect(GitHubCLI.timeout <= .seconds(3))
        let environment = GitHubCLI.environment(home: "/Users/me", user: "me")
        #expect(environment["HOME"] == "/Users/me")
        #expect(environment["GH_PROMPT_DISABLED"] == "1")
        #expect(environment["GH_TOKEN"] == nil)
        #expect(environment["GITHUB_TOKEN"] == nil)
    }
}
