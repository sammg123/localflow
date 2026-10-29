import Foundation

/// Commands that write the files named in their arguments (`cp`, `tee`, `curl -o`,
/// `sed -i`, `tar -C` …): whether any of those files is protected.
enum AgentWrites {
    static let writers: Set<String> = ["tee", "cp", "ln", "install", "truncate", "touch", "chmod", "chown", "chflags",
                                       "sed", "perl", "curl", "wget", "tar", "unzip", "ditto", "plutil", "ssh-keygen",
                                       "gzip", "gunzip", "mkdir", "sort", "patch", "xattr"]
    /// Commands whose last argument is where they write.
    private static let lastIsTarget: Set<String> = ["cp", "ln", "install", "ditto", "tee", "touch", "truncate", "mkdir",
                                                    "chmod", "chown", "chflags", "xattr"]
    /// Options whose value is where the command writes.
    private static let targetOptions: Set<String> = ["-o", "--output", "-O", "--output-document", "-C", "--directory",
                                                     "-d", "-f", "--file"]

    static func isRisky(_ command: String, _ args: [String], home: String, directory: String?) -> Bool {
        guard writers.contains(command) else { return false }
        if ["sed", "perl"].contains(command),
           !args.contains(where: { AgentCommandWords.isShortCluster($0, with: "i") || $0.hasPrefix("--in-place") }) {
            return false
        }
        return targets(command, args).contains { target in
            braceFree(target.word).contains { word in
                guard let path = AgentPaths.shellPath(word, home: home) else {
                    return target.isTarget || AgentPaths.mayBeProtected(word, home: home)
                }
                return AgentPaths.isProtectedArgument(path, home: home, directory: directory)
            }
        }
    }

    /// Each path-like word, and whether it's surely where the command writes: the last
    /// argument of `cp` and the like, or the value of `-o`/`-C`, attached or not.
    private static func targets(_ command: String, _ args: [String]) -> [(word: String, isTarget: Bool)] {
        args.indices.compactMap { index in
            let arg = args[index]
            guard arg.hasPrefix("-") else {
                let afterOption = index > 0 && targetOptions.contains(args[index - 1])
                let isLast = index == args.count - 1 && lastIsTarget.contains(command)
                return (arg, afterOption || isLast)
            }
            if let equals = arg.firstIndex(of: "=") { // --output=PATH
                return (String(arg[arg.index(after: equals)...]), targetOptions.contains(String(arg[..<equals])))
            }
            if !arg.hasPrefix("--"), let start = arg.firstIndex(where: { $0 == "/" || $0 == "~" }) { // -fsSLo/PATH
                return (String(arg[start...]), true)
            }
            return nil
        }
    }

    /// A word with `{a,b}` written out as each word it becomes, up to `limit` of them;
    /// past that, or for ranges and nested braces, the word as it is.
    private static func braceFree(_ word: String, limit: Int = 64) -> [String] {
        guard let open = word.firstIndex(of: "{"), let close = word[open...].firstIndex(of: "}") else { return [word] }
        let inside = word[word.index(after: open)..<close]
        let options = inside.split(separator: ",", omittingEmptySubsequences: false)
        guard options.count > 1, options.count <= limit, !inside.contains("{") else { return [word] }
        let (head, tail) = (word[..<open], word[word.index(after: close)...])
        return options.flatMap { braceFree(String(head + $0 + tail), limit: limit / options.count) }
    }
}
