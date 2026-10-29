import Foundation

/// Which single commands are risky, by name and options. `words` start at the command
/// itself, wrappers already removed.
enum AgentCommands {
    typealias Risk = AgentBash.Risk
    typealias Context = AgentBash.Context
    private typealias Words = AgentCommandWords

    private static let deletes: Set<String> = ["rm", "rmdir", "unlink", "shred", "srm", "trash"]
    private static let stops: Set<String> = ["kill", "killall", "pkill"]
    private static let power: Set<String> = ["shutdown", "reboot", "halt"]
    private static let remote: Set<String> = ["ssh", "scp", "rsync", "sftp", "ssh-copy-id", "mosh", "nc", "ncat",
                                              "netcat", "socat"]
    private static let mailers: Set<String> = ["mail", "mailx", "sendmail", "msmtp", "mutt", "swaks"]
    private static let system: Set<String> = ["launchctl", "pmset", "systemsetup", "networksetup", "scutil", "nvram",
                                              "csrutil", "spctl", "fdesetup", "dscl", "sysadminctl", "tmutil",
                                              "softwareupdate", "tccutil", "profiles", "systemextensionsctl", "kextload",
                                              "kextunload", "pfctl"]
    /// Commands that run a command string or a script in a way this can't follow.
    private static let elsewhere: Set<String> = ["tmux", "screen", "parallel", "chroot", "dtach"]
    private static let permissions: Set<String> = ["chmod", "chown", "chgrp"]
    private static let pips: Set<String> = ["pip", "pip3"]

    static func risks(_ words: [String], _ context: Context) -> [Risk] {
        guard let first = words.first else { return [] }
        if first.contains("$") || first.contains("`") {
            return [context.risk("Run a command named by a variable", "Bash:variable command")]
        }
        let command = Words.name(first)
        let args = Array(words.dropFirst())
        if command == "localflow" || words.contains(where: { word in
            AgentBash.localFlowMarks.contains(where: word.lowercased().contains)
        }) {
            return [context.risk("Run LocalFlow itself", "Bash:localflow")]
        }
        let globbed = !["[", "[["].contains(command) && command.contains(where: { "*?[".contains($0) })
        if globbed || hasBraceExpansion(first) || subcommands(command, args).contains(where: isOpaque) {
            return [context.risk("Run a command that can't be checked", "Bash:complex")]
        }
        return byName(command, args, context) + protectedWrites(command, args, context)
    }

    /// `{a,b}` or `{1..3}`, which the shell turns into several words.
    static func hasBraceExpansion(_ word: String) -> Bool {
        guard let open = word.firstIndex(of: "{"), let close = word[open...].firstIndex(of: "}") else { return false }
        let inside = word[word.index(after: open)..<close]
        return inside.contains(",") || inside.contains("..")
    }

    /// A word whose final text the shell decides: variables, substitutions, globs, braces.
    private static func isOpaque(_ word: String) -> Bool {
        word.contains(where: { "$`*?".contains($0) }) || hasBraceExpansion(word)
    }

    /// The words that decide what a tool with subcommands does (`git push`, `gh pr create`).
    private static func subcommands(_ command: String, _ args: [String]) -> [String] {
        switch command {
        case "git": return Words.subcommand(args, valued: AgentGit.globalValued).map { [$0.name] } ?? []
        case "gh":
            guard let (group, rest) = Words.subcommand(args, valued: ["-R", "--repo"]) else { return [] }
            return [group] + (Words.subcommand(rest, valued: ["-R", "--repo"]).map { [$0.name] } ?? [])
        case "npm", "pnpm", "yarn", "pip", "pip3", "brew", "gem", "cargo", "diskutil", "defaults", "launchctl", "crontab",
             "uv", "pipx", "go", "security", "tmutil":
            return Words.subcommand(args).map { [$0.name] } ?? []
        case _ where AgentPublishing.hasSubcommands(command):
            return Words.subcommand(args).map { [$0.name] } ?? []
        default:
            return []
        }
    }

