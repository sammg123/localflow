import Foundation

/// The agent's folders: the neutral one Claude Code works in, and a private temporary
/// one per session for its MCP config and error output.
enum AgentFiles {
    /// Apart from Ask's folders, whose cleanup would remove a session that runs long.
    static let folderPrefix = "localflow-agent-"
    /// A session's folder older than this was left by a crash or a quit.
    static let leftoverAge: TimeInterval = 86_400
    static let ownerOnly: [FileAttributeKey: Any] = [.posixPermissions: 0o700]

    /// The folder Claude Code runs in, created owner-only if it's missing.
    static func makeWorkingDirectory(home: String) throws -> URL {
        let url = URL(fileURLWithPath: AgentInvocation.workingDirectory(home: home))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: ownerOnly)
        try FileManager.default.setAttributes(ownerOnly, ofItemAtPath: url.path)
        return url
    }

    /// A fresh owner-only folder for one session. The caller deletes it.
    static func makeFolder(in parent: URL = FileManager.default.temporaryDirectory) throws -> URL {
        removeLeftovers(in: parent)
        let url = parent.appendingPathComponent(folderPrefix + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: ownerOnly)
        return url
    }

    static func removeLeftovers(in parent: URL, now: Date = Date()) {
        let files = FileManager.default
        let names = (try? files.contentsOfDirectory(atPath: parent.path)) ?? []
        for name in names where name.hasPrefix(folderPrefix) {
            let url = parent.appendingPathComponent(name)
            let modified = (try? files.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date ?? now
            if now.timeIntervalSince(modified) > leftoverAge { try? files.removeItem(at: url) }
        }
    }

    /// The end of a session's error output, read without loading all of it: a session
    /// can run for hours.
    static func tail(of file: URL, bytes: Int = AskTool.stderrTailBytes) -> String {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
