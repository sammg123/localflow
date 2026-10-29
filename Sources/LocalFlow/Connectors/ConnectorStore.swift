import Combine
import Foundation

/// The user's connectors. The list is saved in UserDefaults without secrets; secrets are
/// only in the keychain. `servers()` gives Claude Code's MCP entries for a new session.
/// Logs counts only, never names, addresses, commands or tokens.
@MainActor
final class ConnectorStore: ObservableObject {
    static let shared = ConnectorStore()
    static let defaultsKey = "connectors"

    @Published private(set) var connectors: [Connector]

    private let defaults: UserDefaults
    private let secrets: any ConnectorSecrets
    private let gitHubCLIToken: @Sendable () async -> String?
    private let isExecutable: @Sendable (String) -> Bool
    private let log: @Sendable (String) -> Void

    init(defaults: UserDefaults = .standard, secrets: any ConnectorSecrets = KeychainConnectorSecrets(),
         gitHubCLIToken: @escaping @Sendable () async -> String? = { await GitHubCLI.token() },
         isExecutable: @escaping @Sendable (String) -> Bool = { ConnectorRules.isExecutableFile($0) },
         log: @escaping @Sendable (String) -> Void = { FlowLog.shared.write($0) }) {
        self.defaults = defaults
        self.secrets = secrets
        self.gitHubCLIToken = gitHubCLIToken
        self.isExecutable = isExecutable
        self.log = log
        connectors = Self.load(from: defaults, log: log)
    }

    // MARK: Changing the list

    /// Checks the draft, keeps its secret in the keychain, then saves it, turned on.
    @discardableResult
    func add(_ draft: ConnectorDraft) throws -> Connector {
        let id = UUID()
        let serverName = ConnectorRules.serverName(for: draft.name, taken: Set(connectors.map(\.serverName)))
        let (connector, secret) = try ConnectorRules.check(draft, id: id, serverName: serverName, isEnabled: true,
                                                           hasStoredSecret: false, isExecutable: isExecutable)
        if let secret { try secrets.save(secret, for: id) }
        save(connectors + [connector])
        log("connectors: added one, \(connectors.count) in all")
        return connector
    }

    /// Checked like an add. The server name stays, and a blank secret keeps the saved one.
    func update(_ id: UUID, with draft: ConnectorDraft) throws {
        guard let old = connectors.first(where: { $0.id == id }) else { throw ConnectorProblem.notFound }
        let hasStoredSecret = old.auth.keepsSecret(for: draft.secret) && secrets.secret(for: id) != nil
        let (connector, secret) = try ConnectorRules.check(draft, id: id, serverName: old.serverName,
                                                           isEnabled: old.isEnabled, hasStoredSecret: hasStoredSecret,
                                                           isExecutable: isExecutable)
        if let secret { try secrets.save(secret, for: id) }
        if !connector.auth.isStored { removeSecret(of: id) }
        save(connectors.map { $0.id == id ? connector : $0 })
        log("connectors: updated one")
    }

    func setEnabled(_ isEnabled: Bool, for id: UUID) {
        save(connectors.map { $0.id == id ? $0.enabled(isEnabled) : $0 })
    }

    /// Removes the connector and its secret.
    func remove(_ id: UUID) {
        guard connectors.contains(where: { $0.id == id }) else { return }
        save(connectors.filter { $0.id != id })
        removeSecret(of: id)
        log("connectors: removed one, \(connectors.count) left")
    }

    // MARK: A session

    /// Claude Code's MCP entries for the connectors that are on, by server name. One
    /// whose secret is missing (a removed keychain item, gh not signed in) is left out.
    func servers() async -> [String: AgentJSON] {
        let enabled = connectors.filter(\.isEnabled)
        let servers = await ConnectorConfig.servers(for: enabled, secrets: secrets, gitHubCLIToken: gitHubCLIToken)
        log("connectors: \(servers.count) of \(enabled.count) turned on are ready")
        return servers
    }

    // MARK: Saving

    private func save(_ list: [Connector]) {
        connectors = list
        do {
            defaults.set(try JSONEncoder().encode(list), forKey: Self.defaultsKey)
        } catch {
            log("connectors: couldn't save the list")
        }
    }

    private func removeSecret(of id: UUID) {
        do {
            try secrets.remove(for: id)
        } catch {
            log("connectors: couldn't remove a secret (\(error))")
        }
    }

    /// The saved list, keeping only connectors that still check out, first of each name.
    private static func load(from defaults: UserDefaults, log: (String) -> Void) -> [Connector] {
        guard let data = defaults.data(forKey: defaultsKey) else { return [] }
        guard let read = try? JSONDecoder().decode([Readable].self, from: data) else {
            log("connectors: couldn't read the saved list")
            return []
        }
        let saved = read.compactMap(\.connector)
        let kept = saved.reduce(into: [Connector]()) { kept, connector in
            let isNew = !kept.contains { $0.id == connector.id || $0.serverName == connector.serverName }
            if isNew, ConnectorRules.isSound(connector) { kept.append(connector) }
        }
        if kept.count < read.count { log("connectors: left out \(read.count - kept.count) that didn't check out") }
        return kept
    }

    /// One saved connector, or nil when it can't be read (say, from a newer LocalFlow), so
    /// one bad entry doesn't lose the rest.
    private struct Readable: Decodable {
        let connector: Connector?

        init(from decoder: Decoder) throws {
            connector = try? Connector(from: decoder)
        }
    }
}
