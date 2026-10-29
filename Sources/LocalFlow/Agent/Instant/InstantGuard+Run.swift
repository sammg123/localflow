import Foundation

/// After the run: the files it changed, putting back any that look broken, and Undo.
extension InstantGuard {
    /// The project files this run changed that differ from before it, by name, and new
    /// files it made. Reads them, so call it after a run rather than on every redraw.
    var changedFiles: [String] {
        touched.filter(isChanged).map(Self.displayName)
    }

    var hasChanges: Bool {
        touched.contains(where: isChanged)
    }

    /// Puts back each changed file that looks broken (see InstantVerify) and returns their
    /// names. Remembers how the rest look now, so Undo won't overwrite a later change.
    func verifyAfterRun() -> [String] {
        var restored: [String] = []
        for path in touched {
            guard let original = originals[path] else { continue }
            let now = Self.contents(path)
            guard InstantVerify.problem(name: Self.displayName(path), before: original.data, after: now) != nil,
                  Self.put(original, at: path) else { continue }
            originals[path] = nil
            restored.append(Self.displayName(path))
        }
        touched.removeAll { originals[$0] == nil && !created.contains($0) }
        afterRun = Dictionary(uniqueKeysWithValues: touched.compactMap { path in Self.contents(path).map { (path, $0) } })
        runEnded = true
        FlowLog.shared.write("instant: run changed \(changedFiles.count) files, put back \(restored.count)")
        return restored
    }

    /// Puts every changed project file back as it was and deletes the files the run made.
    /// A file changed again since the run ended (by the user, say) is left alone and counted
    /// as failed. LocalFlow's memory files keep what the run noted. Doing it twice does nothing.
    /// Call `verifyAfterRun()` when the run ends for any reason, a cancel too, so Undo can
    /// tell the run's changes from the user's.
    func undo() -> InstantUndoResult {
        let steps = touched.map(undoStep)
        forgetRun()
        let result = InstantUndoResult(restored: steps.filter { $0 == .restored }.count,
                                       deleted: steps.filter { $0 == .deleted }.count,
                                       failed: steps.filter { $0 == .failed }.count)
        FlowLog.shared.write("instant: undo put back \(result.restored), deleted \(result.deleted), failed \(result.failed)")
        return result
    }

    private enum UndoStep {
        case restored, deleted, failed, skipped
    }

    private func undoStep(_ path: String) -> UndoStep {
        let now = Self.contents(path)
        if let original = originals[path] {
            guard !original.isMemory, now != original.data else { return .skipped }
            if changedSinceRun(path, now: now) { return .failed }
            return Self.put(original, at: path) ? .restored : .failed
        }
        guard created.contains(path), now != nil else { return .skipped }
        if changedSinceRun(path, now: now) { return .failed }
        return (try? FileManager.default.removeItem(atPath: path)) != nil ? .deleted : .failed
    }

    /// The file isn't as the run left it: the user changed it, or made it, since.
    private func changedSinceRun(_ path: String, now: Data?) -> Bool {
        runEnded && afterRun[path] != now
    }

    private func forgetRun() {
        originals = [:]
        created = []
        touched = []
        afterRun = [:]
        runEnded = false
    }

    private func isChanged(_ path: String) -> Bool {
        if let original = originals[path] { return !original.isMemory && Self.contents(path) != original.data }
        return created.contains(path) && FileManager.default.fileExists(atPath: path)
    }

    private static func contents(_ path: String) -> Data? {
        try? Data(contentsOf: URL(fileURLWithPath: path))
    }

    /// Writes the original back whole, with its old permissions.
    private static func put(_ original: Original, at path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard (try? original.data.write(to: url, options: .atomic)) != nil else { return false }
        if let mode = original.mode {
            try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
        }
        return true
    }
}
