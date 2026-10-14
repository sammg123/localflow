import AppKit
import Foundation

/// Category of the app the text will land in, used for tone matching.
enum AppCategory {
    case messaging
    case email
    case code
    case other

    static func forFrontmostApp() -> (category: AppCategory, appName: String) {
        guard let app = NSWorkspace.shared.frontmostApplication else { return (.other, "unknown") }
        let bundleID = app.bundleIdentifier?.lowercased() ?? ""
        let name = app.localizedName ?? "unknown"

        let messaging = ["com.apple.mobilesms", "com.tinyspeck.slackmacgap", "com.hnc.discord",
                         "net.whatsapp.whatsapp", "ru.keepcoder.telegram", "org.telegram",
                         "com.facebook.archon", "org.signal"]
        let email = ["com.apple.mail", "com.microsoft.outlook", "com.superhuman", "it.bloop.airmail"]
        let code = ["com.microsoft.vscode", "com.todesktop", "com.exafunction.windsurf",
                    "com.apple.terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
                    "dev.warp.warp", "com.apple.dt.xcode", "dev.zed.zed", "com.jetbrains"]

        if messaging.contains(where: { bundleID.hasPrefix($0) }) { return (.messaging, name) }
        if email.contains(where: { bundleID.hasPrefix($0) }) { return (.email, name) }
        if code.contains(where: { bundleID.hasPrefix($0) }) { return (.code, name) }
        return (.other, name)
    }

    var toneHint: String {
        switch self {
        case .messaging:
            return "This is a casual chat message. Keep it conversational and drop the trailing period if it is short."
        case .email:
            return "This is an email. Use clear, complete sentences with normal punctuation."
        case .code:
            return "This will be typed into a code editor or terminal. Keep it plain text, no markdown, preserve technical terms, file names, and casing exactly as spoken."
        case .other:
            return "Use normal, clear punctuation."
        }
    }
}

/// A stage that turns a raw ASR transcript into polished text.
protocol Polisher {
    func polish(_ transcript: String, category: AppCategory, dictionary: [String]) async -> String
}

/// Deterministic cleanup that always runs, LLM or not:
/// residual filler words, spoken commands, user replacements, messaging-tone trailing period.
struct RulesPolisher {
    /// Parakeet/Whisper already punctuate and mostly drop fillers; this catches stragglers.
    /// Deliberately narrow: no "mm" (millimeters), no "like" (too ambiguous), lowercase /
    /// sentence-case only (UM, ERM, UMM are acronyms/tickers), and "uh huh"/"uh-huh" is an
    /// affirmation, not a filler. Consumes a full ellipsis so "Umm... maybe" -> "maybe".
    private static let fillerPattern = try! NSRegularExpression(
        pattern: #"(?:^|(?<=[\s,.!?]))(?:[Uu]m+|[Uu]h+|[Ee]rm+)\b(?![ -]?[Hh]uh\b)(?:\.{1,3}|,)?\s*"#
    )

    func apply(_ text: String, category: AppCategory, replacements: [String: String],
               spokenCommands: Bool, toneMatching: Bool) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return result }

        // Remember whether a filler sat at the very start — recapitalization below is
        // only justified when removing one actually exposed a lowercase first word.
        let hadLeadingFiller = Self.fillerPattern.firstMatch(
            in: result, range: NSRange(result.startIndex..., in: result)
        )?.range.location == 0

        result = Self.fillerPattern.stringByReplacingMatches(
            in: result, range: NSRange(result.startIndex..., in: result), withTemplate: ""
        )

        // Spoken layout commands — opt-in, and only when the phrase stands alone as its
        // own clause ("…done. New paragraph. Next…"), so "a new line of code" survives.
        if spokenCommands {
            result = result.replacingOccurrences(
                of: #"(?i)(?:^|(?<=[.!?,;:]))\s*new paragraph\s*(?:[.!?,;:]\s*|$)"#,
                with: "\n\n", options: .regularExpression)
            result = result.replacingOccurrences(
                of: #"(?i)(?:^|(?<=[.!?,;:]))\s*new line\s*(?:[.!?,;:]\s*|$)"#,
                with: "\n", options: .regularExpression)
        }

        // User-defined replacements, whole-word, case-insensitive.
        // The right side must be literal text, not a regex template ("$" and "\" are data).
        for (wrong, right) in replacements {
            guard !wrong.isEmpty else { continue }
            let pattern = "(?i)\\b\(NSRegularExpression.escapedPattern(for: wrong))\\b"
            result = result.replacingOccurrences(
                of: pattern,
                with: NSRegularExpression.escapedTemplate(for: right),
                options: .regularExpression)
        }

        // Inverse text normalization: spelled-out emails, domains, digit sequences, and
        // technical symbols become their typed form. Ambiguous cases (bare number words,
        // punctuation-symbols like "question mark") are left for the LLM pass.
        result = ITN.apply(result)

        // Collapse doubled spaces left by removals; fix space-before-punctuation
        // (spaces/tabs only — never eat the newlines spoken commands just inserted).
        result = result.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"[ \t]+([,.!?;:])"#, with: "$1", options: .regularExpression)
        // Filler removal can strand punctuation: "report, um." -> "report," -> "report."
        result = result.replacingOccurrences(of: #",[ \t]*([.!?])"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #",[ \t]*$"#, with: ".", options: .regularExpression)
        // Trim spaces/tabs only: a dictation that IS a command ("new line") must survive
        // as "\n", not be trimmed to emptiness and reported as "didn't catch anything".
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))

        // Recapitalize only when a leading filler removal exposed a lowercase start, and
        // never in code contexts ("git status") or on mixed-case terms ("iPhone", "eBay").
        if hadLeadingFiller, category != .code, let first = result.first, first.isLowercase {
            let firstWord = result.prefix { !$0.isWhitespace }
            if firstWord.allSatisfy({ !$0.isUppercase }) {
                result = result.prefix(1).uppercased() + result.dropFirst()
            }
        }

        if toneMatching {
            result = Self.applyTone(to: result, category: category, enabled: true)
        }
        return result
    }

    /// Wispr-style messaging tone: short messages lose the trailing period.
    /// Runs as the FINAL pass (after the LLM, which tends to re-add periods).
    static func applyTone(to text: String, category: AppCategory, enabled: Bool) -> String {
        guard enabled, category == .messaging else { return text }
        let sentenceCount = text.components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        if sentenceCount <= 2, text.hasSuffix("."), !text.hasSuffix("..") {
            return String(text.dropLast())
        }
        return text
    }
}
