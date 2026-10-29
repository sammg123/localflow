import Foundation

/// Claude Code's MCP server entries for connectors, built when a session starts.
enum ConnectorConfig {
    /// Entries by server name. One whose secret is missing is left out. Runs off the main
    /// thread: the keychain and gh can take a moment. gh is asked at most once.
    @concurrent
    static func servers(for connectors: [Connector], secrets: any ConnectorSecrets,
                        gitHubCLIToken: @Sendable () async -> String?) async -> [String: AgentJSON] {
        let wantsGitHubCLI = connectors.contains { $0.auth == .gitHubCLI }
        let gitHubToken = wantsGitHubCLI ? await gitHubCLIToken() : nil
        let pairs = connectors.compactMap { connector -> (String, AgentJSON)? in
            let secret = secret(for: connector, secrets: secrets, gitHubToken: gitHubToken)
            return entry(for: connector, secret: secret).map { (connector.serverName, $0) }
        }
        return Dictionary(pairs) { first, _ in first }
    }

    /// One entry, or nil when the connector needs a secret it doesn't have. The GitHub
    /// CLI's token only ever goes to GitHub.
    static func entry(for connector: Connector, secret: String?) -> AgentJSON? {
        switch (connector.transport, connector.auth) {
        case (.remote(let url), .noSecret):
            return ["type": "http", "url": .string(url.absoluteString)]
        case (.remote(let url), .bearerToken), (.remote(let url), .gitHubCLI):
            guard let secret, connector.auth != .gitHubCLI || GitHubConnector.isGitHub(url) else { return nil }
            return ["type": "http", "url": .string(url.absoluteString),
                    "headers": ["Authorization": .string("Bearer " + secret)]]
        case (.local(let command, let arguments), .noSecret):
            return ["type": "stdio", "command": .string(command), "args": .array(arguments.map(AgentJSON.string))]
        case (.local(let command, let arguments), .environment(let name)):
            guard let secret else { return nil }
            return ["type": "stdio", "command": .string(command), "args": .array(arguments.map(AgentJSON.string)),
                    "env": .object([name: .string(secret)])]
        default:
            return nil
        }
    }

    /// The secret as it is now, checked again so nothing odd reaches a header.
    private static func secret(for connector: Connector, secrets: any ConnectorSecrets,
                               gitHubToken: String?) -> String? {
        let raw: String?
        switch connector.auth {
        case .noSecret: raw = nil
        case .bearerToken, .environment: raw = secrets.secret(for: connector.id)
        case .gitHubCLI: raw = gitHubToken
        }
        return raw.flatMap { try? ConnectorRules.secret($0) }
    }
}
