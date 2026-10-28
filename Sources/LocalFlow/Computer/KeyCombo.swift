import Carbon.HIToolbox
import CoreGraphics

/// One key press with held modifiers, read from text like "cmd+shift+t" or "return".
/// Key codes are the US (ANSI) positions, the same assumption the paste shortcut makes.
struct KeyCombo: Equatable, Sendable {
    enum Modifier: String, CaseIterable, Sendable {
        case command, shift, option, control

        /// Case-insensitive, with the usual aliases (cmd, ctrl, opt, alt).
        static func named(_ name: String) -> Modifier? {
            aliases[name.lowercased()]
        }

        private static let aliases: [String: Modifier] = [
            "cmd": .command, "command": .command, "super": .command,
            "shift": .shift,
            "opt": .option, "option": .option, "alt": .option,
            "ctrl": .control, "control": .control,
        ]

        var flag: CGEventFlags {
            switch self {
            case .command: return .maskCommand
            case .shift: return .maskShift
            case .option: return .maskAlternate
            case .control: return .maskControl
            }
        }

        var keyCode: CGKeyCode {
            switch self {
            case .command: return CGKeyCode(kVK_Command)
            case .shift: return CGKeyCode(kVK_Shift)
            case .option: return CGKeyCode(kVK_Option)
            case .control: return CGKeyCode(kVK_Control)
            }
        }
    }

    let keyCode: CGKeyCode
    let modifiers: Set<Modifier>
    /// Flags a real keyboard adds for this key on its own (fn and keypad for arrows).
    let keyFlags: CGEventFlags

    init(keyCode: CGKeyCode, modifiers: Set<Modifier>, keyFlags: CGEventFlags = []) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyFlags = keyFlags
    }

    /// Everything the key event carries.
    var flags: CGEventFlags {
        modifiers.reduce(keyFlags) { $0.union($1.flag) }
    }

    static func parse(_ text: String) -> KeyCombo? {
        try? parseResult(text).get()
    }

    static func parseResult(_ text: String) -> Result<KeyCombo, KeyComboError> {
        let tokens = KeyNames.tokens(in: text)
        guard !tokens.isEmpty else { return .failure(.empty) }
        var modifiers: Set<Modifier> = []
        var keys: [KeyNames.Key] = []
        for token in tokens {
            if let modifier = Modifier.named(token) {
                modifiers.insert(modifier)
            } else if token.isEmpty {
                return .failure(.missingKey)
            } else if let key = KeyNames.key(named: token) {
                keys.append(key)
            } else {
                return .failure(.unknownKey(token))
            }
        }
        guard let key = keys.first else { return .failure(.missingKey) }
        guard keys.count == 1 else { return .failure(.tooManyKeys) }
        let combo = KeyCombo(keyCode: key.code, modifiers: modifiers.union(key.modifiers), keyFlags: key.flags)
        return .success(combo)
    }
}

enum KeyComboError: Error, Equatable, Sendable {
    case empty
    case unknownKey(String)
    case missingKey
    case tooManyKeys

    var message: String {
        switch self {
        case .empty:
            return "keys is empty. Name a key, like return or cmd+c."
        case .unknownKey(let name):
            return "Unknown key \"\(name)\". Use return, escape, tab, space, delete, forwarddelete, "
                + "up, down, left, right, home, end, pageup, pagedown, f1 to f12, or a single character, "
                + "joined to cmd, shift, option or control with + (like cmd+shift+t)."
        case .missingKey:
            return "keys needs a key besides the modifiers, like cmd+c."
        case .tooManyKeys:
            return "keys can press one key at a time (with modifiers). Send separate key calls."
        }
    }
}

/// The key names and characters `KeyCombo` understands.
enum KeyNames {
    struct Key {
        let code: CGKeyCode
        let modifiers: Set<KeyCombo.Modifier>
        let flags: CGEventFlags
    }

