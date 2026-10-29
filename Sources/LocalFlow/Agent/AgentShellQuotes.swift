import Foundation

extension AgentShellSplitter {
    /// `$'…'`, read the way the shell reads it: backslash escapes like C (`\n`, `\x72`,
    /// `\162`, `r`, `\cA`, `\'`), so the word is what actually runs.
    mutating func readANSIC() -> String {
        var text = String.UnicodeScalarView()
        while index < chars.count, chars[index] != "'" {
            let c = chars[index]
            index += 1
            guard c == "\\", index < chars.count else {
                text.append(c)
                continue
            }
            text.append(contentsOf: escape())
        }
        index += 1
        return String(text)
    }

    /// One escape after a backslash; `index` is just past the backslash.
    private mutating func escape() -> [Unicode.Scalar] {
        let simple: [Unicode.Scalar: Unicode.Scalar] = ["a": "\u{07}", "b": "\u{08}", "e": "\u{1B}", "E": "\u{1B}",
                                                        "f": "\u{0C}", "n": "\n", "r": "\r", "t": "\t", "v": "\u{0B}"]
        let e = chars[index]
        index += 1
        if let mapped = simple[e] { return [mapped] }
        switch e {
        case "x": return code(radix: 16, digits: 2).map { [$0] } ?? ["\\", "x"]
        case "u": return code(radix: 16, digits: 4).map { [$0] } ?? ["\\", "u"]
        case "U": return code(radix: 16, digits: 8).map { [$0] } ?? ["\\", "U"]
        case "0"..."7":
            index -= 1
            return code(radix: 8, digits: 3).map { [$0] } ?? []
        case "c":
            guard index < chars.count else { return ["\\", "c"] }
            let control = chars[index].value & 0x1F
            index += 1
            return Unicode.Scalar(control).map { [$0] } ?? []
        default:
            return [e] // \\ \' \" \? and anything else stand for themselves
        }
    }

    /// Up to `digits` digits in `radix` as one character, or nil when there are none.
    private mutating func code(radix: Int, digits: Int) -> Unicode.Scalar? {
        var found = ""
        while found.count < digits, index < chars.count, Int(String(chars[index]), radix: radix) != nil {
            found.unicodeScalars.append(chars[index])
            index += 1
        }
        return UInt32(found, radix: radix).flatMap { Unicode.Scalar($0) }
    }
}
