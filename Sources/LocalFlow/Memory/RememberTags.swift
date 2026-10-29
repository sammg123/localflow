import Foundation

/// How Ask adds to memory: its engines can't write files, so an answer ends with
/// <remember section="projects|notes|instructions">one line</remember> tags. They come
/// out before the user sees the answer, also while it's still streaming in.
enum RememberTags {
    typealias Note = (section: FlowMemory.Section, text: String)

    /// Most notes kept from one answer, so a page full of planted tags can't fill memory.
    static let maxNotesPerAnswer = 3

    private static let opening = "<remember"
    private static let tag = try! NSRegularExpression( // fixed pattern, checked by the tests
        pattern: #"<remember\b([^>]*)>(.*?)</remember\s*>"#, options: [.caseInsensitive, .dotMatchesLineSeparators])
    private static let sectionAttribute = try! NSRegularExpression(
        pattern: #"section\s*=\s*["']?([A-Za-z]+)"#, options: [.caseInsensitive])
    /// Words that show the user is stating a lasting rule in their own question.
    private static let ruleWords = try! NSRegularExpression(
        pattern: #"\b(always|never|from now on|going forward|in (the )?future|every time|whenever|remember|prefer)\b"#,
        options: [.caseInsensitive])

    /// The answer as the user sees it, and the notes its tags carry. Every complete tag
    /// is hidden, but only those at the very end count. A tag with an unknown section is
    /// ignored. An unclosed tag at the end, or the start of one, is hidden too. Text with
    /// no tags comes back exactly as it was.
    static func split(_ text: String) -> (visible: String, notes: [Note]) {
        guard text.contains("<") else { return (text, []) }
        let whole = text as NSString
        let matches = tag.matches(in: text, range: NSRange(location: 0, length: whole.length))
        let bounds = [0] + matches.flatMap { [$0.range.location, NSMaxRange($0.range)] } + [whole.length]
        let pieces = stride(from: 0, to: bounds.count, by: 2)
            .map { whole.substring(with: NSRange(location: bounds[$0], length: bounds[$0 + 1] - bounds[$0])) }
        let kept = pieces.joined()
        let shown = withoutUnfinishedTag(kept)
        guard !matches.isEmpty || shown != kept else { return (text, []) }
        let tail = Array(pieces.dropLast()) + [withoutUnfinishedTag(pieces[pieces.count - 1])]
        let notes = matches.indices
            .filter { index in tail[(index + 1)...].allSatisfy { $0.allSatisfy(\.isWhitespace) } }
            .compactMap { note(in: matches[$0], of: whole) }
        return (String(shown.reversed().drop(while: \.isWhitespace).reversed()), notes)
    }

    /// The notes worth saving from one answer: the first few, and standing instructions
    /// only when the user's own question states a lasting rule, so text on the screen
    /// can never set one.
    static func allowed(_ notes: [Note], question: String) -> [Note] {
        let statesRule = ruleWords.firstMatch(in: question, range: NSRange(question.startIndex..., in: question)) != nil
        return Array(notes.filter { $0.section != .instructions || statesRule }.prefix(maxNotesPerAnswer))
    }

    private static func note(in match: NSTextCheckingResult, of text: NSString) -> Note? {
        let attributes = text.substring(with: match.range(at: 1)) as NSString
        let body = text.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let found = sectionAttribute.firstMatch(in: attributes as String, range: NSRange(location: 0, length: attributes.length)),
              let section = FlowMemory.Section(rawValue: attributes.substring(with: found.range(at: 1)).lowercased()),
              body.range(of: opening, options: .caseInsensitive) == nil
        else { return nil }
        return (section, body)
    }

    /// Cuts an unclosed tag and everything after it, or the start of "<remember" at the
    /// very end, since the rest may still be on its way.
    private static func withoutUnfinishedTag(_ text: String) -> String {
        if let open = text.range(of: opening, options: .caseInsensitive) {
            return String(text[..<open.lowerBound])
        }
        let partial = (1..<opening.count).reversed().lazy
            .compactMap { text.range(of: String(opening.prefix($0)), options: [.caseInsensitive, .anchored, .backwards]) }
            .first
        return partial.map { String(text[..<$0.lowerBound]) } ?? text
    }
}
