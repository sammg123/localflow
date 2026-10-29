import Foundation

/// What LocalFlow does with a permission prompt.
enum AgentDecision: Equatable, Sendable {
    case allow
    /// Ask the user. `summary` is one plain line for the approval card; `grantKey` names
    /// the kind of action, so "Allow for this task" lets the next one of that kind through.
    case ask(summary: String, grantKey: String)
}

/// The "risky only" rule: everyday work runs, and the user is asked before anything that
/// deletes, sends, installs, runs as administrator, changes the system or can't be undone.
enum AgentPolicy {
    static let screenPrefix = "mcp__" + AgentInvocation.serverName + "__"
    /// The longest command or text an approval line shows.
    static let shownLimit = 120

    /// Reading, and Claude Code's own helpers: finding a tool, a subagent (whose every
    /// step comes here too), stopping one of its own background tasks.
    private static let readOnly: Set<String> = ["Read", "Glob", "Grep", "WebFetch", "WebSearch", "TodoWrite",
                                                "ToolSearch", "Task", "TaskStop"]
    private static let fileWriters: Set<String> = ["Write", "Edit", "NotebookEdit"]
    private static let screenSafe: Set<String> = ["screenshot", "list_apps", "wait", "move", "scroll", "drag"]
    private static let screenChecked: Set<String> = ["click", "type", "key", "open_app"]

    /// `targetTitle` is the accessibility title of the control under a click, when known;
    /// `frontApp` the bundle id of the app in front.
    static func decide(toolName: String, input: AgentJSON, grants: Set<String>, targetTitle: String?,
                       frontApp: String? = nil, home: String = NSHomeDirectory()) -> AgentDecision {
        let screen = AgentScreenRules.Place(targetTitle: targetTitle, frontApp: frontApp)
        let asks = reasons(toolName: toolName, input: input, screen: screen, home: home)
        // Kinds allowed only one at a time ask whatever was allowed before.
        let open = asks.first { !grants.contains($0.grantKey) || !AgentApproval.canGrant($0.grantKey) }
        return open.map { .ask(summary: $0.summary, grantKey: $0.grantKey) } ?? .allow
    }

    private struct Reason {
        let summary: String
        let grantKey: String
    }

    private static func reasons(toolName: String, input: AgentJSON, screen: AgentScreenRules.Place,
                                home: String) -> [Reason] {
        if readOnly.contains(toolName) { return [] }
        if toolName == "Bash" { return bash(input, home: home) }
        if toolName == "Monitor" { return monitor(input, home: home) }
        if fileWriters.contains(toolName) { return file(input, home: home) }
        if toolName.hasPrefix(screenPrefix) {
            let action = String(toolName.dropFirst(screenPrefix.count))
            if screenSafe.contains(action) { return [] }
            if let reason = AgentScreenRules.reason(action: action, input: input, at: screen) {
                return [Reason(summary: reason.summary, grantKey: reason.grantKey)]
            }
            if screenChecked.contains(action) { return [] }
        }
        // A connector's tools: looking runs, anything else asks, one tool at a time.
        if let tool = ConnectorTool(toolName: toolName) {
            return tool.isReadLike ? [] : [Reason(summary: clip(tool.summary), grantKey: tool.grantKey)]
        }
        return [Reason(summary: "Use \(toolName)", grantKey: "tool:\(toolName)")]
    }

    private static func bash(_ input: AgentJSON, home: String) -> [Reason] {
        guard let command = input["command"]?.string else {
            return [Reason(summary: "Run a command", grantKey: "Bash:unknown")]
        }
        let place = AgentBash.Place(home: home, workingDirectory: AgentInvocation.workingDirectory(home: home))
        return AgentBash.risks(in: command, at: place).map { risk in
            let shown = "`" + clip(risk.shown) + "`"
            return Reason(summary: risk.label.map { "\($0): \(shown)" } ?? "Run \(shown)", grantKey: risk.key)
        }
    }

    /// A watch runs a command like Bash does; one on a live connection asks.
    private static func monitor(_ input: AgentJSON, home: String) -> [Reason] {
        if input["command"] == nil, let url = input["ws"]?["url"]?.string {
            return [Reason(summary: "Watch a live connection to `\(clip(url))`", grantKey: "Monitor:ws")]
        }
        return bash(input, home: home)
    }

    private static func file(_ input: AgentJSON, home: String) -> [Reason] {
        guard let path = input["file_path"]?.string ?? input["notebook_path"]?.string else {
            return [Reason(summary: "Write a file", grantKey: "file:unknown")]
        }
        let workingDirectory = AgentInvocation.workingDirectory(home: home)
        guard AgentPaths.isProtected(path, home: home, workingDirectory: workingDirectory) else { return [] }
        let full = AgentPaths.absolute(path, home: home, workingDirectory: workingDirectory)
        if full.lowercased() == AgentPaths.instructionsFile(home: home).lowercased() {
            return [Reason(summary: "Change your standing instructions (localflow.md)", grantKey: "file:" + full)]
        }
        return [Reason(summary: "Write `\(clip(full))`", grantKey: "file:" + full)]
    }

    /// At most `shownLimit` characters on one line, hidden characters showing.
    static func clip(_ text: String) -> String {
        let line = ShownText.visible(text.replacingOccurrences(of: "\n", with: " "))
        return line.count <= shownLimit ? line : String(line.prefix(shownLimit - 1)) + "…"
    }
}
