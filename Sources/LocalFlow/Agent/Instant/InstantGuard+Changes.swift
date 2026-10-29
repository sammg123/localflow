import Foundation

/// Edit and Write: only small, UI-only changes to the project's own text files, within the
/// run's limits, with each file's original kept first.
extension InstantGuard {
    /// Where a change would land, once its path is checked.
    private struct Target {
        let path: String
        let isMemory: Bool
    }

    func reviewEdit(_ input: AgentJSON) -> InstantDecision {
        guard let raw = input["file_path"]?.string, let old = input["old_string"]?.string,
              let new = input["new_string"]?.string else { return .deny(InstantRefusal.editFields) }
        let target: Target
        switch place(raw) {
        case .success(let found): target = found
        case .failure(let refusal): return .deny(refusal.message)
        }
        if let problem = textProblem(old: old, new: new) { return .deny(problem) }
        let data: Data
        switch readable(target.path) {
        case .success(let found): data = found
        case .failure(let refusal): return .deny(refusal.message)
        }
        let replaceAll = input["replace_all"]?.bool == true
        if !target.isMemory, let kind = behaviorChange(in: data, old: old, new: new, all: replaceAll) {
            return .deny(InstantRefusal.behavior(kind))
        }
        let places = replaceAll ? occurrences(of: old, in: data) : 1
        if places > limits.maxReplaceAll { return .deny(InstantRefusal.replaceAll(places, limit: limits.maxReplaceAll)) }
        let lines = max(Self.lineCount(old), Self.lineCount(new)) * max(places, 1)
        if !target.isMemory, !fitsBudget(lines: lines, path: target.path) { return .deny(InstantRefusal.budget) }
        keepOriginal(target, data: data)
        if !target.isMemory { linesUsed += lines }
        return .allow
    }

    func reviewWrite(_ input: AgentJSON) -> InstantDecision {
        guard let raw = input["file_path"]?.string, let content = input["content"]?.string else {
            return .deny(InstantRefusal.writeFields)
        }
        let target: Target
        switch place(raw) {
        case .success(let found): target = found
        case .failure(let refusal): return .deny(refusal.message)
        }
        if InstantPaths.exists(target.path) { return .deny(InstantRefusal.writeExisting) }
        let folder = URL(fileURLWithPath: target.path).deletingLastPathComponent().path
        guard FileManager.default.fileExists(atPath: folder) else { return .deny(InstantRefusal.newFolder) }
        if content.count > limits.maxWriteCharacters { return .deny(InstantRefusal.longWrite(limits.maxWriteCharacters)) }
        if target.isMemory { return .allow }
        if let kind = InstantUIOnly.addedBehavior(old: "", new: content, isNewFile: true) {
            return .deny(InstantRefusal.behavior(kind))
        }
        let lines = Self.lineCount(content)
        guard fitsBudget(lines: lines, path: target.path) else { return .deny(InstantRefusal.budget) }
        created.insert(target.path)
        touch(target.path)
        linesUsed += lines
        backups?.noteCreated(target.path)
        return .allow
    }

    // MARK: Checks

    private struct Refusal: Error {
        let message: String
    }

    /// The real path, if the file may change: one of LocalFlow's memory files, or a file
    /// in the project that isn't generated, a lockfile, a secret, a binary or clearly not UI.
    private func place(_ raw: String) -> Result<Target, Refusal> {
        guard let path = InstantPaths.resolve(raw, home: home) else { return .failure(Refusal(message: InstantRefusal.plainPath)) }
        if isMemory(path) { return .success(Target(path: path, isMemory: true)) }
        guard let root = InstantPaths.root(of: path, in: roots) else { return .failure(Refusal(message: InstantRefusal.outside)) }
        let relative = InstantPaths.relative(path, to: root)
        if let refusal = InstantPaths.refusal(relative: relative) { return .failure(Refusal(message: refusal)) }
        if let kind = InstantUIOnly.nonUIReason(relativePath: relative) {
            return .failure(Refusal(message: InstantRefusal.notUI(kind)))
        }
        return .success(Target(path: path, isMemory: false))
    }

    private func textProblem(old: String, new: String) -> String? {
        if old.isEmpty { return InstantRefusal.emptyOld }
        if old == new { return InstantRefusal.sameText }
        if old.count > limits.maxEditCharacters || new.count > limits.maxEditCharacters {
            return InstantRefusal.longEdit(limits.maxEditCharacters)
        }
        return nil
    }

    /// The file's text, if it's an existing regular text file small enough to change.
    private func readable(_ path: String) -> Result<Data, Refusal> {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            return .failure(Refusal(message: InstantRefusal.missingFile))
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            return .failure(Refusal(message: InstantRefusal.notAFile))
        }
        // Edit writes in place, so a hard link would change the same file somewhere else too.
        if ((attributes[.referenceCount] as? NSNumber)?.intValue ?? 1) > 1 {
            return .failure(Refusal(message: InstantRefusal.hardLink))
        }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        if size > limits.maxFileBytes { return .failure(Refusal(message: InstantRefusal.tooLargeFile)) }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return .failure(Refusal(message: InstantRefusal.missingFile))
        }
        return InstantPaths.isText(data) ? .success(data) : .failure(Refusal(message: InstantRefusal.binary))
    }

    /// What behavior the edit adds, judged on the whole lines it lands on.
    private func behaviorChange(in data: Data, old: String, new: String, all: Bool) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        let lines = InstantUIOnly.editedLines(of: text, old: old, new: new, all: all) ?? (old, new)
        return InstantUIOnly.addedBehavior(old: lines.before, new: lines.after, isNewFile: false)
    }

    private func occurrences(of text: String, in data: Data) -> Int {
        String(decoding: data, as: UTF8.self).components(separatedBy: text).count - 1
    }

    // MARK: The run's record

    private func fitsBudget(lines: Int, path: String) -> Bool {
        let files = Set(touched).union([path]).filter { !isMemory($0) }.count
        return linesUsed + lines <= limits.maxChangedLines && files <= limits.maxFiles
    }

    /// The file as it was before the run, kept the first time only. A file this run made
    /// has no original: Undo deletes it.
    private func keepOriginal(_ target: Target, data: Data) {
        guard originals[target.path] == nil, !created.contains(target.path) else { return }
        let mode = (try? FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions]) as? Int
        originals[target.path] = Original(data: data, mode: mode, isMemory: target.isMemory)
        touch(target.path)
        backups?.save(data, originalPath: target.path)
    }

    private func touch(_ path: String) {
        if !touched.contains(path) { touched.append(path) }
    }

    static func lineCount(_ text: String) -> Int {
        text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count
    }
}
