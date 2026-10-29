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

    private static let readOnly: Set<String> = ["Read", "Glob", "Grep", "WebFetch", "WebSearch", "TodoWrite"]
    private static let fileWriters: Set<String> = ["Write", "Edit"]
    private static let screenSafe: Set<String> = ["screenshot", "list_apps", "wait", "move", "scroll", "open_app", "drag"]

    /// `targetTitle` is the accessibility title of the control under a click, when known.
    static func decide(toolName: String, input: AgentJSON, grants: Set<String>, targetTitle: String?,
                       home: String = NSHomeDirectory()) -> AgentDecision {
        let asks = reasons(toolName: toolName, input: input, targetTitle: targetTitle, home: home)
        return asks.first { !grants.contains($0.grantKey) }.map { .ask(summary: $0.summary, grantKey: $0.grantKey) }
            ?? .allow
    }

    private struct Reason {
        let summary: String
        let grantKey: String
    }

    private static func reasons(toolName: String, input: AgentJSON, targetTitle: String?, home: String) -> [Reason] {
        if readOnly.contains(toolName) { return [] }
        if toolName == "Bash" { return bash(input, home: home) }
        if fileWriters.contains(toolName) { return file(input, home: home) }
        if toolName.hasPrefix(screenPrefix) {
            let action = String(toolName.dropFirst(screenPrefix.count))
            if screenSafe.contains(action) { return [] }
            if let reason = AgentScreenRules.reason(action: action, input: input, targetTitle: targetTitle) {
                return [Reason(summary: reason.summary, grantKey: reason.grantKey)]
            }
            if ["click", "type", "key"].contains(action) { return [] }
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

    private static func file(_ input: AgentJSON, home: String) -> [Reason] {
        guard let path = input["file_path"]?.string else {
            return [Reason(summary: "Write a file", grantKey: "file:unknown")]
        }
        let workingDirectory = AgentInvocation.workingDirectory(home: home)
        guard AgentPaths.isProtected(path, home: home, workingDirectory: workingDirectory) else { return [] }
        let full = AgentPaths.absolute(path, home: home, workingDirectory: workingDirectory)
        return [Reason(summary: "Write `\(clip(full))`", grantKey: "file:" + full)]
    }

    /// At most `shownLimit` characters on one line.
    static func clip(_ text: String) -> String {
        let line = text.replacingOccurrences(of: "\n", with: " ")
        return line.count <= shownLimit ? line : String(line.prefix(shownLimit - 1)) + "…"
    }
}

/// Clicks, typing and key presses on the screen: they ask when marked irreversible, when
/// the button's title sends, pays or deletes, or for keys that delete.
enum AgentScreenRules {
    /// Button words that send, pay, delete or commit, matched as whole words or phrases.
    static let riskyTitles = ["place order", "empty trash", "reply all", "send", "submit", "post", "publish", "pay",
                              "buy", "purchase", "order", "checkout", "delete", "remove", "erase", "trash", "transfer",
                              "confirm", "sign", "accept", "unsubscribe"]
    /// Phrases with a risky word in them that are everyday clicks.
    static let everydayTitles = ["sign in", "sign out"]
    /// Keys that delete when pressed with cmd (cmd+delete, cmd+shift+delete, cmd+option+delete …).
    static let deleteKeys: Set<String> = ["delete", "forwarddelete"]

    static func reason(action: String, input: AgentJSON, targetTitle: String?) -> (summary: String, grantKey: String)? {
        let irreversible = input["irreversible"]?.bool == true || input["irreversible"]?.string == "true"
        switch action {
        case "click":
            if let title = targetTitle, let word = riskyWord(in: title) {
                return ("Click “\(AgentPolicy.clip(title))”", "click:" + word)
            }
            return irreversible ? ("Click at (\(coordinate(input["x"])), \(coordinate(input["y"])))", "click:irreversible") : nil
        case "type":
            let text = AgentPolicy.clip(input["text"]?.string ?? "")
            return irreversible ? ("Type “\(text)”", "type:irreversible") : nil
        case "key":
            let keys = input["keys"]?.string ?? ""
            if let combo = keyCombos(keys).first(where: isDestructive) {
                return ("Press \(combo)", "key:" + combo)
            }
            return irreversible ? ("Press \(keys)", "key:irreversible") : nil
        default:
            return nil
        }
    }

    static func isDestructive(_ combo: String) -> Bool {
        let parts = combo.split(separator: "+").map(String.init)
        return parts.contains("cmd") && parts.last.map(deleteKeys.contains) == true
    }

    /// The first risky word or phrase in a title, ignoring case, look-alike forms and
    /// invisible characters, and everyday phrases.
    static func riskyWord(in title: String) -> String? {
        let visible = String(String.UnicodeScalarView(title.precomposedStringWithCompatibilityMapping.unicodeScalars
            .filter { $0.properties.generalCategory != .format }))
        let cleaned = everydayTitles.reduce(visible.lowercased()) { text, phrase in
            text.replacingOccurrences(of: #"\b\#(phrase)\b"#, with: " ", options: .regularExpression)
        }
        return riskyTitles.first { word in
            cleaned.range(of: #"\b\#(NSRegularExpression.escapedPattern(for: word))\b"#,
                          options: .regularExpression) != nil
        }
    }

    /// Each combo in `keys` written one way: lowercase, modifiers in a fixed order.
    static func keyCombos(_ keys: String) -> [String] {
        let aliases = ["command": "cmd", "⌘": "cmd", "meta": "cmd", "super": "cmd", "alt": "option", "opt": "option",
                       "⌥": "option", "control": "ctrl", "⌃": "ctrl", "⇧": "shift", "backspace": "delete",
                       "⌫": "delete", "⌦": "forwarddelete", "fwddelete": "forwarddelete"]
        let order = ["cmd", "ctrl", "option", "shift"]
        let joined = keys.lowercased().replacingOccurrences(of: #"\s*\+\s*"#, with: "+", options: .regularExpression)
        return joined.split(whereSeparator: { $0 == " " || $0 == "," }).map { combo in
            let parts = combo.split(separator: "+").map { part in
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                return aliases[trimmed] ?? trimmed
            }
            let modifiers = order.filter(parts.contains)
            let rest = parts.filter { !order.contains($0) }
            return (modifiers + rest).joined(separator: "+")
        }
    }

    private static func coordinate(_ value: AgentJSON?) -> String {
        guard let number = value?.number, number.isFinite, abs(number) < 1e9 else { return "?" }
        return number.rounded() == number ? String(Int(number)) : String(number)
    }
}