    /// Lowercased, trimmed parts between "+", where a trailing "++" means the + key.
    static func tokens(in text: String) -> [String] {
        let lowered = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !lowered.isEmpty else { return [] }
        var parts = lowered.split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count >= 2, parts[parts.count - 1].isEmpty, parts[parts.count - 2].isEmpty {
            parts.removeLast(2)
            parts.append("+")
        }
        return parts
    }

    static func key(named token: String) -> Key? {
        if token.count == 1, let character = token.first {
            if let code = plainCharacters[character] { return Key(code: code, modifiers: [], flags: []) }
            if let code = shiftedCharacters[character] { return Key(code: code, modifiers: [.shift], flags: []) }
            return nil
        }
        let name = token.replacingOccurrences(of: "_", with: "")
        guard let named = namedKeys[name] else { return nil }
        return Key(code: CGKeyCode(named.code), modifiers: [], flags: named.flags)
    }

    private static let arrow: CGEventFlags = [.maskSecondaryFn, .maskNumericPad]
    private static let function: CGEventFlags = .maskSecondaryFn

    private static let namedKeys: [String: (code: Int, flags: CGEventFlags)] = [
        "return": (kVK_Return, []), "enter": (kVK_Return, []),
        "escape": (kVK_Escape, []), "esc": (kVK_Escape, []),
        "tab": (kVK_Tab, []), "space": (kVK_Space, []),
        "delete": (kVK_Delete, []), "backspace": (kVK_Delete, []),
        "forwarddelete": (kVK_ForwardDelete, function),
        "up": (kVK_UpArrow, arrow), "down": (kVK_DownArrow, arrow),
        "left": (kVK_LeftArrow, arrow), "right": (kVK_RightArrow, arrow),
        "home": (kVK_Home, function), "end": (kVK_End, function),
        "pageup": (kVK_PageUp, function), "pagedown": (kVK_PageDown, function),
        "f1": (kVK_F1, function), "f2": (kVK_F2, function), "f3": (kVK_F3, function),
        "f4": (kVK_F4, function), "f5": (kVK_F5, function), "f6": (kVK_F6, function),
        "f7": (kVK_F7, function), "f8": (kVK_F8, function), "f9": (kVK_F9, function),
        "f10": (kVK_F10, function), "f11": (kVK_F11, function), "f12": (kVK_F12, function),
        "minus": (kVK_ANSI_Minus, []), "equal": (kVK_ANSI_Equal, []), "comma": (kVK_ANSI_Comma, []),
        "period": (kVK_ANSI_Period, []), "slash": (kVK_ANSI_Slash, []),
    ]

    private static let plainCharacters: [Character: CGKeyCode] = {
        let table: [Character: Int] = [
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
            "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J,
            "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
            "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
            "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y,
            "z": kVK_ANSI_Z,
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
            "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
            "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket,
            "\\": kVK_ANSI_Backslash, ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma,
            ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash, "`": kVK_ANSI_Grave, " ": kVK_Space,
        ]
        return table.mapValues { CGKeyCode($0) }
    }()

    /// Characters typed with shift held, by their unshifted key on a US keyboard.
    private static let shiftedCharacters: [Character: CGKeyCode] = {
        let table: [Character: Int] = [
            "!": kVK_ANSI_1, "@": kVK_ANSI_2, "#": kVK_ANSI_3, "$": kVK_ANSI_4, "%": kVK_ANSI_5,
            "^": kVK_ANSI_6, "&": kVK_ANSI_7, "*": kVK_ANSI_8, "(": kVK_ANSI_9, ")": kVK_ANSI_0,
            "_": kVK_ANSI_Minus, "+": kVK_ANSI_Equal, "{": kVK_ANSI_LeftBracket, "}": kVK_ANSI_RightBracket,
            "|": kVK_ANSI_Backslash, ":": kVK_ANSI_Semicolon, "\"": kVK_ANSI_Quote, "<": kVK_ANSI_Comma,
            ">": kVK_ANSI_Period, "?": kVK_ANSI_Slash, "~": kVK_ANSI_Grave,
        ]
        return table.mapValues { CGKeyCode($0) }
    }()
}
