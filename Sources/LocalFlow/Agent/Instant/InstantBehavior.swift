import Foundation

/// Finds the behavior-shaped pieces of code in an edit's text: what InstantUIOnly
/// compares between the old and new text.
enum InstantBehavior {
    struct Piece: Equatable {
        let kind: String
        /// The piece with whitespace taken out, so reindenting it doesn't count as a change.
        let text: String
    }

    private struct Pattern {
        let kind: String
        let regex: NSRegularExpression
        /// A `{ … }` after the value belongs to it (SwiftUI modifiers like `.onTapGesture`).
        let takesClosure: Bool
        let isDeclaration: Bool

        init(_ kind: String, _ pattern: String, closure: Bool = false, declaration: Bool = false) {
            self.kind = kind
            // The patterns are fixed; a typo is a programming error caught by the tests.
            regex = try! NSRegularExpression(pattern: pattern)
            takesClosure = closure
            isDeclaration = declaration
        }
    }

    /// The longest piece kept; anything longer is cut, the same way on both sides.
    private static let pieceLimit = 2_000
    private static let handler = "an event handler"
    private static let action = "an action"
    private static let work = "network, storage or background work"
    private static let code = "code that runs other code"
    /// Node modules that reach the disk, network or other programs.
    private static let nodeModules = "(?:node:)?(?:child_process|fs|fs/promises|net|http|https|os|vm|worker_threads|dgram|cluster)"

