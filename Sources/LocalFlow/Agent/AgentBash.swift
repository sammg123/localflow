import Foundation

/// The "risky only" rule for terminal commands: every command a line runs is checked,
/// including inside `$(…)`, backticks, `sh -c` and text fed to a shell, and the line asks
/// when any one is risky.
enum AgentBash {
    /// One risky command: what kind (for "Allow for this task") and how it reads.
    struct Risk: Equatable {
        /// Says what it does, such as "Delete files"; nil reads as plain "Run".
        let label: String?
        let key: String
        let shown: String
    }

    /// Where paths are read from, for files written.
    struct Place {
        let home: String
        let workingDirectory: String
    }

    /// Nesting deeper than this (`sh -c` inside `sh -c` …) asks rather than guess.
    static let maxDepth = 8

    static func risks(in command: String, at place: Place) -> [Risk] {
        launchesLocalFlow(command) + risks(in: command, depth: 0, place, directory: place.workingDirectory)
    }

    /// LocalFlow's app or its screen server named anywhere in the line: run that way, it
    /// would act on the screen past every check here. Each command's words are checked
    /// again once unquoted (`Local""Flow`), in AgentCommands.
    static let localFlowMarks = ["computer-mcp", "localflow.app", "macos/localflow"]

    private static func launchesLocalFlow(_ command: String) -> [Risk] {
        let lower = command.lowercased()
        guard localFlowMarks.contains(where: lower.contains) else { return [] }
        return [Risk(label: "Run LocalFlow itself", key: "Bash:localflow", shown: command)]
    }

    /// `directory` is where the text starts running, nil when a `cd` made it unknowable.
    static func risks(in text: String, depth: Int, _ place: Place, directory: String?) -> [Risk] {
        guard depth <= maxDepth else {
            return [Risk(label: "Run a command too nested to check", key: "Bash:complex", shown: text)]
        }
        let parsed = AgentShell.parse(text)
        let unclear = parsed.unclear ? [Risk(label: "Run a command that can't be checked", key: "Bash:complex", shown: text)] : []
        let inner = parsed.substitutions.flatMap { risks(in: $0, depth: depth + 1, place, directory: directory) }
        let steps = parsed.pipelines.flatMap { pipeline in
            pipeline.indices.map { (command: pipeline[$0], upstream: Array(pipeline[..<$0])) }
        }
        // Walk in order so a `cd` moves where later relative paths point.
        let walked = steps.reduce((directory: directory, risks: [Risk]())) { walk, step in
            let context = Context(shown: AgentShell.display(step.command.words), depth: depth, place: place,
                                  directory: walk.directory)
            let found = risks(of: step.command, after: step.upstream, context)
            return (Self.directory(after: step.command, from: walk.directory, place), walk.risks + found)
        }
        return unclear + inner + parsed.feeds.flatMap { fedOutput($0, line: text) } + walked.risks
    }

    /// `>(sh)`: what the command writes is run as code.
    private static func fedOutput(_ feed: String, line: String) -> [Risk] {
        guard let words = AgentShell.parse(feed).pipelines.first?.first?.words,
              case .runs(let program) = AgentCommandWords.strip(words),
              AgentCommandWords.readsProgramFromInput(AgentCommandWords.withoutSudo(program)) else { return [] }
        return [downloaded(line) ? Risk(label: "Run downloaded code", key: "Bash:curl | sh", shown: line)
            : Risk(label: "Run code piped into a shell", key: "Bash:pipe to shell", shown: line)]
    }

    private static func risks(of command: AgentShell.Command, after upstream: [AgentShell.Command],
                              _ context: Context) -> [Risk] {
        let place = context.place
        let writes = command.writes
            .filter { AgentPaths.isRiskyTarget($0, home: place.home, directory: context.directory) }
            .map { Risk(label: "Write to a protected file", key: "Bash:write protected",
                        shown: context.shown + " > " + AgentShell.quote($0)) }
        switch AgentCommandWords.strip(command.words) {
        case .nothing:
            return writes
        case .unclear:
            return writes + [context.risk("Run a command that can't be checked", "Bash:complex")]
        case .runs(let words):
            return writes + piped(words, from: upstream, context) + fed(words, command.inputs, context)
                + AgentCommands.risks(words, context)
        }
    }

    /// Output piped into a shell or interpreter. From curl or wget that's downloaded code,
    /// whatever the interpreter's options; otherwise it asks when the code comes from the pipe.
    private static func piped(_ words: [String], from upstream: [AgentShell.Command], _ context: Context) -> [Risk] {
        let program = AgentCommandWords.withoutSudo(words)
        guard !upstream.isEmpty, let first = program.first,
              AgentCommandWords.runsCode(AgentCommandWords.name(first)) else { return [] }
        let downloads = upstream.contains { command in
            guard case .runs(let words) = AgentCommandWords.strip(command.words), let first = words.first else { return false }
            return ["curl", "wget"].contains(AgentCommandWords.name(first))
        }
        if downloads { return [context.risk("Run downloaded code", "Bash:curl | sh")] }
        guard AgentCommandWords.readsProgramFromInput(program) else { return [] }
        return [context.risk("Run code piped into a shell", "Bash:pipe to shell")]
    }

    /// Input redirected into a shell or interpreter: `< <(curl …)`, here-strings and heredocs.
    /// Text fed to a shell is checked as commands.
    private static func fed(_ words: [String], _ inputs: [AgentShell.Input], _ context: Context) -> [Risk] {
        let program = AgentCommandWords.withoutSudo(words)
        guard let first = program.first, AgentCommandWords.readsProgramFromInput(program) else { return [] }
        let isShell = AgentCommandWords.shells.contains(AgentCommandWords.name(first))
        return inputs.flatMap { input -> [Risk] in
            switch input {
            case .file(let source) where source.hasPrefix("<("):
                return [downloaded(source) ? context.risk("Run downloaded code", "Bash:curl | sh")
                    : context.risk("Run code piped into a shell", "Bash:pipe to shell")]
            case .file:
                return []
            case .text(let text):
                if downloaded(text) { return [context.risk("Run downloaded code", "Bash:curl | sh")] }
                return isShell ? context.nested(text) : []
            }
        }
    }

    static func downloaded(_ text: String) -> Bool {
        text.contains("curl") || text.contains("wget")
    }

    /// Where the next command runs after this one: moved by `cd`/`pushd`, or unknown
    /// (nil) when the folder depends on something only the shell knows.
    private static func directory(after command: AgentShell.Command, from current: String?, _ place: Place) -> String? {
        guard case .runs(let words) = AgentCommandWords.strip(command.words), let first = words.first,
              ["cd", "pushd"].contains(AgentCommandWords.name(first)) else { return current }
        let target = AgentCommandWords.afterOptions(Array(words.dropFirst()), valued: []).first ?? "~"
        guard target != "-", let path = AgentPaths.shellPath(target, home: place.home) else { return nil }
        guard path.hasPrefix("/") || path.hasPrefix("~") || current != nil else { return nil }
        return AgentPaths.absolute(path, home: place.home, workingDirectory: current ?? place.workingDirectory)
    }

    /// What every rule needs to describe a risk and to look inside nested commands.
    struct Context {
        let shown: String
        let depth: Int
        let place: Place
        /// Where relative paths point; nil when a `cd` made it unknowable.
        let directory: String?

        func risk(_ label: String?, _ key: String) -> Risk {
            Risk(label: label, key: key, shown: shown)
        }

        func nested(_ text: String) -> [Risk] {
            AgentBash.risks(in: text, depth: depth + 1, place, directory: directory)
        }
    }
}
