import Foundation

/// Whether a web request sends something rather than just fetching it.
enum AgentNetwork {
    /// Methods that only read.
    private static let reading: Set<String> = ["GET", "HEAD", "OPTIONS"]

    private static let curlSendOptions: Set<String> = ["--data", "--data-raw", "--data-binary", "--data-urlencode",
                                                       "--data-ascii", "--form", "--form-string", "--upload-file",
                                                       "--json"]
    /// curl's short options that take a value; the rest of a cluster after one is that value.
    private static let curlValued = Set("AbcCdDeEFHKmoPQrTuUwxXYyzt")

    static func curlSends(_ args: [String]) -> Bool {
        args.indices.contains { index in
            let arg = args[index]
            let following = index + 1 < args.count ? args[index + 1] : nil
            if arg.hasPrefix("--") {
                let parts = arg.split(separator: "=", maxSplits: 1).map(String.init)
                if curlSendOptions.contains(parts[0]) { return true }
                guard parts[0] == "--request" else { return false }
                return isWriting(parts.count > 1 ? parts[1] : following)
            }
            guard arg.hasPrefix("-"), arg.count > 1 else { return false }
            return shortCurlSends(Array(arg.dropFirst()), following: following)
        }
    }

    /// One cluster such as `-sSL`, `-d@f` or `-XPOST`.
    private static func shortCurlSends(_ letters: [Character], following: String?) -> Bool {
        for (offset, letter) in letters.enumerated() {
            if "dFT".contains(letter) { return true }
            if letter == "X" {
                let attached = String(letters[(offset + 1)...])
                return isWriting(attached.isEmpty ? following : attached)
            }
            if curlValued.contains(letter) { return false }
        }
        return false
    }

    static func wgetSends(_ args: [String]) -> Bool {
        let sending = ["--post-data", "--post-file", "--body-data", "--body-file"]
        return args.indices.contains { index in
            let arg = args[index]
            if sending.contains(where: { arg == $0 || arg.hasPrefix($0 + "=") }) { return true }
            if arg.hasPrefix("--method=") { return isWriting(String(arg.dropFirst("--method=".count))) }
            return arg == "--method" && isWriting(index + 1 < args.count ? args[index + 1] : nil)
        }
    }

    /// `gh api` changes something when its method isn't GET or it sends fields or a body.
    static func ghAPIChanges(_ args: [String]) -> Bool {
        let sendFlags: Set<String> = ["-f", "-F", "--field", "--raw-field", "--input"]
        return args.indices.contains { index in
            let arg = args[index]
            if sendFlags.contains(arg) || ["--field=", "--raw-field=", "--input="].contains(where: arg.hasPrefix) {
                return true
            }
            if !arg.hasPrefix("--"), arg.count > 2, arg.hasPrefix("-f") || arg.hasPrefix("-F") { return true }
            if arg == "-X" || arg == "--method" { return isWriting(index + 1 < args.count ? args[index + 1] : nil) }
            if arg.hasPrefix("--method=") { return isWriting(String(arg.dropFirst("--method=".count))) }
            if arg.hasPrefix("-X"), arg.count > 2 { return isWriting(String(arg.dropFirst(2))) }
            return false
        }
    }

    /// A method that isn't plain reading. A missing one counts as writing: it can't be checked.
    private static func isWriting(_ method: String?) -> Bool {
        guard let method else { return true }
        return !reading.contains(method.uppercased())
    }
}
