import Foundation

/// Reading a command's words: its name, the wrappers in front of it, and its options.
enum AgentCommandWords {
    enum Stripped: Equatable {
        /// The command that actually runs, wrappers and assignments removed.
        case runs([String])
        /// Nothing runs (only assignments, or `command -v`).
        case nothing
        /// It runs something this can't read, such as `env -S`.
        case unclear
    }

    /// Words that run the rest as a command: options that take a value, and how many
    /// plain words come before the command (`timeout 5 cmd`, `script -q file cmd`).
    private static let wrappers: [String: (valued: Set<String>, leading: Int)] = [
        "env": (["-u", "-P", "-C", "--unset", "--chdir"], 0), "time": ([], 0), "nohup": ([], 0),
        "exec": (["-a"], 0), "command": ([], 0), "builtin": ([], 0), "nice": (["-n"], 0),
        "timeout": (["-s", "-k", "--signal", "--kill-after"], 1), "gtimeout": (["-s", "-k", "--signal", "--kill-after"], 1),
        "caffeinate": (["-t", "-w"], 0),
        "xargs": (["-n", "-I", "-P", "-L", "-s", "-E", "-d", "-J", "-R", "-S", "-a"], 0),
        "arch": (["-arch"], 0), "xcrun": (["-sdk", "--sdk", "-toolchain", "--toolchain", "-log"], 0),
        "script": (["-t", "-T"], 1), "lockf": (["-t"], 1), "setsid": ([], 0), "stdbuf": (["-i", "-o", "-e"], 0),
        "busybox": ([], 0), "unbuffer": ([], 0), "noglob": ([], 0), "nocorrect": ([], 0), "repeat": ([], 1),
        "-": ([], 0), "coproc": ([], 0),
        "taskpolicy": (["-c", "-t", "-l", "-g", "-p"], 0), "sandbox-exec": (["-f", "-n", "-p", "-D"], 0),
    ]
    /// Shell words that come before a command without changing it.
    private static let keywords: Set<String> = ["{", "}", "!", "if", "then", "else", "elif", "do", "while", "until",
                                                "fi", "done", "esac"]
    static let sudoValued: Set<String> = ["-u", "-g", "-p", "-C", "-h", "-U", "-r", "-t", "-D", "-R", "-T"]
    static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "fish", "csh", "tcsh", "ash", "mksh", "yash"]
    static let interpreters: Set<String> = ["deno", "bun", "swift", "rscript", "tclsh", "pwsh", "jshell", "osascript"]
    /// Interpreters that come with a version in the name (`python3.12`, `ruby3.3`).
    private static let versioned = ["python", "pypy", "ruby", "perl", "node", "php", "lua", "luajit"]

    /// The command's name as the system finds it: no folder, any case (macOS finds `RM`
    /// as `rm`), and no `=` in front (zsh turns `=rm` into rm's path).
    static func name(_ word: String) -> String {
        let base = (word.split(separator: "/").last.map(String.init) ?? word).lowercased()
        return base.hasPrefix("=") ? String(base.dropFirst()) : base
    }

    static func isAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        let target = word[..<equals].hasSuffix("+") ? word[..<equals].dropLast() : word[..<equals]
        guard let first = target.first, first.isLetter || first == "_" else { return false }
        return target.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    static func strip(_ words: [String]) -> Stripped {
        guard let first = words.first else { return .nothing }
        if isAssignment(first) || keywords.contains(first) { return strip(Array(words.dropFirst())) }
        if first == "function" { return strip(Array(words.dropFirst(2))) } // `function f { … }`
        let command = name(first)
        guard let wrapper = wrappers[command] else { return .runs(words) }
        let rest = Array(words.dropFirst())
        if command == "env", rest.contains(where: { isShortCluster($0, with: "S") || $0.hasPrefix("--split-string") }) {
            return .unclear
        }
        if ["command", "builtin"].contains(command), rest.first.map({ ["-v", "-V"].contains($0) }) == true {
            return .nothing // only looks the name up
        }
        return strip(Array(afterOptions(rest, valued: wrapper.valued).dropFirst(wrapper.leading)))
    }

    /// The words after the leading options (`-x`, `--long`, and the values of `valued`
    /// ones, including at the end of a cluster such as `-iu NAME`).
    static func afterOptions(_ words: [String], valued: Set<String>) -> ArraySlice<String> {
        var index = 0
        while index < words.count, words[index].hasPrefix("-"), words[index] != "-" {
            let word = words[index]
            if word == "--" { return words[(index + 1)...] }
            let clusterEnd = word.count > 2 && !word.hasPrefix("--") ? word.last.map { "-\($0)" } : nil
            let takesValue = valued.contains(word) || clusterEnd.map(valued.contains) == true
            index += takesValue ? 2 : 1
        }
        return words[min(index, words.count)...]
    }

    /// What `sudo` or `doas` runs, or the words themselves.
    static func withoutSudo(_ words: [String]) -> [String] {
        guard let first = words.first, ["sudo", "doas"].contains(name(first)) else { return words }
        guard case .runs(let inner) = strip(Array(afterOptions(Array(words.dropFirst()), valued: sudoValued))) else {
            return []
        }
        return inner
    }

    static func isInterpreter(_ command: String) -> Bool {
        shells.contains(command) || interpreters.contains(command) || versioned.contains { prefix in
            command.hasPrefix(prefix) && command.dropFirst(prefix.count).allSatisfy { $0.isNumber || $0 == "." }
        }
    }

    /// Interpreters, and `source`/`.`, which run a file as shell code.
    static func runsCode(_ command: String) -> Bool {
        isInterpreter(command) || ["source", "."].contains(command)
    }

    /// A shell or interpreter with no program given reads its program from its input.
    static func readsProgramFromInput(_ words: [String]) -> Bool {
        guard let first = words.first, runsCode(name(first)) else { return false }
        let args = Array(words.dropFirst())
        if ["source", "."].contains(name(first)) {
            return args.first.map { ["-", "/dev/stdin", "/dev/fd/0"].contains($0) } ?? false
        }
        let inline: Set<String> = ["-c", "-e", "-E", "-m", "-p", "-r"]
        let isShell = shells.contains(name(first))
        if args.contains(where: { arg in inline.contains(arg) || (isShell && isShortCluster(arg, with: "c")) }) {
            return false
        }
        if isShell, args.contains(where: { isShortCluster($0, with: "s") }) { return true }
        let program = afterOptions(args, valued: ["-o", "-O", "-W", "-X"]).first
        return program.map { ["-", "/dev/stdin", "/dev/fd/0"].contains($0) } ?? true
    }

    /// `-abc` style options that include `letter`.
    static func isShortCluster(_ word: String, with letter: Character) -> Bool {
        word.hasPrefix("-") && !word.hasPrefix("--") && word.dropFirst().contains(letter)
    }

    /// `--name`, or an unambiguous start of it (`--ha` for `--hard`), as git accepts.
    static func hasLongOption(_ words: [String], _ option: String) -> Bool {
        words.contains { $0 == option || ($0.count >= 4 && $0.hasPrefix("--") && option.hasPrefix($0)) }
    }

    /// The first word that isn't an option, and the words after it.
    static func subcommand(_ words: [String], valued: Set<String> = []) -> (name: String, rest: [String])? {
        let after = afterOptions(words, valued: valued)
        guard let first = after.first else { return nil }
        return (first, Array(after.dropFirst()))
    }
}
