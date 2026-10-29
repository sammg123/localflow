import Foundation

/// LocalFlow's two memory files, which Ask and the agent read on every run and add to
/// when something is worth keeping. localflow.md holds the user's standing instructions;
/// flow-memory.md holds what's been learned, above all which project is which. Only
/// the user's account can read them, and nothing from them goes in the event log.
struct FlowMemory: Sendable {
    /// Where a note goes: a heading in flow-memory.md, or localflow.md.
    enum Section: String, CaseIterable, Sendable {
        case projects, notes, instructions
    }

    /// Why a note wasn't added. Safe to log: it never carries the note.
    enum Refusal: String, Error, Sendable {
        case empty, multiline, tooLong, markup, duplicate, secret, full, unwritable
    }

    static let instructionsFileName = "localflow.md"
    static let memoryFileName = "flow-memory.md"

    let folder: URL
    private let log: FlowLog

    /// The real folder unless one is given (tests use a temporary one).
    init(folder: URL = FlowMemory.defaultFolder(), log: FlowLog = .shared) {
        self.folder = folder
        self.log = log
    }

    static func defaultFolder(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home + "/Library/Application Support/LocalFlow/Memory", isDirectory: true)
    }

    var instructionsURL: URL { folder.appendingPathComponent(Self.instructionsFileName) }
    var memoryURL: URL { folder.appendingPathComponent(Self.memoryFileName) }

    /// The two files' standardized paths, so the agent's policy can allow edits to
    /// exactly these.
    var paths: Set<String> { [instructionsURL.standardizedFileURL.path, memoryURL.standardizedFileURL.path] }

    /// Makes the folder, and each file that's missing from its starter template. Files
    /// already there are left alone. False (and logged) when it couldn't.
    @discardableResult
    func ensureFiles() -> Bool {
        let files = FileManager.default
        do {
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            let starters = [(instructionsURL, Self.instructionsTemplate), (memoryURL, Self.memoryTemplate)]
            for (url, template) in starters where !files.fileExists(atPath: url.path) {
                try write(template, to: url)
            }
            return true
        } catch {
            log.write("memory: couldn't create its files (error \((error as NSError).code))")
            return false
        }
    }

    /// Both files as they're shown to a model, each cut to `maxFileBytes` at a line
    /// break. A missing file reads as empty.
    func read() -> (instructions: String, memory: String) {
        (head(of: instructionsURL), head(of: memoryURL))
    }

    /// Adds one note as a bullet line: instructions to localflow.md, projects and notes
    /// under their headings in flow-memory.md. A project already listed by the same name
    /// has its line replaced. Refuses anything empty, multi-line, too long, markup,
    /// already there, secret-looking, or that would grow the file past its size cap.
    /// Not locked against the agent editing the same file at that moment: the rename
    /// keeps the file whole, but one of the two changes can be lost.
    func remember(_ note: String, section: Section) throws(Refusal) {
        let entry = try Self.validated(note)
        let url = section == .instructions ? instructionsURL : memoryURL
        guard ensureFiles(), let current = try? String(contentsOf: url, encoding: .utf8) else { throw .unwritable }
        guard !Self.entries(in: current).contains(entry) else { throw .duplicate }
        let updated = Self.adding(entry, to: current, section: section)
        let size = updated.utf8.count
        guard size <= Self.maxFileBytes || size <= current.utf8.count else { throw .full }
        do {
            try write(updated, to: url)
        } catch {
            throw .unwritable
        }
    }

    /// Adds each note, and logs how many went in and why any didn't: never their text.
    /// Returns how many were added.
    @discardableResult
    func remember(_ notes: [(section: Section, text: String)]) -> Int {
        guard !notes.isEmpty else { return 0 }
        let refusals = notes.compactMap { note -> Refusal? in
            do throws(Refusal) {
                try remember(note.text, section: note.section)
                return nil
            } catch {
                return error
            }
        }
        let added = notes.count - refusals.count
        let kinds = Set(refusals.map(\.rawValue)).sorted().joined(separator: ", ")
        log.write("memory: added \(added) note\(added == 1 ? "" : "s"), refused \(refusals.count)"
            + (kinds.isEmpty ? "" : " (\(kinds))"))
        return added
    }

    /// The start of a file, cut at a line break if it's over the cap; reads no more of it
    /// than that. A file that's there but can't be read is logged and reads as empty.
    private func head(of url: URL) -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: Self.maxFileBytes + 1) ?? Data()
            return Self.capped(String(decoding: data, as: UTF8.self))
        } catch {
            log.write("memory: couldn't read a file (error \((error as NSError).code))")
            return ""
        }
    }

    /// All at once and owner-only: a fresh 0600 file in the same folder, renamed over
    /// the old one, so a crash never leaves half a file.
    private func write(_ text: String, to url: URL) throws {
        let temporary = folder.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: Data(text.utf8),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(temporary.path, url.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: temporary)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }
}
