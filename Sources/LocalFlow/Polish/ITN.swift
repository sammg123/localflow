import Foundation

/// Deterministic inverse text normalization (ITN): turns spoken-form fragments the ASR
/// spells out ("two two one", "sam at gmail dot com", "underscore") into the way they are
/// conventionally typed ("221", "sam@gmail.com", "_").
///
/// Scope is deliberately the UNAMBIGUOUS cases only — emails, domains/URLs, spoken digit
/// sequences, and technical/programming symbols. Bare number words in prose ("two dogs")
/// and punctuation-symbols that collide with prose ("question mark", "dash", "quote") are
/// left for the context-aware LLM pass, which can tell "a dash of salt" from "foo dash bar".
/// This runs BEFORE the LLM and always (even with Apple Intelligence off).
enum ITN {
    // Single spoken digits only. Sequences ("two two one") are read digit-by-digit;
    // compound cardinals ("twenty four") are left for the LLM.
    private static let digitWord: [String: Character] = [
        "zero": "0", "oh": "0", "one": "1", "two": "2", "three": "3", "four": "4",
        "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9",
    ]

    private static let tlds: Set<String> = [
        "com", "net", "org", "io", "gov", "edu", "co", "dev", "app", "ai",
        "uk", "us", "ca", "me", "info", "biz", "xyz", "tech", "gg",
    ]

    // Technical symbols that essentially never appear as these words in prose.
    // Longest phrases first so "forward slash" wins over "slash", etc.
    private static let symbolPhrases: [(String, String)] = [
        ("open parenthesis", "("), ("close parenthesis", ")"),
        ("left parenthesis", "("), ("right parenthesis", ")"),
        ("open paren", "("), ("close paren", ")"),
        ("open bracket", "["), ("close bracket", "]"),
        ("left square bracket", "["), ("right square bracket", "]"),
        ("open brace", "{"), ("close brace", "}"),
        ("left curly brace", "{"), ("right curly brace", "}"),
        ("open curly brace", "{"), ("close curly brace", "}"),
        ("forward slash", "/"), ("back slash", "\\"), ("backslash", "\\"),
        ("vertical bar", "|"), ("pipe symbol", "|"),
        ("hash sign", "#"), ("hash tag", "#"), ("hashtag", "#"),
        ("pound sign", "#"), ("number sign", "#"),
        ("at sign", "@"), ("at symbol", "@"),
        ("plus sign", "+"), ("minus sign", "-"), ("equals sign", "="),
        ("equal sign", "="), ("percent sign", "%"), ("dollar sign", "$"),
        ("ampersand", "&"), ("asterisk", "*"), ("underscore", "_"),
        ("caret", "^"), ("tilde", "~"), ("slash", "/"),
    ]

    static func apply(_ input: String) -> String {
        var s = input
        s = normalizeEmails(s)
        s = normalizeDomains(s)
        s = normalizeDigitSequences(s)
        s = normalizePercent(s)
        s = normalizeSymbols(s)
        s = tidy(s)
        return s
    }

    /// True when the (already deterministically-normalized) text still contains spelled-out
    /// numbers or punctuation-symbol words that need the context-aware LLM to resolve.
    /// Used to bypass the word-count gate for short but ITN-relevant utterances.
    static func needsContextualNormalization(_ text: String) -> Bool {
        let numberWords = #"(?i)\b(zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|thousand|million|billion)\b"#
        let symbolWords = #"(?i)\b(question mark|exclamation (point|mark)|semicolon|quotation mark|open quote|close quote|ellipsis|em dash|en dash)\b"#
        return text.range(of: numberWords, options: .regularExpression) != nil
            || text.range(of: symbolWords, options: .regularExpression) != nil
    }

