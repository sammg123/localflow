import Foundation

/// A shell command line split the way the shell would run it, just far enough to see
/// which commands it runs, what it feeds them and which files it writes. Nothing is
/// run or expanded. It reads Unicode scalars, as the shell reads bytes, so a combining
/// mark can't turn a quote or `;` into something else.
enum AgentShell {
    /// One simple command: its words with the quotes taken off, the files its output is
    /// sent to (`>`, `>>`, `&>`), and what it reads as input.
    struct Command: Equatable {
        let words: [String]
        let writes: [String]
        let inputs: [Input]
    }

    enum Input: Equatable {
        /// `< file`, including `< <(…)`.
        case file(String)
        /// A here-string (`<<<`) or a heredoc's lines.
        case text(String)
    }

    struct Parsed: Equatable {
        /// Commands joined by pipes, in order; each pipeline is one list.
        let pipelines: [[Command]]
        /// Text the shell runs first and puts in place: `$(…)`, backticks, `<(…)`.
        let substitutions: [String]
        /// The bodies of `>(…)`, which read what the command writes.
        let feeds: [String]
        /// Something the shell (zsh above all) reads in a way this can't follow, such as a
        /// glob qualifier `*(e:…:)` or a `(` after a command's words.
        let unclear: Bool
    }

    static func parse(_ text: String) -> Parsed {
        var splitter = AgentShellSplitter(chars: Array(text.unicodeScalars))
        splitter.run()
        return splitter.parsed
    }

    /// Characters a word can show without quotes.
    private static let plain = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./:=@%+,~^"))

    /// A word as the shell would need it typed: as is when it's plain, else in single quotes.
    static func quote(_ word: String) -> String {
        guard word.isEmpty || !word.unicodeScalars.allSatisfy(plain.contains) else { return word }
        return "'" + word.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    static func display(_ words: [String]) -> String {
        words.map(quote).joined(separator: " ")
    }
}
