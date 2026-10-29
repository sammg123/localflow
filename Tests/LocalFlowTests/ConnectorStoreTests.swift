import Foundation
import Testing
@testable import LocalFlow

/// Secrets in memory, so tests never touch the keychain.
final class FakeConnectorSecrets: ConnectorSecrets, @unchecked Sendable {
    private let lock = NSLock()
    private let failsToSave: Bool
    private var stored: [UUID: String] = [:]

    init(failsToSave: Bool = false) {
        self.failsToSave = failsToSave
    }

    var all: [UUID: String] {
        lock.withLock { stored }
    }

    func secret(for id: UUID) -> String? {
        lock.withLock { stored[id] }
    }

    func save(_ secret: String, for id: UUID) throws {
        if failsToSave { throw ConnectorProblem.keychain(-25_293) }
        lock.withLock { stored[id] = secret }
    }

    func remove(for id: UUID) throws {
        _ = lock.withLock { stored.removeValue(forKey: id) }
    }
}

/// What was logged, and how many times gh was asked.
final class ConnectorTestRecord: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private var asks = 0

    var logged: String { lock.withLock { lines.joined(separator: "\n") } }
    var gitHubAsks: Int { lock.withLock { asks } }

    func log(_ line: String) { lock.withLock { lines.append(line) } }
    func askedGitHub() { lock.withLock { asks += 1 } }
}

@Suite("Connectors: the store")
@MainActor
final class ConnectorStoreTests {
    private let suiteName = "LocalFlowTests.connectors." + UUID().uuidString
    private let defaults: UserDefaults
    private let secrets = FakeConnectorSecrets()
    private let record = ConnectorTestRecord()

