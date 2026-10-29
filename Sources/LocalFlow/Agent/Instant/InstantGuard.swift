import Foundation

/// What LocalFlow answers a permission request with in Instant Edits. There are no
/// approval cards: a refusal goes back to the model as the tool's error.
enum InstantDecision: Equatable, Sendable {
    case allow
    /// `message` is written to the model: what was refused and what to do instead.
    case deny(String)
}

/// What Undo did: files put back, new files deleted, and files it couldn't do either for.
struct InstantUndoResult: Equatable, Sendable {
    let restored: Int
    let deleted: Int
    let failed: Int
}

/// How much one Instant run may change.
struct InstantLimits: Equatable, Sendable {
    let maxFileBytes: Int
    let maxEditCharacters: Int
    let maxWriteCharacters: Int
    let maxReplaceAll: Int
    let maxChangedLines: Int
    let maxFiles: Int

    init(maxFileBytes: Int = 1_048_576, maxEditCharacters: Int = 6_000, maxWriteCharacters: Int = 4_000,
         maxReplaceAll: Int = 20, maxChangedLines: Int = 200, maxFiles: Int = 8) {
        self.maxFileBytes = maxFileBytes
        self.maxEditCharacters = maxEditCharacters
        self.maxWriteCharacters = maxWriteCharacters
        self.maxReplaceAll = maxReplaceAll
        self.maxChangedLines = maxChangedLines
        self.maxFiles = maxFiles
    }

    static let standard = InstantLimits()
}

/// Every tool an Instant run asks for comes here: reading inside the project, small
/// edits that stay within the run's limits, a terminal that only reads, and a look at the
/// screen. It keeps each changed file's original, so after the run it can put back a file
/// that looks broken, and Undo can put them all back. One per run.
@MainActor
final class InstantGuard {
    /// A file as it was before the run's first change to it.
    struct Original {
        let data: Data
        let mode: Int?
        /// One of LocalFlow's memory files: checked after the run, but not shown or undone.
        let isMemory: Bool
    }

    static let screenPrefix = AgentPolicy.screenPrefix
    private static let screenLooks: Set<String> = ["screenshot", "list_apps", "wait"]

    let roots: [String]
    let memoryPaths: Set<String>
    let home: String
    let limits: InstantLimits
    let backups: InstantBackups?

    // The run's record, kept by the review, check and undo extensions.
    var originals: [String: Original] = [:]
    var created: Set<String> = []
    /// Changed and created files, in the order the run first touched them.
    var touched: [String] = []
    var linesUsed = 0
    /// How each file looked when the run ended, so Undo can tell a later change by the user.
    var afterRun: [String: Data] = [:]
    /// `verifyAfterRun` has recorded `afterRun`.
    var runEnded = false
    /// Folders an allowed `cd` moved the terminal to; relative paths are checked from them too.
    private var terminalFolders: [String] = []

    /// `projects` are the folders it may change; `memoryPaths` LocalFlow's own memory
    /// files, which it may also note in. Originals are also copied under `backupFolder`.
    init(projects: [String], memoryPaths: Set<String> = [], home: String = NSHomeDirectory(),
         limits: InstantLimits = .standard,
         backupFolder: URL? = InstantBackups.defaultRoot(home: NSHomeDirectory())) {
        roots = projects.compactMap { InstantFolders.resolved($0, home: home) }
        self.memoryPaths = Set(memoryPaths.compactMap { InstantPaths.resolve($0, home: home)?.lowercased() })
        self.home = home
        self.limits = limits
        backups = backupFolder.map { InstantBackups(root: $0) }
    }