    // "sam at gmail dot com" -> "sam@gmail.com"
    private static func normalizeEmails(_ s: String) -> String {
        let tldAlt = tlds.joined(separator: "|")
        let pattern = #"\b([A-Za-z0-9][A-Za-z0-9._+-]*)\s+at\s+([A-Za-z0-9-]+(?:\s+dot\s+[A-Za-z0-9-]+)*\s+dot\s+(?:\#(tldAlt)))\b"#
        return replace(s, pattern) { m, str in
            let local = group(m, 1, str)
            let domain = group(m, 2, str)
                .replacingOccurrences(of: #"\s+dot\s+"#, with: ".", options: .regularExpression)
            return "\(local)@\(domain)"
        }
    }

    // "github dot com" -> "github.com" (only when the final label is a known TLD)
    private static func normalizeDomains(_ s: String) -> String {
        let tldAlt = tlds.joined(separator: "|")
        let pattern = #"\b([A-Za-z0-9-]+(?:\s+dot\s+[A-Za-z0-9-]+)*\s+dot\s+(?:\#(tldAlt)))\b"#
        return replace(s, pattern) { m, str in
            group(m, 1, str)
                .replacingOccurrences(of: #"\s+dot\s+"#, with: ".", options: .regularExpression)
        }
    }

    // Runs of >=2 spoken single digits (optionally with "point") -> concatenated digits.
    // "two two one" -> "221", "three point five" -> "3.5". A lone "two" is left alone.
    private static func normalizeDigitSequences(_ s: String) -> String {
        let tokens = tokenize(s)
        var out = ""
        var i = 0
        while i < tokens.count {
            let (text, isWord) = tokens[i]
            if isWord, digitWord[text.lowercased()] != nil {
                // Gather a maximal run of digit words / "point" separated by single spaces.
                var j = i
                var digitCount = 0
                while j < tokens.count {
                    let (t, w) = tokens[j]
                    if w, digitWord[t.lowercased()] != nil { digitCount += 1; j += 1; continue }
                    if w, t.lowercased() == "point" { j += 1; continue }
                    if !w, t.allSatisfy({ $0 == " " }) {
                        // keep an inter-word space only if a digit/point word follows it
                        var k = j + 1
                        while k < tokens.count, !tokens[k].1, tokens[k].0.allSatisfy({ $0 == " " }) { k += 1 }
                        if k < tokens.count, tokens[k].1,
                           (digitWord[tokens[k].0.lowercased()] != nil || tokens[k].0.lowercased() == "point") {
                            j += 1; continue
                        }
                    }
                    break
                }
                if digitCount >= 2 {
                    var built = ""
                    for idx in i..<j {
                        let (t, w) = tokens[idx]
                        guard w else { continue }
                        let lower = t.lowercased()
                        if let d = digitWord[lower] { built.append(d) }
                        else if lower == "point" { built.append(".") }
                    }
                    built = built.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    out += built
                    i = j
                    continue
                }
            }
            out += text
            i += 1
        }
        return out
    }

    private static func normalizePercent(_ s: String) -> String {
        s.replacingOccurrences(of: #"(\d)\s*percent\b"#, with: "$1%", options: .regularExpression)
    }

    private static func normalizeSymbols(_ s: String) -> String {
        var r = s
        for (phrase, glyph) in symbolPhrases {
            let escaped = phrase.replacingOccurrences(of: " ", with: #"\s+"#)
            let pattern = #"(?i)\b"# + escaped + #"\b"#
            r = r.replacingOccurrences(of: pattern, with: glyph, options: .regularExpression)
        }
        return r
    }

    // Attach bracket/paren glyphs to their content; join identifier/path symbols to neighbors.
    private static func tidy(_ s: String) -> String {
        var r = s
        r = r.replacingOccurrences(of: #"([(\[{])\s+"#, with: "$1", options: .regularExpression)
        r = r.replacingOccurrences(of: #"\s+([)\]}])"#, with: "$1", options: .regularExpression)
        // Only identifier/path joiners attach to their neighbors ("report _ final" -> "report_final",
        // "a / b" -> "a/b"); arithmetic-style symbols (+ = * ^ ~ | # &) keep the speaker's spacing.
        r = r.replacingOccurrences(of: #"\s*([_/\\])\s*"#, with: "$1", options: .regularExpression)
        r = r.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        return r
    }

    // MARK: helpers

    /// Split into alternating word / non-word runs, losing nothing.
    private static func tokenize(_ s: String) -> [(String, Bool)] {
        var result: [(String, Bool)] = []
        var current = ""
        var currentIsWord = false
        func flush() { if !current.isEmpty { result.append((current, currentIsWord)); current = "" } }
        for ch in s {
            let isWordChar = ch.isLetter || ch.isNumber
            if current.isEmpty { current.append(ch); currentIsWord = isWordChar; continue }
            if isWordChar == currentIsWord { current.append(ch) }
            else { flush(); current.append(ch); currentIsWord = isWordChar }
        }
        flush()
        return result
    }

    private static func replace(_ s: String, _ pattern: String,
                                _ transform: (NSTextCheckingResult, String) -> String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let ns = s as NSString
        let matches = re.matches(in: s, range: NSRange(location: 0, length: ns.length))
        var result = s
        for m in matches.reversed() {
            let replacement = transform(m, s)
            result = (result as NSString).replacingCharacters(in: m.range, with: replacement)
        }
        return result
    }

    private static func group(_ m: NSTextCheckingResult, _ i: Int, _ s: String) -> String {
        let r = m.range(at: i)
        guard r.location != NSNotFound else { return "" }
        return (s as NSString).substring(with: r)
    }
}
