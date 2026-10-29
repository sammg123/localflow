import Foundation

/// After a run: does a changed file look broken? Each check compares the file with how it
/// was before the run, and they're kept conservative, so a normal small edit (a color, a
/// modifier line, a JSX attribute, new copy) never trips one.
enum InstantVerify {
    /// A file must lose more than this many lines, as well as more than half, to count as cut.
    static let shrinkLines = 20
    private static let jsonExtensions: Set<String> = ["json", "xcstrings", "webmanifest"]
    private static let plistExtensions: Set<String> = ["plist", "entitlements", "xcprivacy", "strings"]

    /// Why `after` looks broken next to `before`, or nil. `after` is nil when the file is gone.
    static func problem(name: String, before: Data, after: Data?) -> String? {
        guard let after else { return before.isEmpty ? nil : "gone" }
        if after.isEmpty, !before.isEmpty { return "emptied" }
        let beforeLines = lineCount(before)
        let afterLines = lineCount(after)
        if beforeLines - afterLines > shrinkLines, afterLines * 2 < beforeLines { return "cut" }
        let wasText = String(data: before, encoding: .utf8) != nil
        guard let text = String(data: after, encoding: .utf8) else { return wasText ? "not text" : nil }
        let ext = InstantPaths.fileExtension(name)
        if jsonExtensions.contains(ext), parsesJSON(before), !parsesJSON(after) { return "JSON" }
        if plistExtensions.contains(ext), parsesPlist(before), !parsesPlist(after) { return "plist" }
        if let family = InstantBrackets.Family(fileExtension: ext), wasText,
           InstantBrackets.isWorse(after: text, before: String(decoding: before, as: UTF8.self), family: family) {
            return "brackets"
        }
        return nil
    }

    static func lineCount(_ data: Data) -> Int {
        data.isEmpty ? 0 : data.reduce(0) { $1 == UInt8(ascii: "\n") ? $0 + 1 : $0 } + (data.last == UInt8(ascii: "\n") ? 0 : 1)
    }

    private static func parsesJSON(_ data: Data) -> Bool {
        (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
    }

    private static func parsesPlist(_ data: Data) -> Bool {
        (try? PropertyListSerialization.propertyList(from: data, format: nil)) != nil
    }
}

/// Bracket balance in code, with strings and comments left out. The heuristic: per kind
/// ({} [] ()), count opens minus closes; a file is worse when any kind ends further from
/// balanced than it was before the run. Single quotes aren't strings in C-like code (JSX
/// text is full of apostrophes), and plain strings end at a line's end, so one stray
/// quote can't hide the rest of a file.
enum InstantBrackets {
    enum Family {
        case cLike, css, scss, script

        init?(fileExtension ext: String) {
            switch ext {
            case "swift", "ts", "tsx", "js", "jsx", "mjs", "cjs", "kt", "kts", "java", "c", "h", "m", "mm", "cpp", "cc",
                 "cxx", "hpp", "go", "rs", "cs", "dart", "scala", "php", "vue", "svelte", "groovy":
                self = .cLike
            case "css": self = .css
            case "scss", "less": self = .scss
            case "py", "rb": self = .script
            default: return nil
            }
        }

        var lineComment: String? {
            switch self {
            case .cLike, .scss: return "//"
            case .script: return "#"
            case .css: return nil
            }
        }

        var quotes: Set<Unicode.Scalar> {
            switch self {
            case .cLike: return ["\"", "`"]
            case .css, .scss, .script: return ["\"", "'"]
            }
        }
    }

    struct Balance: Equatable {
        var curly = 0
        var square = 0
        var round = 0
    }

    static func isWorse(after: String, before: String, family: Family) -> Bool {
        let old = balance(before, family: family)
        let new = balance(after, family: family)
        return abs(new.curly) > abs(old.curly) || abs(new.square) > abs(old.square) || abs(new.round) > abs(old.round)
    }

    static func balance(_ text: String, family: Family) -> Balance {
        let chars = Array(text.unicodeScalars)
        var counts = Balance()
        var at = 0
        while at < chars.count {
            if let skipped = skip(at, in: chars, family: family) {
                at = skipped
                continue
            }
            switch chars[at] {
            case "{": counts.curly += 1
            case "}": counts.curly -= 1
            case "[": counts.square += 1
            case "]": counts.square -= 1
            case "(": counts.round += 1
            case ")": counts.round -= 1
            default: break
            }
            at += 1
        }
        return counts
    }

    /// Where a comment or string starting at `at` ends, or nil when none starts there.
    private static func skip(_ at: Int, in chars: [Unicode.Scalar], family: Family) -> Int? {
        let c = chars[at]
        if let line = family.lineComment, c == line.unicodeScalars.first,
           starts(Array(line.unicodeScalars), at, chars) {
            return chars[at...].firstIndex(of: "\n") ?? chars.count
        }
        if c == "/", family != .script, starts(["/", "*"], at, chars) {
            return end(of: ["*", "/"], from: at + 2, in: chars)
        }
        guard family.quotes.contains(c) else { return nil }
        let triple = [c, c, c]
        if c != "`", starts(triple, at, chars) { return end(of: triple, from: at + 3, in: chars) }
        var index = at + 1
        while index < chars.count {
            if chars[index] == "\\" {
                index += 2
                continue
            }
            if chars[index] == c { return index + 1 }
            if chars[index] == "\n", c != "`" { return index }
            index += 1
        }
        return chars.count
    }

    private static func starts(_ token: [Unicode.Scalar], _ at: Int, _ chars: [Unicode.Scalar]) -> Bool {
        guard at + token.count <= chars.count else { return false }
        return token.indices.allSatisfy { chars[at + $0] == token[$0] }
    }

    private static func end(of token: [Unicode.Scalar], from start: Int, in chars: [Unicode.Scalar]) -> Int {
        var at = start
        while at < chars.count {
            if starts(token, at, chars) { return at + token.count }
            at += 1
        }
        return chars.count
    }
}
