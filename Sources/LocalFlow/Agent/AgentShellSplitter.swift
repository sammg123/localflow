import Foundation

/// Walks the text once. Mutable by nature; it lives only inside `AgentShell.parse`.
struct AgentShellSplitter {
    typealias Scalar = Unicode.Scalar

    /// What the next word is for.
    private enum Next {
        case argument, write, skip, duplicate, input, hereString
        case heredoc(stripTabs: Bool)
    }

    /// Before a heredoc's lines are read, its command only knows which one it gets.
    private enum RawInput {
        case ready(AgentShell.Input)
        case heredoc(Int)
    }

    private struct RawCommand {
        let words: [String]
        let writes: [String]
        let inputs: [RawInput]
    }

    /// Deeper nesting than this is read as plain text; the policy asks about it anyway.
    static let maxDepth = 32
    /// Words after which `((` starts arithmetic rather than two subshells.
    private static let beforeArithmetic: Set<String> = ["for", "if", "while", "until", "!", "then", "do", "else", "elif",
                                                        "{", "time", "coproc"]

    let chars: [Scalar]
    var index = 0
    let depth: Int
    /// Stop at the `)` that closes a `$(` this splitter was started inside.
    let stopsAtClose: Bool
    private(set) var substitutions: [String] = []
    private var feeds: [String] = []
    private var unclear = false
    private var pipelines: [[RawCommand]] = []
    private var pipeline: [RawCommand] = []
    private var words: [String] = []
    private var writes: [String] = []
    private var inputs: [RawInput] = []
    private var word = ""
    private var inWord = false
    private var quoted = false
    private var next = Next.argument
    private var heredocs: [(delimiter: String, stripTabs: Bool, expands: Bool, number: Int)] = []
    private var heredocBodies: [String] = []
    private var parens = 0
    /// A `|` was the last thing: a newline or `(` doesn't end the pipeline yet.
    private var pipeOpen = false

    init(chars: [Scalar], index: Int = 0, depth: Int = 0, stopsAtClose: Bool = false) {
        self.chars = chars
        self.index = index
        self.depth = depth
        self.stopsAtClose = stopsAtClose
    }

    var parsed: AgentShell.Parsed {
        let resolve: (RawInput) -> AgentShell.Input = { input in
            switch input {
            case .ready(let ready): return ready
            case .heredoc(let number): return .text(number < heredocBodies.count ? heredocBodies[number] : "")
            }
        }
        let commands = pipelines.map { pipeline in
            pipeline.map { AgentShell.Command(words: $0.words, writes: $0.writes, inputs: $0.inputs.map(resolve)) }
        }
        return AgentShell.Parsed(pipelines: commands, substitutions: substitutions, feeds: feeds, unclear: unclear)
    }

    func peek(_ offset: Int) -> Scalar? {
        index + offset < chars.count ? chars[index + offset] : nil
    }

    private var atCommandStart: Bool {
        !inWord && words.allSatisfy(Self.beforeArithmetic.contains)
    }

    mutating func run() {
        while index < chars.count {
            let c = chars[index]
            if c == ")" && stopsAtClose && parens == 0 { break }
            step(c)
        }
        endWord()
        endCommand(piped: false)
    }

    private mutating func step(_ c: Scalar) {
        switch c {
        case "\\":
            if let escaped = peek(1), escaped != "\n" { word.unicodeScalars.append(escaped) }
            inWord = true
            quoted = true
            index += 2
        case "'":
            index += 1
            while index < chars.count, chars[index] != "'" { word.unicodeScalars.append(chars[index]); index += 1 }
            index += 1
            inWord = true
            quoted = true
        case "$" where peek(1) == "'":
            index += 2
            word += readANSIC()
            inWord = true
            quoted = true
        case "$" where peek(1) == "\"", "\"":
            index += c == "$" ? 2 : 1
            readDoubleQuoted(stopsAtQuote: true)
            inWord = true
            quoted = true
        default:
            substitutionOrRest(c)
        }
    }

