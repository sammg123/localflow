import Foundation

/// Turning what the user typed into a connector, and checking one read back from settings.
extension ConnectorRules {
    /// The connector a draft makes, and the secret to keep for it (nil: none given, so a
    /// saved one stays when `hasStoredSecret`).
    static func check(_ draft: ConnectorDraft, id: UUID, serverName: String, isEnabled: Bool, hasStoredSecret: Bool,
                      isExecutable: (String) -> Bool) throws -> (connector: Connector, secret: String?) {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ConnectorProblem.emptyName }
        let transport = try checked(draft.transport, isExecutable: isExecutable)
        let (auth, secret) = try checked(draft.secret, for: transport, hasStoredSecret: hasStoredSecret)
        let connector = Connector(id: id, name: name, serverName: serverName, transport: transport, auth: auth,
                                  isEnabled: isEnabled)
        return (connector, secret)
    }

    /// Whether a connector read back from settings still passes: a name, a usable server
    /// name, a sound address or command, and the GitHub CLI's sign-in only for GitHub.
    static func isSound(_ connector: Connector) -> Bool {
        guard !connector.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              isValidServerName(connector.serverName) else { return false }
        switch (connector.transport, connector.auth) {
        case (.remote(let url), .noSecret), (.remote(let url), .bearerToken):
            return (try? remoteURL(url.absoluteString)) == url
        case (.remote(let url), .gitHubCLI):
            return GitHubConnector.isGitHub(url)
        case (.local(let command, _), .noSecret):
            return isCommandShape(command)
        case (.local(let command, _), .environment(let name)):
            return isCommandShape(command) && (try? environmentName(name)) == name
        default:
            return false
        }
    }

    private static func isCommandShape(_ command: String) -> Bool {
        (try? self.command(command, isExecutable: { _ in true })) == command
    }

    private static func checked(_ transport: ConnectorDraft.Transport,
                                isExecutable: (String) -> Bool) throws -> ConnectorTransport {
        switch transport {
        case .remote(let url):
            return .remote(url: try remoteURL(url))
        case .local(let command, let arguments):
            return .local(command: try self.command(command, isExecutable: isExecutable), arguments: arguments)
        }
    }

    private static func checked(_ secret: ConnectorDraft.Secret, for transport: ConnectorTransport,
                                hasStoredSecret: Bool) throws -> (ConnectorAuth, String?) {
        switch (secret, transport) {
        case (.noSecret, _):
            return (.noSecret, nil)
        case (.token(let token), .remote):
            return (.bearerToken, try given(token, hasStoredSecret: hasStoredSecret))
        case (.environment(let name, let value), .local):
            let variable = try environmentName(name)
            return (.environment(name: variable), try given(value, hasStoredSecret: hasStoredSecret))
        case (.gitHubCLI, .remote(let url)) where GitHubConnector.isGitHub(url):
            return (.gitHubCLI, nil)
        case (.gitHubCLI, _):
            throw ConnectorProblem.gitHubCLIOnlyForGitHub
        default:
            throw ConnectorProblem.wrongSecretKind
        }
    }

    /// A blank secret is fine only when one is already saved; it stays.
    private static func given(_ text: String, hasStoredSecret: Bool) throws -> String? {
        if hasStoredSecret, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        return try secret(text)
    }
}
