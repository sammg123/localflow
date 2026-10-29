import Foundation

/// Copies on disk of the files an Instant run changes, besides the ones in memory, so a
/// crash or quit mid-run can't lose the originals. One owner-only folder per run, made
/// only once something changes; the last `keep` runs are kept.
final class InstantBackups {
    static let keep = 10
    static let manifestName = "manifest.json"
    private static let ownerOnly: [FileAttributeKey: Any] = [.posixPermissions: 0o700]

    private let root: URL
    private let runID: String
    private var entries: [[String: String]] = []

    static func defaultRoot(home: String) -> URL {
        URL(fileURLWithPath: home + "/Library/Application Support/LocalFlow/instant-backups")
    }

    /// Sorts by time: `20261029-142501-123-ab12cd`.
    static func makeRunID(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: now) + "-" + UUID().uuidString.prefix(6).lowercased()
    }

    init(root: URL, runID: String = InstantBackups.makeRunID()) {
        self.root = root
        self.runID = runID
    }

    private var folder: URL {
        root.appendingPathComponent(runID)
    }

    /// Keeps a copy of a file as it was before the run. Failures only cost the extra copy.
    func save(_ data: Data, originalPath: String) {
        guard prepare() else { return }
        let name = String(format: "%02d-", entries.count + 1) + URL(fileURLWithPath: originalPath).lastPathComponent
        let copy = folder.appendingPathComponent(name)
        guard FileManager.default.createFile(atPath: copy.path, contents: data, attributes: AskTool.privateFile) else {
            return
        }
        record(["path": originalPath, "backup": name, "kind": "changed"])
    }

    /// Notes a file the run made, which Undo deletes.
    func noteCreated(_ path: String) {
        guard prepare() else { return }
        record(["path": path, "kind": "created"])
    }

    private func record(_ entry: [String: String]) {
        entries.append(entry)
        guard let data = try? JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        let manifest = folder.appendingPathComponent(Self.manifestName)
        try? FileManager.default.removeItem(at: manifest)
        FileManager.default.createFile(atPath: manifest.path, contents: data, attributes: AskTool.privateFile)
    }

    /// Makes the run's folder the first time, after clearing all but the newest earlier runs.
    private func prepare() -> Bool {
        let files = FileManager.default
        if files.fileExists(atPath: folder.path) { return true }
        do {
            try files.createDirectory(at: root, withIntermediateDirectories: true, attributes: Self.ownerOnly)
            removeOldRuns()
            try files.createDirectory(at: folder, withIntermediateDirectories: false, attributes: Self.ownerOnly)
            return true
        } catch {
            FlowLog.shared.write("instant: couldn't make a backup folder")
            return false
        }
    }

    private func removeOldRuns() {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { $0.range(of: #"^\d{8}-\d{6}"#, options: .regularExpression) != nil }
            .sorted()
        for name in names.dropLast(Self.keep - 1) {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
        }
    }
}
