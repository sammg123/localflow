import Foundation

/// Files the agent asks before writing: the system's, keys and keychains, shell startup
/// files, login items, app preferences, git hooks and config, Claude Code's settings, and
/// LocalFlow's own app and files (where the agent could otherwise give itself more permissions).
enum AgentPaths {
    static let systemFolders = ["/System", "/Library", "/etc", "/usr", "/bin", "/sbin", "/private",
                                "/Applications/LocalFlow.app"]
    static let homeFolders = [".ssh", "Library/Keychains", ".gnupg", "Library/LaunchAgents", ".config/git", ".claude",
                              ".config/fish", "Applications/LocalFlow.app", "Library/Preferences"]
    static let startupFiles = [".zshrc", ".zprofile", ".zshenv", ".zlogin", ".zlogout", ".bashrc", ".bash_profile",
                               ".bash_login", ".bash_logout", ".profile", ".gitconfig"]
    /// Names that are sensitive wherever they are, for paths whose folder isn't known.
    static let sensitiveNames = Set(startupFiles + ["authorized_keys", "authorized_keys2", "known_hosts"])
    static let sensitiveFolders: Set<String> = [".ssh", ".gnupg", "keychains", "launchagents", "launchdaemons", ".claude",
                                                "localflow.app"]

    /// Whether writing `path` should ask. Relative paths are from `workingDirectory`, `~`
    /// is home, and a link to a protected place counts as that place. macOS names don't
    /// care about case, so neither does this.
    static func isProtected(_ path: String, home: String, workingDirectory: String) -> Bool {
        let full = absolute(path, home: home, workingDirectory: workingDirectory)
        let url = URL(fileURLWithPath: full)
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent)
        let candidates = [full, parent.path, url.resolvingSymlinksInPath().path]
        return candidates.contains { isProtected(absolute: $0, home: home) }
    }

    static func absolute(_ path: String, home: String, workingDirectory: String) -> String {
        let expanded = path == "~" ? home : path.hasPrefix("~/") ? home + path.dropFirst() : path
        let rooted = expanded.hasPrefix("/") ? expanded : workingDirectory + "/" + expanded
        return URL(fileURLWithPath: rooted).standardized.path
    }

    /// A shell word as a path: `$HOME` filled in, or nil when it depends on anything
    /// else the shell would expand (other variables, globs, braces, substitutions).
    static func shellPath(_ word: String, home: String) -> String? {
        let expanded = expandingHome(word, home: home)
        return expanded.contains(where: isOpaque) ? nil : expanded
    }

    private static func expandingHome(_ word: String, home: String) -> String {
        ["${HOME}", "$HOME"].reduce(word) { text, variable in
            text.hasPrefix(variable) ? home + text.dropFirst(variable.count) : text
        }
    }

    private static func isOpaque(_ c: Character) -> Bool {
        "$`*?[{".contains(c)
    }

    /// A path the shell fills in (`$D/x`, `~/.z*rc`, `~/{a,b}`) that may be protected: it
    /// names or could match a sensitive file, or it starts in home itself or a protected folder.
    static func mayBeProtected(_ word: String, home: String) -> Bool {
        let lower = word.lowercased()
        let last = lower.split(separator: "/").last.map(String.init) ?? lower
        if hasSensitiveName(lower) || sensitiveNames.contains(where: { fnmatch(last, $0, 0) == 0 })
            || (sensitiveNames.union(sensitiveFolders)).contains(where: lower.contains) {
            return true
        }
        let expanded = expandingHome(word, home: home)
        let fixed = expanded.prefix { !isOpaque($0) }
        guard let slash = fixed.lastIndex(of: "/") else { return false }
        let folder = String(fixed[..<slash])
        guard folder.isEmpty || folder.hasPrefix("/") || folder.hasPrefix("~") else { return false }
        let full = folder.isEmpty ? "/" : absolute(folder, home: home, workingDirectory: home)
        return full == home || isProtected(full, home: home, workingDirectory: home)
    }

    /// Where a redirect writes is risky: protected, a sensitive name in an unknown folder,
    /// or not knowable before it runs. `directory` is nil after a `cd` that can't be followed.
    static func isRiskyTarget(_ word: String, home: String, directory: String?) -> Bool {
        guard let path = shellPath(word, home: home) else { return true }
        return isProtectedArgument(path, home: home, directory: directory)
    }

    /// A path named on a command line that writes it (`cp`, `tee`, `curl -o`).
    static func isProtectedArgument(_ word: String, home: String, directory: String?) -> Bool {
        guard let path = shellPath(word, home: home) else { return false }
        if hasSensitiveName(path) { return true }
        let anchored = path.hasPrefix("/") || path.hasPrefix("~")
        guard anchored || directory != nil else { return false }
        return isProtected(path, home: home, workingDirectory: directory ?? home)
    }

    /// Claude Code keeps the folder a `cd` moved it to, so a relative path can be anywhere:
    /// judge it by its names.
    static func hasSensitiveName(_ path: String) -> Bool {
        let parts = path.lowercased().split(separator: "/").map(String.init)
        return isGitInternal(parts) || parts.last.map(sensitiveNames.contains) == true
            || parts.contains(where: sensitiveFolders.contains)
    }

    /// A repository's .git/hooks and .git/config set commands the next git command runs.
    private static func isGitInternal(_ parts: [String]) -> Bool {
        zip(parts, parts.dropFirst()).contains { $0 == ".git" && ["hooks", "config"].contains($1) }
    }

    private static func isProtected(absolute path: String, home: String) -> Bool {
        let lower = path.lowercased()
        let folders = systemFolders + homeFolders.map { home + "/" + $0 }
            + [ClaudeInvocation.configDirectory(home: home)]
        let files = startupFiles.map { home + "/" + $0 }
        return folders.contains { isInside(lower, $0.lowercased()) } || files.contains { lower == $0.lowercased() }
            || isGitInternal(lower.split(separator: "/").map(String.init)) || isLocalFlowFile(lower, home: home)
    }

    /// LocalFlow's own files (its sign-in script, Claude settings, chats), but not the
    /// agent's working folder among them, apart from the notes Claude Code reads there.
    private static func isLocalFlowFile(_ lower: String, home: String) -> Bool {
        let folder = (home + "/Library/Application Support/LocalFlow").lowercased()
        let agent = AgentInvocation.workingDirectory(home: home).lowercased()
        let notes = ["claude.md", "claude.local.md"].map { agent + "/" + $0 }
        return isInside(lower, folder) && (!isInside(lower, agent) || notes.contains(lower))
    }

    /// `path` is `folder` or somewhere under it.
    private static func isInside(_ path: String, _ folder: String) -> Bool {
        path == folder || path.hasPrefix(folder + "/")
    }
}