    func review(toolName: String, input: AgentJSON) -> InstantDecision {
        switch toolName {
        case "Read": return reviewRead(input["file_path"]?.string)
        case "Glob": return reviewSearch(path: input["path"]?.string, pattern: input["pattern"]?.string)
        case "Grep": return reviewSearch(path: input["path"]?.string, pattern: nil)
        case "Edit": return reviewEdit(input)
        case "Write": return reviewWrite(input)
        case "Bash": return reviewBash(input["command"]?.string)
        case "NotebookEdit": return .deny(InstantRefusal.notebook)
        case "Task", "Agent": return .deny(InstantRefusal.subagent)
        case "WebFetch", "WebSearch": return .deny(InstantRefusal.web)
        default: return reviewOther(toolName)
        }
    }

    // MARK: Reading

    /// Reads stay inside the project and cheap: not generated or downloaded code, not
    /// secrets (they'd go to the model), and nothing too big to be what draws the screen.
    private func reviewRead(_ raw: String?) -> InstantDecision {
        guard let raw, let path = InstantPaths.resolve(raw, home: home) else { return .deny(InstantRefusal.plainPath) }
        if isMemory(path) { return .allow }
        guard let root = InstantPaths.root(of: path, in: roots) else { return .deny(InstantRefusal.outside) }
        if InstantPaths.isGenerated(relative: InstantPaths.relative(path, to: root)) {
            return .deny(InstantRefusal.readGenerated)
        }
        if InstantPaths.isSecret(Self.displayName(path).lowercased()) { return .deny(InstantRefusal.secret) }
        let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber
        return (size?.intValue ?? 0) > limits.maxFileBytes ? .deny(InstantRefusal.bigRead) : .allow
    }

    /// Glob and Grep need a folder inside the project. A Glob pattern written from `/`
    /// must start inside it too.
    private func reviewSearch(path raw: String?, pattern: String?) -> InstantDecision {
        if let pattern, pattern.split(separator: "/").contains("..") { return .deny(InstantRefusal.plainPath) }
        let fixed = pattern.flatMap(Self.fixedStart)
        guard let folder = raw ?? fixed else { return .deny(InstantRefusal.searchPath) }
        let starts = [folder] + (raw != nil ? [fixed].compactMap { $0 } : [])
        for start in starts {
            guard let path = InstantPaths.resolve(start, home: home) else { return .deny(InstantRefusal.plainPath) }
            guard let root = InstantPaths.root(of: path, in: roots) else { return .deny(InstantRefusal.outside) }
            if InstantPaths.isGenerated(relative: InstantPaths.relative(path, to: root)) {
                return .deny(InstantRefusal.readGenerated)
            }
        }
        return .allow
    }

    /// The part of an absolute glob before its first wildcard: `/a/src` of `/a/src/**/*.ts`.
    private static func fixedStart(_ pattern: String) -> String? {
        guard pattern.hasPrefix("/") || pattern.hasPrefix("~") else { return nil }
        let parts = pattern.split(separator: "/", omittingEmptySubsequences: false)
        let fixed = parts.prefix { !$0.contains(where: { "*?[{".contains($0) }) }
        let joined = fixed.joined(separator: "/")
        return joined.isEmpty ? "/" : joined
    }

    private func reviewBash(_ command: String?) -> InstantDecision {
        let decision = InstantBash.review(command, roots: roots, home: home, folders: terminalFolders)
        if decision == .allow, let command {
            let moved = InstantBash.cdTargets(in: command, home: home).filter { !terminalFolders.contains($0) }
            terminalFolders += moved
        }
        return decision
    }

    private func reviewOther(_ toolName: String) -> InstantDecision {
        guard toolName.hasPrefix(Self.screenPrefix) else { return .deny(InstantRefusal.otherTool(toolName)) }
        let action = String(toolName.dropFirst(Self.screenPrefix.count))
        return Self.screenLooks.contains(action) ? .allow : .deny(InstantRefusal.screen)
    }

    // MARK: Places

    func isInsideProject(_ path: String) -> Bool {
        InstantPaths.root(of: path, in: roots) != nil
    }

    func isMemory(_ path: String) -> Bool {
        memoryPaths.contains(path.lowercased())
    }

    static func displayName(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}
