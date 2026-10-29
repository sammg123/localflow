import Foundation

/// Spots text that looks like a secret, so it's never written to LocalFlow's memory.
/// Errs toward refusing: a note wrongly refused costs little, a saved key a lot.
enum SecretText {
    /// Known key and token shapes, a private key's first line, sign-in details or a
    /// webhook in a web address, and a secret word followed by its value ("password:
    /// ...", "the token for prod is ...").
    private static let patterns: [NSRegularExpression] = [
        #"-----BEGIN [A-Z ]*PRIVATE KEY"#,
        #"\b(?:sk|pk|rk)_(?:live|test)_[A-Za-z0-9]{10,}"#,
        #"\bsk-[A-Za-z0-9_-]{20,}"#,
        #"\bgh[pousr]_[A-Za-z0-9]{20,}"#,
        #"\bgithub_pat_[A-Za-z0-9_]{20,}"#,
        #"\bglpat-[A-Za-z0-9_-]{20,}"#,
        #"\bxox[abposr]-[A-Za-z0-9-]{10,}"#,
        #"\bxapp-[A-Za-z0-9-]{10,}"#,
        #"\b(?:hf|shpat|shpss|shpca|whsec|npm)_[A-Za-z0-9]{16,}"#,
        #"\bdop_v1_[a-f0-9]{32,}"#,
        #"\bAKIA[0-9A-Z]{16}\b"#,
        #"\bAIza[0-9A-Za-z_-]{30,}"#,
        #"\bya29\.[A-Za-z0-9_-]{20,}"#,
        #"\bSG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}"#,
        #"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\."#,
        #"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]{16,}"#,
        #"://[^/\s:@]+:[^/\s@]+@"#,
        #"(?i)hooks\.slack\.com/services/|discord(?:app)?\.com/api/webhooks/"#,
        #"(?i)\b(?:password|passwd|passphrase|pwd|secret|token|api[ _-]?key|access[ _-]?key|secret[ _-]?key|"#
            + #"private[ _-]?key|client[ _-]?secret|auth[ _-]?token)s?\b[^|:=\n]{0,30}?(?:[:=]|\bis\b)\s*\S+"#,
    ].map { try! NSRegularExpression(pattern: $0) } // fixed patterns, checked by the tests

    /// A run this long of letters and digits (with both in it) is a key, not a word.
    static let longRunLength = 32
    private static let longRun = try! NSRegularExpression(pattern: "[A-Za-z0-9+=_-]{\(longRunLength),}")

    static func looksLikeSecret(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        if patterns.contains(where: { $0.firstMatch(in: text, range: range) != nil }) { return true }
        return longRun.matches(in: text, range: range).contains { isKeyLike((text as NSString).substring(with: $0.range)) }
    }

    /// Letters and digits, and either both cases or no word breaks: a hyphenated
    /// lowercase name ("my-project-2026-redesign") is a name, not a key.
    private static func isKeyLike(_ run: String) -> Bool {
        guard run.contains(where: \.isNumber), run.contains(where: \.isLetter) else { return false }
        let isMixedCase = run.contains(where: \.isUppercase) && run.contains(where: \.isLowercase)
        return isMixedCase || !run.contains(where: { $0 == "-" || $0 == "_" })
    }
}