    private mutating func substitutionOrRest(_ c: Scalar) {
        switch c {
        case "`":
            word += "`" + readBackticks() + "`"
            inWord = true
        case "$" where peek(1) == "(" && peek(2) == "(":
            index += 3
            if let end = arithmeticEnd(open: "(", close: ")", double: true) {
                word += "$((" + readArithmetic(to: end, closingLength: 2) + "))"
            } else {
                index -= 1 // a command substitution that starts with a subshell
                word += "$(" + readBalanced() + ")"
            }
            inWord = true
        case "$" where peek(1) == "[":
            index += 2
            let end = arithmeticEnd(open: "[", close: "]", double: false)
            word += "$[" + (end.map { readArithmetic(to: $0, closingLength: 1) + "]" } ?? "")
            inWord = true
        case "$" where peek(1) == "(", "<" where peek(1) == "(", ">" where peek(1) == "(":
            index += 2
            let body = readBalanced()
            if c == ">" { feeds.append(body) }
            word += String(Character(c)) + "(" + body + ")"
            inWord = true
        case "(" where inWord && word.hasSuffix("=") && AgentCommandWords.isAssignment(word):
            index += 1
            word += "(" + readArray() + ")"
        case "(" where peek(1) == "(" && atCommandStart:
            index += 2
            if let end = arithmeticEnd(open: "(", close: ")", double: true) {
                _ = readArithmetic(to: end, closingLength: 2)
            } else {
                index -= 2
                operatorOrLetter(c) // two subshells after all, as the shell would read it
            }
        case "#" where !inWord:
            while index < chars.count, chars[index] != "\n" { index += 1 }
        case " ", "\t":
            endWord()
            index += 1
        case "\n":
            endWord()
            if !(pipeOpen && words.isEmpty) { endCommand(piped: false) }
            index += 1
            readHeredocBodies()
        default:
            operatorOrLetter(c)
        }
    }

    private mutating func operatorOrLetter(_ c: Scalar) {
        switch c {
        case ";":
            endWord()
            endCommand(piped: false)
            index += peek(1) == ";" ? 2 : 1
        case "&" where peek(1) == ">":
            endWord()
            index += peek(2) == ">" ? 3 : 2
            next = .write
        case "&":
            endWord()
            endCommand(piped: false)
            index += peek(1) == "&" ? 2 : 1
        case "|":
            endWord()
            let isOr = peek(1) == "|"
            endCommand(piped: !isOr)
            index += isOr || peek(1) == "&" ? 2 : 1
        case "(", ")":
            // Outside `f()`, a `(` in or after a word is a syntax error to bash and a glob
            // (with qualifiers that can run code) to zsh.
            if c == "(", peek(1) != ")", inWord || !words.allSatisfy(Self.beforeArithmetic.contains) { unclear = true }
            endWord()
            parens += c == "(" ? 1 : -1
            // `| (bash)`: the subshell still reads the pipe.
            if !(c == "(" && pipeOpen && words.isEmpty) { endCommand(piped: false) }
            index += 1
        case "<", ">":
            redirect(c)
        default:
            word.unicodeScalars.append(c)
            inWord = true
            index += 1
        }
    }

