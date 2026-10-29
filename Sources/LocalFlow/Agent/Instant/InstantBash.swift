import Foundation

/// The terminal in Instant Edits: only commands that clearly just read (ls, cat, grep,
/// find, git status/diff/log …), alone or piped or chained with each other, with paths
/// inside the project. Anything else, or anything this can't read for sure, is refused.
enum InstantBash {
    struct Place {
        let roots: [String]
        let home: String
        /// Where a relative path may start: the projects, and folders `cd` went to.
        let folders: [String]
    }

    private typealias Rule = ([String]) -> Bool

    private static let gitReads: Set<String> = ["status", "diff", "log", "show", "ls-files", "grep", "rev-parse", "blame"]
    /// find's actions that run, delete or write, and its options that follow links.
    private static let findRefused: Set<String> = ["-exec", "-execdir", "-delete", "-ok", "-okdir", "-fprint", "-fprint0",
                                                   "-fprintf", "-fls", "-L", "-follow"]
    private static let grepRule: Rule = { args in
        !args.contains { $0 == "--dereference-recursive" || isCluster($0, with: "R") }
    }

    /// By exact name: a path in front (`/tmp/ls`), quotes or an `=` would run something else.
    private static let rules: [String: Rule] = [
        "ls": { _ in true }, "pwd": { _ in true }, "cat": { _ in true }, "head": { _ in true }, "wc": { _ in true },
        "grep": grepRule, "egrep": grepRule, "fgrep": grepRule,
        "tail": { args in !args.contains { $0.hasPrefix("--follow") || isCluster($0, with: "fF") } },
        "file": { args in !args.contains { $0 == "--compile" || isCluster($0, with: "C") } },
        "rg": { args in
            !args.contains {
                $0.hasPrefix("--pre") || $0.hasPrefix("--hostname-bin") || $0 == "--follow" || isCluster($0, with: "L")
            }
        },
        "find": { args in !args.contains(where: findRefused.contains) },
        "git": { args in git(args) },
        "cd": { args in args.count == 1 && (args[0].hasPrefix("/") || args[0].hasPrefix("~/")) },
    ]

    /// `folders` are where earlier commands left the terminal (see `cdTargets`).
    static func review(_ command: String?, roots: [String], home: String, folders: [String] = []) -> InstantDecision {
        guard let command else { return .deny(InstantRefusal.bash) }
        let place = Place(roots: roots, home: home, folders: roots + folders + cdTargets(in: command, home: home))
        return isReadOnly(command, place) ? .allow : .deny(InstantRefusal.bash)
    }

    static func isReadOnly(_ command: String, _ place: Place) -> Bool {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let parsed = AgentShell.parse(command)
        guard !parsed.unclear, parsed.substitutions.isEmpty, parsed.feeds.isEmpty, !parsed.pipelines.isEmpty else {
            return false
        }
        return parsed.pipelines.allSatisfy { $0.allSatisfy { isReadOnly($0, place) } }
    }

    /// The real folders a command's `cd`s go to. The terminal stays there afterwards.
    static func cdTargets(in command: String, home: String) -> [String] {
        AgentShell.parse(command).pipelines.flatMap { $0 }.compactMap { part in
            guard part.words.count == 2, part.words[0] == "cd" else { return nil }
            return InstantPaths.resolve(part.words[1], home: home)
        }
    }

    /// Every word is checked as a path, a search pattern too: a pattern given inside an
    /// option (`-ex`, `--regexp=x`) leaves the first plain word a file to read.
    private static func isReadOnly(_ command: AgentShell.Command, _ place: Place) -> Bool {
        guard command.writes.allSatisfy({ $0 == "/dev/null" }),
              let name = command.words.first, let rule = rules[name] else { return false }
        let args = Array(command.words.dropFirst())
        let inputs = command.inputs.compactMap { input -> String? in
            if case .file(let path) = input { return path }
            return nil
        }
        guard (args + inputs).allSatisfy(isPlain), inputs.allSatisfy({ isInside($0, place) }) else { return false }
        return (args + inputs).allSatisfy { isSafeWord($0, place) } && rule(args)
    }

    private static func isSafeWord(_ word: String, _ place: Place) -> Bool {
        if let path = pathPart(word) { return isInside(path, place) }
        guard let value = valuePart(word) else { return true }
        return !isSecretName(value) && staysInside(relative: value, place)
    }

    /// No variables, substitutions, brace expansion or another user's home (`~root`).
    private static func isPlain(_ word: String) -> Bool {
        !word.contains("$") && !word.contains("`") && !AgentCommands.hasBraceExpansion(word)
            && (!word.hasPrefix("~") || word == "~" || word.hasPrefix("~/"))
    }

