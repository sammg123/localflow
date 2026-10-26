import Foundation

/// Splits a model answer into prose and fenced code so code can be shown monospaced.
/// Works on partial text mid-stream: an unclosed fence is treated as code so far.
enum AnswerFormatter {
    enum Segment: Equatable {
        case prose(String)
        case code(String)
    }

    static func segments(_ text: String) -> [Segment] {
        var segments: [Segment] = []
        var current: [Substring] = []
        var inCode = false

        func flush() {
            let joined = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            current = []
            guard !joined.isEmpty else { return }
            segments.append(inCode ? .code(joined) : .prose(joined))
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                flush()
                inCode.toggle()
            } else {
                current.append(line)
            }
        }
        flush()
        return segments
    }
}
