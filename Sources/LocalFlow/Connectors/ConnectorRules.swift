import Foundation

/// The checks a connector passes before it's saved, and again when it's read back.
enum ConnectorRules {
    /// Short enough that mcp__<server>__<tool> stays within the 64 characters a tool name can have.
    static let maxServerNameLength = 20
    static let fallbackServerName = "connector"
    /// Plain http is only for a server on this Mac.
    private static let localHosts: Set<String> = ["localhost", "127.0.0.1"]
    /// Variables that change how a program finds or loads code: never a secret's home.
    private static let reservedVariables: Set<String> = ["PATH", "HOME", "USER", "SHELL", "TMPDIR", "NODE_OPTIONS",
                                                         "NODE_PATH", "PYTHONPATH", "PYTHONSTARTUP", "PERL5OPT",
                                                         "RUBYOPT", "BASH_ENV", "ENV"]
    private static let reservedPrefixes = ["DYLD_", "LD_"]

    // MARK: Server names

    /// The name in lowercase letters, digits and dashes, numbered past any taken one.
    /// Never the screen tools' server.
    static func serverName(for name: String, taken: Set<String>) -> String {
        let base = sanitized(name)
        let unavailable = taken.union([AgentInvocation.serverName])
        guard unavailable.contains(base) else { return base }
        let free = (2...).lazy.map { numbered(base, $0) }.first { !unavailable.contains($0) }
        return free ?? base
    }

    /// One `serverName(for:taken:)` could have made, and not the screen tools'.
    static func isValidServerName(_ name: String) -> Bool {
        name != AgentInvocation.serverName && sanitized(name) == name
    }

    private static func sanitized(_ name: String) -> String {
        let mapped = String(String.UnicodeScalarView(name.lowercased().unicodeScalars.map { isNameScalar($0) ? $0 : "-" }))
        let joined = mapped.split(separator: "-").joined(separator: "-")
        let cut = trimmingDashes(String(joined.prefix(maxServerNameLength)))
        return cut.isEmpty ? fallbackServerName : cut
    }

    private static func numbered(_ base: String, _ number: Int) -> String {
        let suffix = "-\(number)"
        return trimmingDashes(String(base.prefix(maxServerNameLength - suffix.count))) + suffix
    }

    private static func trimmingDashes(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func isNameScalar(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar)
    }

    // MARK: Addresses and commands

    /// An https address, or plain http to localhost. No sign-in inside the address, and
    /// plain ASCII with no backslash, so Claude Code reads the same host LocalFlow checked.
    static func remoteURL(_ text: String) throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let plain = trimmed.unicodeScalars.allSatisfy { (0x21...0x7E).contains($0.value) && $0 != "\\" }
        guard plain, let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), let host = url.host(percentEncoded: false)?.lowercased(),
              !host.isEmpty else { throw ConnectorProblem.badURL }
        guard url.user == nil, url.password == nil else { throw ConnectorProblem.credentialsInURL }
        switch scheme {
        case "https": return url
        case "http" where localHosts.contains(host): return url
        default: throw ConnectorProblem.notHTTPS
        }
    }

    /// A full path to a program, or a plain command name found on the agent's PATH.
    static func command(_ text: String, isExecutable: (String) -> Bool = isExecutableFile) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") {
            let plain = !trimmed.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
            guard plain, isExecutable(trimmed) else { throw ConnectorProblem.badCommand }
            return trimmed
        }
        guard isCommandName(trimmed) else { throw ConnectorProblem.badCommand }
        return trimmed
    }

    /// A file (not a folder) this user can run.
    static func isExecutableFile(_ path: String) -> Bool {
        var isFolder: ObjCBool = false
        let files = FileManager.default
        return files.fileExists(atPath: path, isDirectory: &isFolder) && !isFolder.boolValue
            && files.isExecutableFile(atPath: path)
    }

    /// Letters, digits, - _ and . only, not starting with - or . so it's never a flag or a path.
    private static func isCommandName(_ text: String) -> Bool {
        guard let first = text.first, first != "-", first != "." else { return false }
        return text.unicodeScalars.allSatisfy { isASCIIWordScalar($0) || $0 == "-" || $0 == "." }
    }

    /// Split on spaces; single or double quotes keep spaces in one argument. Nil when a
    /// quote isn't closed.
    static func arguments(from text: String) -> [String]? {
        var words: [String] = []
        var word = ""
        var inWord = false
        var quote: Character?
        for character in text {
            if let open = quote {
                if character == open { quote = nil } else { word.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
                inWord = true
            } else if character.isWhitespace {
                if inWord { words.append(word) }
                word = ""
                inWord = false
            } else {
                word.append(character)
                inWord = true
            }
        }
        guard quote == nil else { return nil }
        return inWord ? words + [word] : words
    }

    // MARK: Secrets

    static func environmentName(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.unicodeScalars.first else { throw ConnectorProblem.missingEnvironmentName }
        guard !("0"..."9").contains(first), trimmed.unicodeScalars.allSatisfy(isASCIIWordScalar) else {
            throw ConnectorProblem.badEnvironmentName
        }
        guard !reservedVariables.contains(trimmed), !reservedPrefixes.contains(where: trimmed.hasPrefix) else {
            throw ConnectorProblem.reservedEnvironmentName
        }
        return trimmed
    }

    /// Trimmed, with no spaces or line breaks inside, so it can't break out of a header.
    static func secret(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ConnectorProblem.missingSecret }
        guard !trimmed.unicodeScalars.contains(where: isSpaceOrControl) else { throw ConnectorProblem.badSecret }
        return trimmed
    }

    private static func isASCIIWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        isNameScalar(scalar) || ("A"..."Z").contains(scalar) || scalar == "_"
    }

    private static func isSpaceOrControl(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.whitespacesAndNewlines.contains(scalar) || CharacterSet.controlCharacters.contains(scalar)
    }
}
