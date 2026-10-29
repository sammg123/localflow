import Carbon.HIToolbox
import Foundation

/// Clicks, typing, key presses and opened apps on the screen: they ask when marked
/// irreversible, when the button's title sends, pays or deletes, for keys that delete or
/// send, and for apps that run commands.
enum AgentScreenRules {
    /// What's known about where an action lands.
    struct Place {
        /// The accessibility title of the control under a click.
        let targetTitle: String?
        /// The bundle id of the app in front.
        let frontApp: String?
    }

    /// Button words that send, pay, delete or commit, matched as whole words or phrases.
    static let riskyTitles = ["place order", "empty trash", "reply all", "send", "submit", "post", "publish", "pay",
                              "buy", "purchase", "order", "checkout", "delete", "remove", "erase", "trash", "transfer",
                              "confirm", "sign", "accept", "unsubscribe"]
    /// Phrases with a risky word in them that are everyday clicks.
    static let everydayTitles = ["sign in", "sign out"]
    /// Keys that delete when pressed with cmd (cmd+delete, cmd+shift+delete, cmd+option+delete …).
    static let deleteKeys: Set<String> = ["delete", "forwarddelete"]

    static func reason(action: String, input: AgentJSON, at place: Place) -> (summary: String, grantKey: String)? {
        let irreversible = input["irreversible"]?.bool == true || input["irreversible"]?.string == "true"
        switch action {
        case "click":
            if let title = place.targetTitle, let word = riskyWord(in: title) {
                return ("Click “\(AgentPolicy.clip(title))”", "click:" + word)
            }
            return irreversible ? ("Click at (\(coordinate(input["x"])), \(coordinate(input["y"])))", "click:irreversible") : nil
        case "type":
            let typed = input["text"]?.string ?? ""
            let text = AgentPolicy.clip(typed)
            if AgentApps.isMessenger(place.frontApp), typed.contains(where: \.isNewline) {
                return ("Type “\(text)” (it may send)", "type:send")
            }
            return irreversible ? ("Type “\(text)”", "type:irreversible") : nil
        case "key":
            return key(input["keys"]?.string ?? "", irreversible: irreversible, frontApp: place.frontApp)
        case "open_app":
            let name = input["name"]?.string ?? ""
            guard AgentApps.isRunner(name) else { return nil }
            return ("Open \(AgentPolicy.clip(name.trimmingCharacters(in: .whitespacesAndNewlines)))",
                    "open:" + AgentApps.normalized(name))
        default:
            return nil
        }
    }

    /// Read both by name and by the key tool's own parser, so no spelling of a key slips past.
    private static func key(_ keys: String, irreversible: Bool, frontApp: String?) -> (summary: String, grantKey: String)? {
        let named = keyCombos(keys)
        let pressed = KeyCombo.parse(keys)
        let shown = named.first ?? AgentPolicy.clip(keys)
        if let combo = named.first(where: isDestructive) {
            return ("Press \(combo)", "key:" + combo)
        }
        if let pressed, deletes(pressed) {
            return ("Press \(shown)", "key:" + shown)
        }
        if let pressed, sends(pressed, frontApp: frontApp) {
            return ("Press \(shown) (it may send)", "key:send")
        }
        return irreversible ? ("Press \(AgentPolicy.clip(keys))", "key:irreversible") : nil
    }

    static func isDestructive(_ combo: String) -> Bool {
        let parts = combo.split(separator: "+").map(String.init)
        return parts.contains("cmd") && parts.last.map(deleteKeys.contains) == true
    }

    private static func deletes(_ combo: KeyCombo) -> Bool {
        combo.modifiers.contains(.command)
            && [CGKeyCode(kVK_Delete), CGKeyCode(kVK_ForwardDelete)].contains(combo.keyCode)
    }

    /// cmd+return sends in mail and chat apps; in one of those, plain return does too.
    private static func sends(_ combo: KeyCombo, frontApp: String?) -> Bool {
        guard combo.keyCode == CGKeyCode(kVK_Return) else { return false }
        if combo.modifiers.contains(.command) { return true }
        return AgentApps.isMessenger(frontApp) && combo.modifiers.isDisjoint(with: [.shift, .option])
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

    /// Each combo in `keys` written one way: lowercase, no underscores (as the key tool
    /// reads them), modifiers in a fixed order.
    static func keyCombos(_ keys: String) -> [String] {
        let aliases = ["command": "cmd", "⌘": "cmd", "meta": "cmd", "super": "cmd", "alt": "option", "opt": "option",
                       "⌥": "option", "control": "ctrl", "⌃": "ctrl", "⇧": "shift", "backspace": "delete",
                       "⌫": "delete", "⌦": "forwarddelete", "fwddelete": "forwarddelete"]
        let order = ["cmd", "ctrl", "option", "shift"]
        let joined = keys.lowercased().replacingOccurrences(of: #"\s*\+\s*"#, with: "+", options: .regularExpression)
        return joined.split(whereSeparator: { $0 == " " || $0 == "," }).map { combo in
            let parts = combo.split(separator: "+").map { part in
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                let name = trimmed.count > 1 ? trimmed.replacingOccurrences(of: "_", with: "") : trimmed
                return aliases[name] ?? name
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
