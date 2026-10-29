import Foundation

/// How Claude Code reaches a connector's MCP server.
enum ConnectorTransport: Codable, Equatable, Sendable {
    /// A server on the web (Claude Code's type "http").
    case remote(url: URL)
    /// A program on this Mac, talked to over stdio (Claude Code's type "stdio").
    case local(command: String, arguments: [String])
}

/// Where a connector's secret comes from. The secret itself is never saved with the
/// connector: it's in the keychain, or asked of the GitHub CLI when a session starts.
enum ConnectorAuth: Codable, Equatable, Sendable {
    case noSecret
    /// Sent to a remote server as `Authorization: Bearer …`.
    case bearerToken
    /// Set as this environment variable for a local server.
    case environment(name: String)
    /// The GitHub CLI's own sign-in (`gh auth token`). GitHub's server only.
    case gitHubCLI

    /// The secret is one the user pasted, kept in the keychain.
    var isStored: Bool {
        switch self {
        case .bearerToken, .environment: return true
        case .noSecret, .gitHubCLI: return false
        }
    }

    /// A blank secret in an edit keeps the saved one only for the same kind of secret.
    func keepsSecret(for secret: ConnectorDraft.Secret) -> Bool {
        switch (self, secret) {
        case (.bearerToken, .token), (.environment, .environment): return true
        default: return false
        }
    }
}

/// An MCP server the agent gets every time it starts, like Claude's connectors.
/// Saved without its secret.
struct Connector: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    /// What the user called it.
    let name: String
    /// Its name in Claude Code, so its tools are mcp__<serverName>__<tool>. Set once.
    let serverName: String
    let transport: ConnectorTransport
    let auth: ConnectorAuth
    let isEnabled: Bool

    func enabled(_ isEnabled: Bool) -> Connector {
        Connector(id: id, name: name, serverName: serverName, transport: transport, auth: auth, isEnabled: isEnabled)
    }

    /// The address (https:// and anything after ? left off) or command, for the list in Settings.
    var detail: String {
        switch transport {
        case .remote(let url):
            let address = url.absoluteString.split(separator: "?").first.map(String.init) ?? ""
            let shown = address.split(separator: "#").first.map(String.init) ?? ""
            let secure = "https://"
            return shown.hasPrefix(secure) ? String(shown.dropFirst(secure.count)) : shown
        case .local(let command, let arguments):
            return ([command] + arguments).joined(separator: " ")
        }
    }
}

/// What the user typed for a connector, before it's checked. A blank secret on an
/// update keeps the one already saved.
struct ConnectorDraft: Equatable, Sendable {
    enum Transport: Equatable, Sendable {
        case remote(url: String)
        case local(command: String, arguments: [String])
    }

    enum Secret: Equatable, Sendable {
        case noSecret
        /// A token for a remote server.
        case token(String)
        /// A secret for a local server, and the environment variable it goes in.
        case environment(name: String, value: String)
        /// The GitHub CLI's sign-in, for GitHub's server.
        case gitHubCLI
    }

    let name: String
    let transport: Transport
    let secret: Secret
}

/// Why a connector can't be added, in words for Settings.
enum ConnectorProblem: Error, Equatable, Sendable, LocalizedError {
    case emptyName
    case badURL
    case notHTTPS
    case credentialsInURL
    case badCommand
    case badArguments
    case badEnvironmentName
    case reservedEnvironmentName
    case missingEnvironmentName
    case missingSecret
    case badSecret
    case wrongSecretKind
    case gitHubCLIOnlyForGitHub
    case keychain(OSStatus)
    case notFound

    var errorDescription: String? {
        switch self {
        case .emptyName: return "Give it a name."
        case .badURL: return "That isn't a web address. It should start with https://."
        case .notHTTPS: return "Use an https:// address. Plain http:// only works for localhost."
        case .credentialsInURL: return "Leave the sign-in out of the address and paste the token in its own field."
        case .badCommand:
            return "Use a full path to a program (like /usr/local/bin/server) or a command name (like npx)."
        case .badArguments: return "An argument has a quote that isn't closed."
        case .badEnvironmentName:
            return "The variable name can only have letters, digits and _, and can't start with a digit."
        case .reservedEnvironmentName:
            return "PATH, HOME and variables that change how programs load can't hold a secret. Pick another name."
        case .missingEnvironmentName: return "Say which environment variable gets the secret."
        case .missingSecret: return "Paste the token or secret."
        case .badSecret: return "The token can't have spaces or line breaks in it."
        case .wrongSecretKind: return "That kind of secret doesn't fit this connector."
        case .gitHubCLIOnlyForGitHub: return "The GitHub CLI sign-in only works for GitHub's own server."
        case .keychain(let status): return "Couldn't save the token in the keychain (error \(status))."
        case .notFound: return "That connector isn't there anymore."
        }
    }
}
