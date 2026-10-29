import Foundation

/// What the agent is doing, in plain words for the panel: "Run the tests", "Read plan.md",
/// "Click “Send”". Shown on screen only, never logged.
enum AgentStepTitle {
    static let maxLength = 60
    private static let screenPrefix = "mcp__\(AgentInvocation.serverName)__"

    static func title(toolName: String, input: AgentJSON, target: String?) -> String {
        clip(words(toolName: toolName, input: input, target: target))
    }

    private static func words(toolName: String, input: AgentJSON, target: String?) -> String {
        let text = { (key: String) in input[key]?.string ?? "" }
        if toolName.hasPrefix(screenPrefix) {
            return screen(String(toolName.dropFirst(screenPrefix.count)), input: input, target: target)
        }
        if let connector = ConnectorTool(toolName: toolName) { return connector.summary }
        switch toolName {
        case "Bash":
            let said = text("description").trimmingCharacters(in: .whitespacesAndNewlines)
            return said.isEmpty ? "Run \(text("command"))" : said
        case "Read": return "Read \(fileName(text("file_path")))"
        case "Write": return "Write \(fileName(text("file_path")))"
        case "Edit": return "Edit \(fileName(text("file_path")))"
        case "Glob": return "Find files matching \(text("pattern"))"
        case "Grep": return "Search files for “\(text("pattern"))”"
        case "WebFetch": return "Open \(URL(string: text("url"))?.host ?? "a web page")"
        case "WebSearch": return "Search the web for “\(text("query"))”"
        case "TodoWrite": return "Update the plan"
        default: return "Use \(toolName.split(separator: "_").last.map(String.init) ?? toolName)"
        }
    }

    private static func screen(_ tool: String, input: AgentJSON, target: String?) -> String {
        switch tool {
        case "screenshot": return "Look at the screen"
        case "click":
            let verb = input["button"]?.string == "right" ? "Right-click"
                : input["clicks"]?.number == 2 ? "Double-click" : "Click"
            return target.map { "\(verb) “\($0)”" } ?? verb
        case "type": return "Type “\(input["text"]?.string ?? "")”"
        case "key": return "Press \(input["keys"]?.string ?? "a key")"
        case "scroll": return "Scroll \(input["direction"]?.string ?? "")"
        case "open_app": return "Open \(input["name"]?.string ?? "an app")"
        case "list_apps": return "Check which apps are open"
        case "wait": return "Wait \(Int(input["seconds"]?.number ?? 0))s"
        case "drag": return "Drag"
        case "move": return "Move the pointer"
        default: return "Use \(tool)"
        }
    }

    private static func fileName(_ path: String) -> String {
        path.isEmpty ? "a file" : (path as NSString).lastPathComponent
    }

    private static func clip(_ text: String) -> String {
        let line = ShownText.visible(text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces))
        return line.count <= maxLength ? line : String(line.prefix(maxLength - 1)) + "…"
    }
}