    private static func byName(_ command: String, _ args: [String], _ context: Context) -> [Risk] {
        let simple: (String, String)? = switch command {
        case _ where deletes.contains(command): ("Delete files", command)
        case "su": ("Run as administrator", command)
        case "dd": ("Change disks", command)
        case _ where command.hasPrefix("mkfs") || command.hasPrefix("newfs"): ("Change disks", "mkfs")
        case _ where stops.contains(command): ("Stop processes", command)
        case _ where power.contains(command): ("Shut down or restart the Mac", command)
        case _ where system.contains(command): ("Change system settings", command)
        case "crontab" where args != ["-l"]: ("Change scheduled jobs", command)
        case "at", "batch": ("Change scheduled jobs", command)
        case "security": ("Use the keychain", command)
        case _ where elsewhere.contains(command): ("Run a command that can't be checked", command)
        case "osascript": ("Run AppleScript", command)
        case _ where remote.contains(command): ("Connect to another computer", command)
        case _ where mailers.contains(command): ("Send email", command)
        case "mv": ("Move or rename files", command)
        default: nil
        }
        if let (label, key) = simple { return [context.risk(label, "Bash:" + key)] }
        if let key = AgentPublishing.risky(command, args) { return [context.risk(AgentPublishing.label, "Bash:" + key)] }
        return detailed(command, args, context)
    }

    private static func detailed(_ command: String, _ args: [String], _ context: Context) -> [Risk] {
        switch command {
        case "sudo", "doas":
            let inner = Words.withoutSudo([command] + args)
            return [context.risk("Run as administrator", "Bash:" + command)] + risks(inner, context)
        case "diskutil": return diskutil(args).map { [context.risk("Change disks", "Bash:diskutil " + $0)] } ?? []
        case "git": return AgentGit.risky(args).map { [context.risk(nil, "Bash:git " + $0)] } ?? []
        case "npm", "pnpm", "yarn": return node(command, args).map { [context.risk(nil, "Bash:" + $0)] } ?? []
        case "pip", "pip3": return installer("pip", args, ["install", "uninstall"], context)
        case _ where command.hasPrefix("pip3."): return installer("pip", args, ["install", "uninstall"], context)
        case _ where command.hasPrefix("python"):
            let pip = zip(args, args.dropFirst()).contains { $0 == "-m" && pips.contains($1) }
                || args.contains { $0.hasPrefix("-m") && pips.contains(String($0.dropFirst(2))) } // -mpip
            return pip ? installer("pip", args, ["install", "uninstall"], context) : substituted(args, context)
        case "brew":
            return installer("brew", args, ["install", "uninstall", "upgrade", "remove", "rm", "reinstall", "bundle"], context)
        case "gem", "cargo", "uv", "go": return installer(command, args, ["install", "uninstall"], context)
        case "pipx": return installer("pipx", args, ["install", "uninstall", "upgrade", "reinstall", "inject"], context)
        case "watch": // runs its words as one shell command, again and again
            return context.nested(Words.afterOptions(args, valued: ["-n", "--interval"]).joined(separator: " "))
        case "gh": return gh(args).map { [context.risk(nil, "Bash:gh " + $0)] } ?? []
        case "open":
            let runs = AgentApps.opensProgram(args, directory: context.directory, home: context.place.home)
            return runs ? [context.risk("Open a program", "Bash:open program")] : []
        case "curl": return AgentNetwork.curlSends(args) ? [context.risk("Send data", "Bash:curl send")] : []
        case "wget": return AgentNetwork.wgetSends(args) ? [context.risk("Send data", "Bash:wget send")] : []
        case "defaults": return defaults(args).map { [context.risk("Change system settings", "Bash:defaults " + $0)] } ?? []
        case _ where permissions.contains(command):
            let recursive = args.contains("--recursive") || args.contains { Words.isShortCluster($0, with: "R") }
            return recursive ? [context.risk("Change permissions", "Bash:\(command) -R")] : []
        case "find": return find(args, context)
        case "eval": return context.nested(args.joined(separator: " "))
        case "trap": return Words.afterOptions(args, valued: []).first.map(context.nested) ?? [] // runs on a signal or exit
        case "alias": // an alias runs its text later in the same line
            return args.compactMap { arg in arg.firstIndex(of: "=").map { String(arg[arg.index(after: $0)...]) } }
                .flatMap(context.nested)
        case "source", ".": return substituted(args, context)
        case _ where Words.isInterpreter(command): return shell(command, args, context)
        default: return []
        }
    }

    /// Any of the risky subcommands anywhere among the plain words, so an option with a
    /// value in front (`pip --log f install`) can't hide one.
    private static func installer(_ tool: String, _ args: [String], _ risky: [String], _ context: Context) -> [Risk] {
        let plain = Set(args.filter { !$0.hasPrefix("-") })
        guard let sub = risky.first(where: plain.contains) else { return [] }
        return [context.risk("Install software", "Bash:\(tool) \(sub)")]
    }

