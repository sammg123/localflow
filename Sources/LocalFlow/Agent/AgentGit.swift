import Foundation

/// Which git commands ask: the ones that publish, throw work away, rewrite history, or
/// set up commands git will run later (aliases, hooks, pagers).
enum AgentGit {
    /// git's own options that take a value before the subcommand.
    static let globalValued: Set<String> = ["-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env",
                                            "--super-prefix"]
    private typealias Words = AgentCommandWords

    /// The kind of risky git command (`push`, `reset --hard` …), or nil.
    static func risky(_ args: [String]) -> String? {
        guard let (sub, rest) = Words.subcommand(args, valued: globalValued) else { return nil }
        // `-c alias.x='!cmd'`, core.pager and the like run commands of their own.
        let global = args.prefix(args.count - rest.count - 1)
        if global.contains(where: { $0 == "-c" || $0.hasPrefix("--config-env") }) { return "-c" }
        // Options only count before `--`; after it they're file names.
        let options = Array(rest.prefix { $0 != "--" })
        switch sub {
        case "push", "restore", "rebase": return sub
        case "filter-branch", "filter-repo": return "filter-branch"
        case "reset": return Words.hasLongOption(options, "--hard") ? "reset --hard" : nil
        case "clean":
            let dryRun = Words.hasLongOption(options, "--dry-run") || options.contains { Words.isShortCluster($0, with: "n") }
            return dryRun ? nil : "clean"
        case "branch": return forceDeletes(options) ? "branch -D" : nil
        case "checkout":
            let discards = rest.contains { ["--", "."].contains($0) } || options.contains("-f")
                || Words.hasLongOption(options, "--force")
            return discards ? "checkout --" : nil
        case "stash": return ["drop", "clear"].contains(rest.first ?? "") ? "stash " + (rest.first ?? "") : nil
        case "config": return setsConfig(rest) ? "config" : nil
        default: return losesWork(sub, rest, options)
        }
    }

    /// Commands that delete files, throw away changes or history, or send mail.
    private static func losesWork(_ sub: String, _ rest: [String], _ options: [String]) -> String? {
        let force = options.contains { Words.isShortCluster($0, with: "f") }
            || Words.hasLongOption(options, "--force") || Words.hasLongOption(options, "--discard-changes")
        switch sub {
        case "rm": return options.contains("--cached") ? nil : "rm"
        case "switch": return force ? "switch -f" : nil
        case "reflog": return ["expire", "delete"].contains(rest.first ?? "") ? "reflog expire" : nil
        case "gc": return options.contains { $0 == "--prune" || $0.hasPrefix("--prune=") } ? "gc --prune" : nil
        case "tag":
            let delete = options.contains { Words.isShortCluster($0, with: "d") } || Words.hasLongOption(options, "--delete")
            return delete ? "tag -d" : nil
        case "lfs": return rest.first == "push" ? "lfs push" : nil
        case "send-email": return "send-email"
        case "update-ref": return options.contains("-d") ? "update-ref -d" : nil
        default: return nil
        }
    }

    /// `-D`, or delete together with force in any spelling (`-df`, `--delete --force`).
    private static func forceDeletes(_ options: [String]) -> Bool {
        let delete = Words.hasLongOption(options, "--delete") || options.contains { Words.isShortCluster($0, with: "d") }
        let force = Words.hasLongOption(options, "--force") || options.contains { Words.isShortCluster($0, with: "f") }
        return options.contains { Words.isShortCluster($0, with: "D") } || (delete && force)
    }

    /// `git config key value` and the editing options set something; a key alone or
    /// `--get`/`--list` only read.
    private static func setsConfig(_ rest: [String]) -> Bool {
        let editing: Set<String> = ["--add", "--replace-all", "--unset", "--unset-all", "--rename-section",
                                    "--remove-section", "--edit", "-e", "set", "unset", "edit"]
        let reading: Set<String> = ["--get", "--get-all", "--get-regexp", "--list", "-l", "--show-origin", "get", "list"]
        if rest.contains(where: editing.contains) { return true }
        if rest.contains(where: reading.contains) { return false }
        return rest.filter { !$0.hasPrefix("-") }.count >= 2
    }
}
