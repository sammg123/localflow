import Foundation

/// The text side of the memory files: starter templates, checking a note, putting it
/// under the right heading, and cutting a file that's grown too long. No disk access.
extension FlowMemory {
    /// Most of a file that's read, and the most a note may grow a file to.
    static let maxFileBytes = 12 * 1024
    static let maxNoteLength = 300
    /// Ends a file that was cut on reading.
    static let cutNote = "[LocalFlow cut this file here: the rest is past the \(maxFileBytes / 1024) KB it reads.]\n"

    static let instructionsTemplate = """
    # LocalFlow instructions

    <!-- Standing instructions for LocalFlow's Ask and agent, read before every answer: how you want \
    answers, conventions, and "always", "never" or "from now on" rules. One line each. -->

    """

    static let memoryTemplate = """
    # LocalFlow memory

    <!-- What LocalFlow has learned, read before every answer. One line per entry, never a secret. -->

    ## Projects

    <!-- One line per project: Name | folder: ~/path | repo: owner/name | domains: app.example.com | \
    cues: logo, app or window names, page titles | design: path/to/design-profile.md -->

    ## Notes

    <!-- Other durable facts. -->

    """

    /// Text a note can't hold: it would start a heading, or pass for the start or end
    /// of a file, a comment or a tag where the files are shown to a model.
    static let markup = ["===", "<!--", "-->", "<remember", "</remember"]

    /// The note as it's stored: trimmed, one line, short, no bullet of its own, no
    /// markup and no secret.
    static func validated(_ note: String) throws(Refusal) -> String {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isNewline) else { throw .multiline }
        let entry = withoutBullet(trimmed)
        guard !entry.isEmpty else { throw .empty }
        guard entry.count <= maxNoteLength else { throw .tooLong }
        let lower = entry.lowercased()
        guard !entry.hasPrefix("#"), !markup.contains(where: lower.contains) else { throw .markup }
        guard !SecretText.looksLikeSecret(entry) else { throw .secret }
        return entry
    }

    /// Every line of a file as an entry: trimmed, bullet dropped.
    static func entries(in text: String) -> Set<String> {
        Set(text.split(whereSeparator: \.isNewline).map { withoutBullet(trimmed($0)) })
    }

    /// `text` with `entry` added as a bullet: at the end of its section in flow-memory.md
    /// (the section added at the end if its heading is gone), or at the end of
    /// localflow.md. A project already listed by the same name gets its line replaced.
    static func adding(_ entry: String, to text: String, section: Section) -> String {
        let line = "- " + entry
        guard let heading = section.heading else { return appending(line, to: text, gap: "\n") }
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { trimmed($0).lowercased() == heading.lowercased() })
        else { return appending(heading + "\n\n" + line, to: text, gap: "\n\n") }
        let end = lines[(start + 1)...].firstIndex(where: isMajorHeading) ?? lines.count
        if section == .projects, let name = projectName(entry),
           let old = (start + 1 ..< end).first(where: { projectName(withoutBullet(trimmed(lines[$0]))) == name }) {
            return joined(lines[..<old] + [line] + lines[(old + 1)...])
        }
        let last = (start ..< end).last { !trimmed(lines[$0]).isEmpty } ?? start
        let after = last + 1
        let spacer = after < lines.count && isMajorHeading(lines[after]) ? [""] : []
        return joined(lines[..<after] + [line] + spacer + lines[after...])
    }

    /// `text` cut to `limit` bytes at the last line break (or character, if there's no
    /// line break), with a note saying it was cut. Text within the limit is unchanged.
    static func capped(_ text: String, limit: Int = maxFileBytes) -> String {
        let bytes = Array(text.utf8)
        guard bytes.count > limit else { return text }
        let newline = UInt8(ascii: "\n")
        let end = bytes[..<limit].lastIndex(of: newline).map { $0 + 1 } ?? characterStart(in: bytes, atOrBefore: limit)
        let kept = String(decoding: bytes[..<end], as: UTF8.self)
        return kept + (kept.isEmpty || kept.hasSuffix("\n") ? "" : "\n") + cutNote
    }

    /// The name a project line starts with, before its first "|", lowercased.
    static func projectName(_ entry: String) -> String? {
        guard let bar = entry.firstIndex(of: "|") else { return nil }
        let name = entry[..<bar].trimmingCharacters(in: .whitespaces).lowercased()
        return name.isEmpty ? nil : name
    }

    private static func withoutBullet(_ line: String) -> String {
        guard let first = line.first, "-*•".contains(first), line.dropFirst().first?.isWhitespace ?? true else { return line }
        return line.dropFirst().trimmingCharacters(in: .whitespaces)
    }

    /// A "#" or "##" heading, which ends a section. Deeper headings stay inside it.
    private static func isMajorHeading(_ line: String) -> Bool {
        let text = trimmed(line)
        return text.hasPrefix("# ") || text.hasPrefix("## ")
    }

    /// Without spaces, or the carriage return a file saved with Windows line endings has.
    private static func trimmed<S: StringProtocol>(_ line: S) -> String {
        line.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func appending(_ block: String, to text: String, gap: String) -> String {
        let body = String(text.reversed().drop(while: \.isWhitespace).reversed())
        return body.isEmpty ? block + "\n" : body + gap + block + "\n"
    }

    private static func joined<S: Sequence>(_ lines: S) -> String where S.Element == String {
        let text = lines.joined(separator: "\n")
        return text.hasSuffix("\n") ? text : text + "\n"
    }

    /// The start of the UTF-8 character at or before `index`, so a cut never splits one.
    private static func characterStart(in bytes: [UInt8], atOrBefore index: Int) -> Int {
        let isContinuation = { (byte: UInt8) in byte & 0xC0 == 0x80 }
        return stride(from: index, through: 0, by: -1).first { $0 == bytes.count || !isContinuation(bytes[$0]) } ?? 0
    }
}

extension FlowMemory.Section {
    /// Its heading in flow-memory.md; instructions have the whole of localflow.md.
    var heading: String? {
        switch self {
        case .projects: return "## Projects"
        case .notes: return "## Notes"
        case .instructions: return nil
        }
    }
}