    private static func diskutil(_ args: [String]) -> String? {
        guard let (sub, rest) = Words.subcommand(args) else { return nil }
        let lower = sub.lowercased()
        if lower == "apfs" {
            return rest.first.map { $0.lowercased() }.flatMap { $0.hasPrefix("delete") || $0.hasPrefix("erase") ? "erase" : nil }
        }
        let kinds: [(prefix: String, kind: String)] = [
            ("erase", "erase"), ("secureerase", "erase"), ("zerodisk", "erase"), ("randomdisk", "erase"),
            ("reformat", "erase"), ("partition", "partition"), ("splitpartition", "partition"),
            ("mergepartitions", "partition"), ("resizevolume", "partition"), ("unmount", "unmount"), ("eject", "eject"),
        ]
        return kinds.first { lower.hasPrefix($0.prefix) }?.kind
    }

    private static func node(_ tool: String, _ args: [String]) -> String? {
        let plain = args.filter { !$0.hasPrefix("-") }
        if plain.contains("publish") { return "\(tool) publish" }
        if tool == "yarn", plain.contains("global") { return "yarn global" }
        let global = args.contains { ["-g", "--global", "--location=global"].contains($0) || Words.isShortCluster($0, with: "g") }
            || zip(args, args.dropFirst()).contains { $0 == "--location" && $1 == "global" }
        let changes: Set<String> = ["i", "install", "add", "uninstall", "un", "remove", "rm", "update", "up", "upgrade", "link"]
        return global && plain.contains(where: changes.contains) ? "\(tool) install -g" : nil
    }

    /// gh changes things unless it only lists, views or downloads.
    private static func gh(_ args: [String]) -> String? {
        guard let (group, rest) = Words.subcommand(args, valued: ["-R", "--repo"]) else { return nil }
        if group == "api" { return AgentNetwork.ghAPIChanges(rest) ? "api" : nil }
        let groups: Set<String> = ["pr", "issue", "release", "repo", "gist", "run", "workflow", "secret", "variable",
                                   "label", "project", "ssh-key", "gpg-key", "cache", "ruleset", "auth", "codespace",
                                   "org", "extension", "alias", "config"]
        let reads: Set<String> = ["list", "ls", "view", "status", "diff", "checks", "download", "browse", "clone",
                                  "checkout", "watch", "get"]
        guard groups.contains(group), let action = Words.subcommand(rest, valued: ["-R", "--repo"])?.name,
              !reads.contains(action) else { return nil }
        return "\(group) \(action)"
    }

    private static func defaults(_ args: [String]) -> String? {
        guard let sub = Words.subcommand(args, valued: ["-host"])?.name,
              ["write", "delete", "import", "rename"].contains(sub) else { return nil }
        return sub
    }

    private static func find(_ args: [String], _ context: Context) -> [Risk] {
        let deletes = args.contains("-delete") ? [context.risk("Delete files", "Bash:find -delete")] : []
        let runs = args.indices.filter { ["-exec", "-execdir", "-ok", "-okdir"].contains(args[$0]) }.flatMap { start in
            let inner = args[(start + 1)...].prefix { $0 != ";" && $0 != "+" }
            guard case .runs(let words) = Words.strip(Array(inner)) else { return [Risk]() }
            return risks(words, context)
        }
        return deletes + runs
    }

    /// `sh -c '…'` runs that text; a shell or interpreter given `<(…)` runs what it outputs.
    private static func shell(_ command: String, _ args: [String], _ context: Context) -> [Risk] {
        if Words.shells.contains(command), let flag = args.firstIndex(where: { Words.isShortCluster($0, with: "c") }) {
            let text = Words.afterOptions(Array(args[(flag + 1)...]), valued: ["-o", "+o"]).first
            return text.map(context.nested) ?? []
        }
        return substituted(args, context)
    }

    private static func substituted(_ args: [String], _ context: Context) -> [Risk] {
        guard let script = args.first(where: { $0.hasPrefix("<(") }) else { return [] }
        return [AgentBash.downloaded(script) ? context.risk("Run downloaded code", "Bash:curl | sh")
            : context.risk("Run code piped into a shell", "Bash:pipe to shell")]
    }

    /// Writing a protected file by naming it, as `cp`, `tee`, `curl -o` or `sed -i` do.
    private static func protectedWrites(_ command: String, _ args: [String], _ context: Context) -> [Risk] {
        AgentWrites.isRisky(command, args, home: context.place.home, directory: context.directory)
            ? [context.risk("Write to a protected file", "Bash:write protected")] : []
    }
}