    /// `>`, `>>`, `>|`, `<>` write to the next word; `<` reads it; `<<<` feeds it as text;
    /// `<&`/`>&2` copy another descriptor; `<<` starts a heredoc. A number just before is the fd.
    private mutating func redirect(_ c: Scalar) {
        if inWord, !quoted, !word.isEmpty, word.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }) {
            word = ""
            inWord = false
        } else {
            endWord()
        }
        let (second, third) = (peek(1) ?? " ", peek(2) ?? " ")
        switch (c, second, third) {
        case ("<", "<", "<"): index += 3; next = .hereString
        case ("<", "<", _):
            let strip = third == "-"
            index += strip ? 3 : 2
            next = .heredoc(stripTabs: strip)
        case ("<", "&", _): index += 2; next = .skip
        case ("<", ">", _): index += 2; next = .write
        case ("<", _, _): index += 1; next = .input
        case (">", ">", _), (">", "|", _): index += 2; next = .write
        case (">", "&", _): index += 2; next = .duplicate
        default: index += 1; next = .write
        }
    }

    private mutating func endWord() {
        guard inWord else { return }
        switch next {
        case .argument:
            words.append(word)
            pipeOpen = false
        case .write: writes.append(word)
        case .skip: break
        case .duplicate: if !(word.allSatisfy(\.isNumber) || word == "-") { writes.append(word) }
        case .input: inputs.append(.ready(.file(word)))
        case .hereString: inputs.append(.ready(.text(word)))
        case .heredoc(let strip):
            let number = heredocBodies.count + heredocs.count
            heredocs.append((word, strip, !quoted, number))
            inputs.append(.heredoc(number))
        }
        next = .argument
        word = ""
        inWord = false
        quoted = false
    }

    private mutating func endCommand(piped: Bool) {
        if !words.isEmpty || !writes.isEmpty || !inputs.isEmpty {
            pipeline.append(RawCommand(words: words, writes: writes, inputs: inputs))
        }
        words = []
        writes = []
        inputs = []
        pipeOpen = piped && !pipeline.isEmpty
        guard !piped else { return }
        if !pipeline.isEmpty { pipelines.append(pipeline) }
        pipeline = []
    }

    /// Inside "…": backslash only escapes $ ` " \, and $(…) and backticks still run.
    mutating func readDoubleQuoted(stopsAtQuote: Bool) {
        while index < chars.count {
            let c = chars[index]
            if c == "\"" && stopsAtQuote {
                index += 1
                return
            }
            if c == "\\", let escaped = peek(1) {
                if "$`\"\\".unicodeScalars.contains(escaped) {
                    word.unicodeScalars.append(escaped)
                } else if escaped != "\n" {
                    word.unicodeScalars.append(contentsOf: [c, escaped])
                }
                index += 2
            } else if c == "$", peek(1) == "(", peek(2) != "(" {
                index += 2
                word += "$(" + readBalanced() + ")"
            } else if c == "`" {
                word += "`" + readBackticks() + "`"
            } else {
                word.unicodeScalars.append(c)
                index += 1
            }
        }
    }

    /// Where arithmetic starting at `index` closes (`))` or `]`), or nil when it isn't
    /// arithmetic after all. Inside it, `<<` is a shift, not a heredoc.
    private func arithmeticEnd(open: Scalar, close: Scalar, double: Bool) -> Int? {
        var depth = 0
        var at = index
        while at < chars.count {
            if chars[at] == open {
                depth += 1
            } else if chars[at] == close {
                if depth > 0 {
                    depth -= 1
                } else {
                    return !double ? at : (at + 1 < chars.count && chars[at + 1] == close ? at : nil)
                }
            }
            at += 1
        }
        return nil
    }

    /// Arithmetic up to `end`, keeping any `$(…)` or backticks inside as substitutions.
    private mutating func readArithmetic(to end: Int, closingLength: Int) -> String {
        let body = Array(chars[index..<end])
        var text = AgentShellSplitter(chars: body, depth: depth + 1)
        text.readDoubleQuoted(stopsAtQuote: false)
        substitutions += text.substitutions
        index = end + closingLength
        return String(String.UnicodeScalarView(body))
    }

    /// The text up to the next unescaped backtick, kept as a substitution.
    private mutating func readBackticks() -> String {
        index += 1
        var body = String.UnicodeScalarView()
        while index < chars.count, chars[index] != "`" {
            if chars[index] == "\\", let escaped = peek(1) {
                body.append(escaped)
                index += 2
            } else {
                body.append(chars[index])
                index += 1
            }
        }
        index += 1
        let text = String(body)
        substitutions.append(text)
        return text
    }

    /// The text up to the `)` that closes this `(`, found by splitting it the same way,
    /// so quotes and heredocs inside can't fool it. Kept as a substitution.
    private mutating func readBalanced() -> String {
        let start = index
        let end: Int
        if depth < Self.maxDepth {
            var inner = AgentShellSplitter(chars: chars, index: start, depth: depth + 1, stopsAtClose: true)
            inner.run()
            end = min(inner.index, chars.count)
        } else {
            end = chars.count
        }
        let body = String(String.UnicodeScalarView(chars[min(start, end)..<end]))
        index = min(end + 1, chars.count)
        substitutions.append(body)
        return body
    }

    /// `name=(…)`: the array's words aren't commands, but `$(…)` and backticks in them run.
    private mutating func readArray() -> String {
        let body = readBalanced()
        substitutions.removeLast()
        var text = AgentShellSplitter(chars: Array(body.unicodeScalars), depth: depth + 1)
        text.readDoubleQuoted(stopsAtQuote: false)
        substitutions += text.substitutions
        return body
    }

    /// After a line with `<<WORD`, the lines up to WORD are text, not commands. Unless
    /// WORD was quoted, `$(…)` and backticks in them still run.
    private mutating func readHeredocBodies() {
        for doc in heredocs {
            var body: [Scalar] = []
            while index < chars.count {
                let end = chars[index...].firstIndex(of: "\n") ?? chars.count
                let line = Array(chars[index..<end])
                index = min(end + 1, chars.count)
                let bare = doc.stripTabs ? Array(line.drop { $0 == "\t" }) : line
                if String(String.UnicodeScalarView(bare)) == doc.delimiter { break }
                body += line + ["\n"]
            }
            heredocBodies.append(String(String.UnicodeScalarView(body)))
            if doc.expands {
                var text = AgentShellSplitter(chars: body, depth: depth + 1)
                text.readDoubleQuoted(stopsAtQuote: false)
                substitutions += text.substitutions
            }
        }
        heredocs = []
    }
}