    private static let linear = ConnectorDraft(name: "Linear", transport: .remote(url: "https://mcp.example.com/mcp"),
                                               secret: .token("lin_test"))
    private static let files = ConnectorDraft(name: "Files", transport: .local(command: "npx", arguments: ["-y", "server"]),
                                              secret: .environment(name: "API_KEY", value: "sk_test"))

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suiteName))
    }

    deinit {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    private func makeStore(gitHubToken: String? = "gho_test", secrets: (any ConnectorSecrets)? = nil) -> ConnectorStore {
        let record = record
        return ConnectorStore(defaults: defaults, secrets: secrets ?? self.secrets,
                              gitHubCLIToken: {
                                  record.askedGitHub()
                                  return gitHubToken
                              },
                              isExecutable: { $0 == "/opt/tools/server" },
                              log: { record.log($0) })
    }

    // MARK: Saving

    @Test("connectors are saved under their own key without their secrets, and read back")
    func roundTrip() throws {
        let store = makeStore()
        let added = try store.add(Self.linear)
        #expect(ConnectorStore.defaultsKey == "connectors")
        let saved = try #require(defaults.data(forKey: "connectors"))
        #expect(!String(decoding: saved, as: UTF8.self).contains("lin_test"))
        #expect(secrets.all == [added.id: "lin_test"])
        #expect(makeStore().connectors == [added])
        #expect(added.name == "Linear")
        #expect(added.serverName == "linear")
        #expect(added.transport == .remote(url: try #require(URL(string: "https://mcp.example.com/mcp"))))
        #expect(added.auth == .bearerToken)
        #expect(added.isEnabled)
        #expect(added.detail == "mcp.example.com/mcp")
        #expect(try store.add(Self.files).detail == "npx -y server")
        let local = try store.add(ConnectorDraft(name: "Dev", transport: .remote(url: "http://localhost:3000/mcp"),
                                                 secret: .noSecret))
        #expect(local.detail == "http://localhost:3000/mcp")
        let keyed = try store.add(ConnectorDraft(name: "Keyed", transport: .remote(url: "https://k.example.com/mcp?key=k_test#x"),
                                                 secret: .noSecret))
        #expect(keyed.detail == "k.example.com/mcp")
    }

    @Test("names are trimmed and server names stay unique")
    func uniqueNames() throws {
        let store = makeStore()
        let first = try store.add(GitHubConnector.draft(token: nil))
        let second = try store.add(GitHubConnector.draft(token: "ghp_test"))
        let trimmed = try store.add(ConnectorDraft(name: "  Notes  ", transport: .remote(url: "https://n.example.com"),
                                                   secret: .noSecret))
        #expect([first.serverName, second.serverName] == ["github", "github-2"])
        #expect(trimmed.name == "Notes")
        #expect(store.connectors.map(\.id) == [first.id, second.id, trimmed.id])
    }

    @Test("bad input is turned down before anything is saved", arguments: [
        (ConnectorDraft(name: "  ", transport: .remote(url: "https://x.example.com"), secret: .noSecret),
         ConnectorProblem.emptyName),
        (ConnectorDraft(name: "X", transport: .remote(url: "http://x.example.com"), secret: .noSecret), .notHTTPS),
        (ConnectorDraft(name: "X", transport: .remote(url: "https://x.example.com"), secret: .token("a b")), .badSecret),
        (ConnectorDraft(name: "X", transport: .remote(url: "https://x.example.com"), secret: .token(" ")), .missingSecret),
        (ConnectorDraft(name: "X", transport: .local(command: "npx", arguments: []),
                        secret: .environment(name: "API_KEY", value: "")), .missingSecret),
        (ConnectorDraft(name: "X", transport: .local(command: "npx", arguments: []),
                        secret: .environment(name: "", value: "sk_test")), .missingEnvironmentName),
        (ConnectorDraft(name: "X", transport: .local(command: "npx", arguments: []),
                        secret: .environment(name: "MY-KEY", value: "sk_test")), .badEnvironmentName),
        (ConnectorDraft(name: "X", transport: .local(command: "npx -y", arguments: []), secret: .noSecret), .badCommand),
        (ConnectorDraft(name: "X", transport: .remote(url: "https://x.example.com"), secret: .gitHubCLI),
         .gitHubCLIOnlyForGitHub),
        (ConnectorDraft(name: "X", transport: .local(command: "npx", arguments: []), secret: .gitHubCLI),
         .gitHubCLIOnlyForGitHub),
        (ConnectorDraft(name: "X", transport: .local(command: "npx", arguments: []), secret: .token("t")), .wrongSecretKind),
        (ConnectorDraft(name: "X", transport: .remote(url: "https://x.example.com"),
                        secret: .environment(name: "API_KEY", value: "t")), .wrongSecretKind),
    ])
    func badInput(draft: ConnectorDraft, problem: ConnectorProblem) {
        let store = makeStore()
        #expect(throws: problem) { try store.add(draft) }
        #expect(store.connectors.isEmpty)
        #expect(secrets.all.isEmpty)
        #expect(makeStore().connectors.isEmpty)
    }

    @Test("a secret the keychain won't take adds nothing")
    func keychainFailure() {
        let store = makeStore(secrets: FakeConnectorSecrets(failsToSave: true))
        #expect(throws: ConnectorProblem.keychain(-25_293)) { try store.add(Self.linear) }
        #expect(store.connectors.isEmpty)
        #expect(makeStore().connectors.isEmpty)
    }

    @Test("turning a connector off is saved")
    func turnOff() throws {
        let store = makeStore()
        let added = try store.add(Self.linear)
        store.setEnabled(false, for: added.id)
        #expect(store.connectors.first?.isEnabled == false)
        #expect(makeStore().connectors.first?.isEnabled == false)
    }

    @Test("removing a connector deletes its secret")
    func removeDeletesSecret() throws {
        let store = makeStore()
        let added = try store.add(Self.linear)
        let kept = try store.add(Self.files)
        store.remove(added.id)
        #expect(store.connectors == [kept])
        #expect(secrets.all == [kept.id: "sk_test"])
        #expect(makeStore().connectors == [kept])
    }

    @Test("an update is checked like an add, keeps the server name, and a blank secret keeps the old one")
    func update() throws {
        let store = makeStore()
        let added = try store.add(Self.linear)
        let renamed = ConnectorDraft(name: "Linear Work", transport: .remote(url: "https://work.example.com/mcp"),
                                     secret: .token(""))
        try store.update(added.id, with: renamed)
        let updated = try #require(store.connectors.first)
        #expect(updated.name == "Linear Work")
        #expect(updated.serverName == "linear")
        #expect(secrets.all == [added.id: "lin_test"])

        let bad = ConnectorDraft(name: "Linear", transport: .remote(url: "http://x.example.com"), secret: .noSecret)
        #expect(throws: ConnectorProblem.notHTTPS) { try store.update(added.id, with: bad) }
        #expect(store.connectors == [updated])

        let open = ConnectorDraft(name: "Linear", transport: .remote(url: "https://x.example.com"), secret: .noSecret)
        try store.update(added.id, with: open)
        #expect(store.connectors.first?.auth == ConnectorAuth.noSecret)
        #expect(secrets.all.isEmpty)
        #expect(throws: ConnectorProblem.notFound) { try store.update(UUID(), with: open) }
    }

    @Test("an update to another kind of secret needs the new secret, not the old one")
    func updateSwitchingKind() throws {
        let store = makeStore()
        let files = try store.add(Self.files)
        let remote = ConnectorDraft(name: "Files", transport: .remote(url: "https://f.example.com"), secret: .token(""))
        #expect(throws: ConnectorProblem.missingSecret) { try store.update(files.id, with: remote) }
        #expect(secrets.all == [files.id: "sk_test"])
        try store.update(files.id, with: ConnectorDraft(name: "Files", transport: .remote(url: "https://f.example.com"),
                                                        secret: .token("tok_test")))
        #expect(secrets.all == [files.id: "tok_test"])
        #expect(store.connectors.first?.auth == .bearerToken)
    }

    @Test("one connector that can't be read doesn't take the rest with it")
    func lenientLoad() throws {
        let url = try #require(URL(string: "https://n.example.com"))
        let good = Connector(id: UUID(), name: "Notes", serverName: "notes", transport: .remote(url: url),
                             auth: .noSecret, isEnabled: true)
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode([good])) as? [[String: Any]])
        let future = encoded[0].merging(["id": UUID().uuidString, "serverName": "later",
                                         "transport": ["satellite": ["band": "ka"]]]) { _, new in new }
        defaults.set(try JSONSerialization.data(withJSONObject: [future] + encoded), forKey: "connectors")
        #expect(makeStore().connectors == [good])
    }

    @Test("connectors read back from settings are checked again")
    func tamperedSettings() throws {
        let url = try #require(URL(string: "https://evil.example.com"))
        let good = Connector(id: UUID(), name: "Notes", serverName: "notes", transport: .remote(url: url),
                             auth: .noSecret, isEnabled: true)
        let unsound = [
            Connector(id: UUID(), name: "Screen", serverName: "localflow", transport: .remote(url: url), auth: .noSecret,
                      isEnabled: true),
            Connector(id: UUID(), name: "Twin", serverName: "notes", transport: .remote(url: url), auth: .noSecret,
                      isEnabled: true),
            Connector(id: UUID(), name: "Leak", serverName: "leak", transport: .remote(url: url), auth: .gitHubCLI,
                      isEnabled: true),
            Connector(id: UUID(), name: "Plain", serverName: "plain",
                      transport: .remote(url: try #require(URL(string: "http://example.com"))), auth: .noSecret,
                      isEnabled: true),
            Connector(id: UUID(), name: " ", serverName: "blank", transport: .remote(url: url), auth: .noSecret,
                      isEnabled: true),
            Connector(id: UUID(), name: "Run", serverName: "run", transport: .local(command: "a b", arguments: []),
                      auth: .noSecret, isEnabled: true),
        ]
        defaults.set(try JSONEncoder().encode([good] + unsound), forKey: "connectors")
        #expect(makeStore().connectors == [good])
        defaults.set(Data("not json".utf8), forKey: "connectors")
        #expect(makeStore().connectors.isEmpty)
    }

    // MARK: Servers for a session

    @Test("a remote server gets its token as a bearer header")
    func remoteServer() async throws {
        let store = makeStore()
        try store.add(GitHubConnector.draft(token: "ghp_test"))
        let servers = await store.servers()
        #expect(servers == ["github": ["type": "http", "url": "https://api.githubcopilot.com/mcp/",
                                       "headers": ["Authorization": "Bearer ghp_test"]]])
        #expect(record.gitHubAsks == 0)
    }

    @Test("a remote server with no token has no headers")
    func remoteServerOpen() async throws {
        let store = makeStore()
        try store.add(ConnectorDraft(name: "Docs", transport: .remote(url: "http://localhost:3000/mcp"), secret: .noSecret))
        #expect(await store.servers() == ["docs": ["type": "http", "url": "http://localhost:3000/mcp"]])
    }

    @Test("a local server gets its arguments, and its secret as an environment variable")
    func localServer() async throws {
        let store = makeStore()
        try store.add(Self.files)
        try store.add(ConnectorDraft(name: "Tool", transport: .local(command: "/opt/tools/server", arguments: []),
                                     secret: .noSecret))
        let servers = await store.servers()
        #expect(servers["files"] == ["type": "stdio", "command": "npx", "args": ["-y", "server"],
                                     "env": ["API_KEY": "sk_test"]])
        #expect(servers["tool"] == ["type": "stdio", "command": "/opt/tools/server", "args": []])
    }

    @Test("the GitHub CLI sign-in is asked for when a session starts, once, and never stored")
    func gitHubCLI() async throws {
        let store = makeStore(gitHubToken: "gho_test")
        try store.add(GitHubConnector.draft(token: nil))
        try store.add(GitHubConnector.draft(token: nil))
        #expect(record.gitHubAsks == 0)
        let servers = await store.servers()
        let header: AgentJSON = ["Authorization": "Bearer gho_test"]
        #expect(servers["github"]?["headers"] == header)
        #expect(servers["github-2"]?["headers"] == header)
        #expect(record.gitHubAsks == 1)
        #expect(secrets.all.isEmpty)
    }

    @Test("a connector whose secret is missing is left out")
    func missingSecret() async throws {
        let store = makeStore(gitHubToken: nil)
        let linear = try store.add(Self.linear)
        try store.add(Self.files)
        try store.add(GitHubConnector.draft(token: nil))
        try secrets.remove(for: linear.id)
        #expect(Set(await store.servers().keys) == ["files"])
    }

    @Test("a turned-off connector is left out, and gh isn't asked for one")
    func disabledSkipped() async throws {
        let store = makeStore()
        let gitHub = try store.add(GitHubConnector.draft(token: nil))
        try store.add(Self.files)
        store.setEnabled(false, for: gitHub.id)
        #expect(Set(await store.servers().keys) == ["files"])
        #expect(record.gitHubAsks == 0)
    }

    @Test("only counts are logged: no names, addresses, commands or tokens")
    func logsCountsOnly() async throws {
        let store = makeStore()
        let linear = try store.add(Self.linear)
        try store.add(Self.files)
        try store.add(GitHubConnector.draft(token: nil))
        _ = await store.servers()
        store.remove(linear.id)
        let logged = record.logged.lowercased()
        #expect(!logged.isEmpty)
        for secretOrName in ["lin_test", "sk_test", "gho_test", "linear", "files", "github", "example.com", "npx",
                             "api_key", "githubcopilot"] {
            #expect(!logged.contains(secretOrName))
        }
    }
}
