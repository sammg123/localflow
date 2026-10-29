import Foundation

/// A connector's tool, from Claude Code's name for it: mcp__<server>__<tool>. LocalFlow's
/// own screen tools aren't one.
struct ConnectorTool: Equatable, Sendable {
    /// A tool whose first word is one of these only looks, so it runs without asking.
    static let readWords: Set<String> = ["get", "list", "search", "read", "fetch", "find", "view", "describe", "show"]
    /// Any of these later in the name means it changes something after all ("get or create"),
    /// as does a joining word: a tool that does two things isn't only looking.
    static let changeWords: Set<String> = [
        "accept", "add", "apply", "approve", "archive", "assign", "cancel", "clear", "close", "copy", "create",
        "decline", "delete", "destroy", "disable", "dismiss", "drop", "edit", "enable", "erase", "execute", "fork",
        "grant", "insert", "install", "invite", "kill", "merge", "move", "patch", "pay", "post", "publish", "purge",
        "push", "put", "reject", "remove", "rename", "reopen", "replace", "rerun", "reset", "resolve", "restart",
        "revert", "revoke", "rollback", "save", "send", "set", "submit", "terminate", "transfer", "trigger",
        "uninstall", "unlock", "update", "upload", "wipe", "write",
        "and", "or", "then",
    ]
    private static let prefix = "mcp__"

    let server: String
    let tool: String

    init?(toolName: String) {
        guard toolName.hasPrefix(Self.prefix) else { return nil }
        let rest = toolName.dropFirst(Self.prefix.count)
        guard let split = rest.range(of: "__") else { return nil }
        let server = String(rest[..<split.lowerBound])
        let tool = String(rest[split.upperBound...])
        guard !server.isEmpty, !tool.isEmpty, server != AgentInvocation.serverName else { return nil }
        self.server = server
        self.tool = tool
    }

    var words: [String] { Self.words(in: tool) }

    var isReadLike: Bool {
        guard let first = words.first, Self.readWords.contains(first) else { return false }
        return !words.dropFirst().contains(where: Self.changeWords.contains)
    }

    /// "Use github: create pull request".
    var summary: String {
        let said = words.isEmpty ? tool : words.joined(separator: " ")
        return "Use \(server): \(said)"
    }

    /// Allowing one for the task allows this server's tool, and only it.
    var grantKey: String { "connector:\(server):\(tool)" }

    /// snake_case, kebab-case and camelCase names as lowercase words; an acronym before a
    /// word stays its own ("getURLDelete" is get, url, delete).
    static func words(in name: String) -> [String] {
        var words: [String] = []
        var word = ""
        for character in name {
            guard character.isLetter || character.isNumber else {
                if !word.isEmpty { words.append(word.lowercased()) }
                word = ""
                continue
            }
            let previous = word.last
            if character.isUppercase, let previous, previous.isLowercase || previous.isNumber {
                words.append(word.lowercased())
                word = ""
            } else if character.isLowercase, let previous, previous.isUppercase, word.count > 1,
                      word.dropLast().last?.isUppercase == true {
                words.append(String(word.dropLast()).lowercased())
                word = String(previous)
            }
            word.append(character)
        }
        return word.isEmpty ? words : words + [word.lowercased()]
    }
}