    /// The path a word names, if it names one the shell would read as a path: from `/`,
    /// `~`, or with `..` in it; for an option, its value (`--file=/x`, `-f/x`).
    private static func pathPart(_ word: String) -> String? {
        var value = word
        if word.hasPrefix("-") {
            if let equals = word.firstIndex(of: "=") {
                value = String(word[word.index(after: equals)...])
            } else if let slash = word.firstIndex(of: "/") {
                value = String(word[slash...])
            } else {
                return nil
            }
        }
        let named = value.hasPrefix("/") || value.hasPrefix("~") || value.split(separator: "/").contains("..")
        return named ? value : nil
    }

    /// A word that may be a relative path: the word, or an option's value after `=`.
    private static func valuePart(_ word: String) -> String? {
        guard word.hasPrefix("-") else { return word.isEmpty ? nil : word }
        return word.firstIndex(of: "=").map { String(word[word.index(after: $0)...]) }
    }

    /// Inside a project, and not secret, generated or downloaded: reads stay cheap, as with Read.
    private static func isInside(_ path: String, _ place: Place) -> Bool {
        guard let resolved = InstantPaths.resolve(path, home: place.home),
              let root = InstantPaths.root(of: resolved, in: place.roots) else { return false }
        let name = URL(fileURLWithPath: resolved).lastPathComponent.lowercased()
        return !InstantPaths.isGenerated(relative: InstantPaths.relative(resolved, to: root))
            && (resolved.count == root.count || !InstantPaths.isSecret(name))
    }

    /// A relative word naming a secret file, like `.env` or `certs/server.pem`. Words
    /// without a dot are left to be search patterns (`grep -rn secret`).
    private static func isSecretName(_ word: String) -> Bool {
        let name = word.split(separator: "/").last.map { String($0).lowercased() } ?? ""
        return name.contains(".") && InstantPaths.isSecret(name)
    }

    /// A relative word doesn't lead out of the projects through a link, from any folder the
    /// terminal may be in. Only its part before a wildcard counts, since the shell expands it.
    private static func staysInside(relative word: String, _ place: Place) -> Bool {
        let fixed = word.split(separator: "/").prefix { !$0.contains(where: { "*?[".contains($0) }) }
        guard !fixed.isEmpty else { return true }
        let tail = fixed.joined(separator: "/")
        return place.folders.allSatisfy { folder in
            guard let resolved = InstantPaths.resolve(folder + "/" + tail, home: place.home) else { return false }
            return InstantPaths.root(of: resolved, in: place.roots) != nil
        }
    }

    /// `-xyz` style options that include any of `letters`.
    private static func isCluster(_ word: String, with letters: String) -> Bool {
        word.hasPrefix("-") && !word.hasPrefix("--") && word.dropFirst().contains(where: letters.contains)
    }
}

extension InstantBash {
    /// git that only reads: status, diff, log, show, ls-files, grep, rev-parse, blame, and
    /// `branch` when it only lists. No `-c` (it can set a pager to run), no output files.
    fileprivate static func git(_ args: [String]) -> Bool {
        var index = 0
        while index < args.count, args[index].hasPrefix("-") {
            switch args[index] {
            case "--no-pager", "-P", "--no-optional-locks": index += 1
            case "-C": index += 2
            default: return false
            }
        }
        guard index < args.count else { return false }
        let rest = Array(args[(index + 1)...])
        let sub = args[index]
        if sub == "branch" { return branchOnlyLists(rest) }
        guard gitReads.contains(sub) else { return false }
        let writes = rest.contains {
            $0.hasPrefix("--output") || $0.hasPrefix("--open-files-in-pager") || $0 == "--ext-diff"
        }
        return !writes && !(sub == "grep" && rest.contains { $0.hasPrefix("-O") })
    }

    /// `git branch` with listing options only; a plain word names a branch to make,
    /// unless `--list` makes it a pattern.
    private static func branchOnlyLists(_ args: [String]) -> Bool {
        let listing: Set<String> = ["-a", "--all", "-r", "--remotes", "-v", "-vv", "--verbose", "--show-current", "-l",
                                    "--list", "--no-color", "--color", "--column", "--no-column", "-i", "--ignore-case"]
        let valued: Set<String> = ["--contains", "--no-contains", "--merged", "--no-merged", "--points-at", "--sort",
                                   "--format"]
        let isList = args.contains("-l") || args.contains("--list")
        var index = 0
        while index < args.count {
            let word = args[index]
            if word.hasPrefix("--"), let equals = word.firstIndex(of: "=") {
                guard valued.contains(String(word[..<equals])) else { return false }
                index += 1
            } else if valued.contains(word) {
                index += 2
            } else if listing.contains(word) || (word.hasPrefix("-") && !word.hasPrefix("--")
                                                 && word.count > 1 && word.dropFirst().allSatisfy("arvli".contains)) {
                index += 1
            } else if word.hasPrefix("-") || !isList {
                return false
            } else {
                index += 1
            }
        }
        return true
    }
}