    private static let patterns: [Pattern] = [
        // JSX, HTML, Vue and Svelte handlers: onClick={…}, onclick="…", @click="…", v-on:…, on:click
        Pattern(handler, #"\bon[A-Z][A-Za-z]*\s*=(?!=)"#),
        Pattern(handler, #"\bon(?:click|dblclick|submit|change|input|keydown|keyup|keypress|load|blur|focus|mouse[a-z]*|touch[a-z]*|pointer[a-z]*)\s*=(?!=)"#),
        Pattern(handler, #"(?<![\w@])@[a-z][\w.:-]*\s*=(?!=)"#),
        Pattern(handler, #"\bv-on:[\w.:-]+\s*="#),
        Pattern(handler, #"\bon:[a-z]+(?:\|[\w|]+)?\s*="#),
        // SwiftUI and UIKit actions, gestures and tasks
        Pattern(action, #"(?<=[(,{])\s*action\s*:"#),
        Pattern(action, #"\.on(?:TapGesture|LongPressGesture|Submit|Appear|Disappear|Change|Receive|Delete|Move|Drop|Drag|OpenURL|Commit|KeyPress)\b"#, closure: true),
        Pattern(action, #"\.(?:task|refreshable|swipeActions|contextMenu|gesture|simultaneousGesture|highPriorityGesture)\s*(?=[({])"#, closure: true),
        Pattern(action, #"\b(?:addTarget|addEventListener|addGestureRecognizer)\s*(?=\()"#),
        // Network, storage, effects and background work
        Pattern(work, #"\b(?:fetch|axios(?:\.\w+)?|XMLHttpRequest|URLRequest|WebSocket|EventSource|setTimeout|setInterval|useEffect|useLayoutEffect|useSWR|useQuery|useMutation|dispatch|navigate|router\.(?:push|replace))\s*(?=[({])"#),
        Pattern(work, #"\bTask(?:\.detached)?\s*(?=\{)"#),
        Pattern(work, #"\$\.ajax\b"#),
        Pattern(work, #"\b(?:localStorage|sessionStorage|indexedDB|UserDefaults|AppStorage|SceneStorage|NSUbiquitousKeyValueStore|FileManager|URLSession|NSPersistentContainer|modelContext)\b"#),
        Pattern(work, #"\bawait\s+(?=[\w.$]+\s*\()"#),
        Pattern(work, #"\.then\s*(?=\()"#),
        Pattern(work, #"\b(?:sendBeacon|document\.cookie|window\.location|location\.(?:href|assign|replace))\b"#),
        // Running other code, or HTML that isn't escaped
        Pattern(code, #"\beval(?=\()|\bnew\s+Function(?=\s*\()|\bimport(?=\s*\()"#),
        Pattern(code, #"\brequire\s*(?=\(\s*['"]"# + nodeModules + #"['"])|\bfrom\s+(?=['"]"# + nodeModules + #"['"])"#),
        Pattern(code, #"\b(?:child_process|execSync|execFileSync|spawnSync|subprocess|os\.system|os\.popen|NSTask|NSAppleScript)\b"#),
        Pattern(code, #"\bProcess\s*(?=\(\s*\))"#),
        Pattern(code, #"\bdangerouslySetInnerHTML\s*=|\binnerHTML\s*=(?!=)|<script\b"#),
        // New functions, for edits
        Pattern("a new function", #"\b(?:func|function|def)\s+[A-Za-z_$][\w$]*\s*(?=[(<])"#, declaration: true),
    ]

    static func pieces(in text: String, declarations: Bool) -> [Piece] {
        let scalars = Array(text.unicodeScalars)
        let whole = NSRange(text.startIndex..., in: text)
        return patterns.filter { declarations || !$0.isDeclaration }.flatMap { pattern in
            pattern.regex.matches(in: text, range: whole).compactMap { match -> Piece? in
                guard let range = Range(match.range, in: text) else { return nil }
                let start = text.unicodeScalars.distance(from: text.unicodeScalars.startIndex, to: range.lowerBound)
                let end = start + text[range].unicodeScalars.count
                let tailEnd = value(after: end, in: scalars, pattern: pattern)
                let piece = String(String.UnicodeScalarView(scalars[start..<min(tailEnd, start + pieceLimit)]))
                return Piece(kind: pattern.kind, text: piece.filter { !$0.isWhitespace })
            }
        }
    }

    /// Where the value after a match ends: a name like `save` or `api.load`, then one
    /// bracketed or quoted group, then for closures a `{ … }`. Declarations take only
    /// their parameters, so restyling a function's body doesn't read as a new function.
    private static func value(after index: Int, in chars: [Unicode.Scalar], pattern: Pattern) -> Int {
        var at = skipSpaces(from: index, in: chars)
        if pattern.isDeclaration {
            return at < chars.count && chars[at] == "(" ? group(at, in: chars) : index
        }
        while at < chars.count, isNameScalar(chars[at]) { at += 1 }
        let afterName = at
        at = skipSpaces(from: at, in: chars)
        var end = at < chars.count && "{([\"'`".unicodeScalars.contains(chars[at]) ? group(at, in: chars) : afterName
        if pattern.takesClosure {
            let next = skipSpaces(from: end, in: chars)
            if next < chars.count, chars[next] == "{" { end = group(next, in: chars) }
        }
        return end
    }

    private static func isNameScalar(_ c: Unicode.Scalar) -> Bool {
        CharacterSet.alphanumerics.contains(c) || c == "_" || c == "." || c == "$"
    }

    private static func skipSpaces(from index: Int, in chars: [Unicode.Scalar]) -> Int {
        var at = index
        while at < chars.count, CharacterSet.whitespacesAndNewlines.contains(chars[at]) { at += 1 }
        return at
    }

    /// Just past the bracket or quote that closes the one at `start`, skipping strings
    /// inside; the end of the text when it never closes.
    private static func group(_ start: Int, in chars: [Unicode.Scalar]) -> Int {
        let quotes: Set<Unicode.Scalar> = ["\"", "'", "`"]
        if quotes.contains(chars[start]) { return quoted(start, in: chars) }
        var depth = 0
        var at = start
        while at < chars.count {
            let c = chars[at]
            if quotes.contains(c) {
                at = quoted(at, in: chars)
                continue
            }
            if "{([".unicodeScalars.contains(c) { depth += 1 }
            if "})]".unicodeScalars.contains(c) {
                depth -= 1
                if depth == 0 { return at + 1 }
            }
            at += 1
        }
        return chars.count
    }

    /// Just past the quote that closes the one at `start`. Plain quotes end at a line's
    /// end too, so an apostrophe in text can't swallow the rest.
    private static func quoted(_ start: Int, in chars: [Unicode.Scalar]) -> Int {
        let quote = chars[start]
        var at = start + 1
        while at < chars.count {
            let c = chars[at]
            if c == "\\" {
                at += 2
                continue
            }
            if c == quote { return at + 1 }
            if c == "\n", quote != "`" { return at }
            at += 1
        }
        return chars.count
    }
}
