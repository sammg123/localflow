import Foundation
import Testing
@testable import LocalFlow

/// After a run: putting back files that look broken, and Undo. Each test lets the guard
/// allow an edit, then changes the file the way Claude Code would.
@MainActor
@Suite("Instant Edits: checking and undoing a run")
struct InstantVerifyTests {
    @MainActor
    private struct Run {
        let box: InstantSandbox
        let app: String
        let guarded: InstantGuard

        init() throws {
            box = try InstantSandbox()
            app = try box.project()
            guarded = InstantGuard(projects: [app], home: box.home, backupFolder: box.backups)
        }

        /// Writes `before`, lets the guard allow an edit to it, then leaves `after` on disk.
        @discardableResult
        func change(_ name: String, from before: String, to after: String?, old: String = "a", new: String = "b") throws -> String {
            let path = try box.write(before, to: app + "/" + name)
            let anchor = before.isEmpty ? old : String(before.prefix(4))
            let decision = guarded.review(toolName: "Edit", input: InstantInput.edit(path, anchor, anchor + new))
            #expect(decision == .allow, "\(name): \(String(describing: decision.message))")
            if let after { try box.write(after, to: path) } else { try FileManager.default.removeItem(atPath: path) }
            return path
        }
    }

    // MARK: Restoring broken files

    @Test("a file left empty or deleted is put back")
    func emptiedOrGone() throws {
        let run = try Run()
        defer { run.box.cleanUp() }
        let emptied = try run.change("a.swift", from: instantLines(5), to: "")
        let gone = try run.change("b.swift", from: instantLines(5), to: nil)
        #expect(Set(run.guarded.verifyAfterRun()) == ["a.swift", "b.swift"])
        #expect(run.box.read(emptied) == instantLines(5))
        #expect(run.box.read(gone) == instantLines(5))
    }

    @Test("a file that lost most of its lines is put back; a small trim stays")
    func shrank() throws {
        let run = try Run()
        defer { run.box.cleanUp() }
        let cut = try run.change("cut.swift", from: instantLines(60), to: instantLines(25))
        let trimmed = try run.change("trim.swift", from: instantLines(100), to: instantLines(85))
        let small = try run.change("small.swift", from: instantLines(30), to: instantLines(10))
        #expect(run.guarded.verifyAfterRun() == ["cut.swift"])
        #expect(run.box.read(cut) == instantLines(60))
        #expect(run.box.read(trimmed) == instantLines(85))
        #expect(run.box.read(small) == instantLines(10)) // shrank by more than half, but only 20 lines
    }

    @Test("JSON and plist files that stop parsing are put back")
    func structured() throws {
        let run = try Run()
        defer { run.box.cleanUp() }
        let json = try run.change("theme.json", from: "{\"accent\": \"red\"}\n", to: "{\"accent\": \"blue\"\n")
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>Tint</key><string>red</string></dict></plist>

        """
        let plistPath = try run.change("Info.plist", from: plist, to: plist.replacingOccurrences(of: "</dict>", with: ""))
        let fine = try run.change("ok.json", from: "{\"a\": 1}\n", to: "{\"a\": 2}\n")
        let alreadyBroken = try run.change("loose.json", from: "{a: 1, // note\n}\n", to: "{a: 2, // note\n")
        #expect(Set(run.guarded.verifyAfterRun()) == ["theme.json", "Info.plist"])
        #expect(run.box.read(json) == "{\"accent\": \"red\"}\n")
        #expect(run.box.read(plistPath) == plist)
        #expect(run.box.read(fine) == "{\"a\": 2}\n")
        #expect(run.box.read(alreadyBroken) == "{a: 2, // note\n")
    }

    @Test("code whose brackets stopped balancing is put back")
    func brackets() throws {
        let run = try Run()
        defer { run.box.cleanUp() }
        let swift = "struct A: View {\n    var body: some View {\n        Text(\"Hi\")\n    }\n}\n"
        let brokenSwift = "struct A: View {\n    var body: some View {\n        Text(\"Hi\")\n}\n"
        let tsx = "export const A = () => (\n  <div style={{ color: 'red' }}>Hi</div>\n)\n"
        let brokenTSX = "export const A = () => (\n  <div style={{ color: 'red' }>Hi</div>\n)\n"
        try run.change("A.swift", from: swift, to: brokenSwift)
        try run.change("A.tsx", from: tsx, to: brokenTSX)
        #expect(Set(run.guarded.verifyAfterRun()) == ["A.swift", "A.tsx"])
    }

    @Test("normal small edits never trip the checks", arguments: [
        ("View.swift", "struct A: View {\n    var body: some View {\n        Text(\"Save\")\n            .foregroundStyle(.red)\n    }\n}\n",
         "struct A: View {\n    var body: some View {\n        Text(\"Save\")\n            .foregroundStyle(.blue)\n            .padding(.horizontal, 12)\n    }\n}\n"),
        ("Button.tsx", "export function B() {\n  return <button className=\"p-2\">Save</button>\n}\n",
         "export function B() {\n  return <button className=\"p-4\" style={{ color: 'blue' }} aria-label=\"Save\">Save</button>\n}\n"),
        ("app.css", ".save {\n  color: red;\n}\n", ".save {\n  color: blue;\n  padding: 8px;\n}\n.save:hover { opacity: 0.8; }\n"),
        ("Label.swift", "let a = Text(\"Step 1\")\n", "let a = Text(\"Step 1)\")\n"),
        ("Copy.tsx", "const a = <p>Don't save (yet)</p>\n", "const a = <p>Do not save</p>\n"),
        ("Hide.tsx", "<div>\n  <Badge />\n  <span>{count}</span>\n</div>\n", "<div>\n  <span>{count}</span>\n</div>\n"),
        ("Strings.json", "{\"save\": \"Save\"}\n", "{\"save\": \"Submit (beta)\"}\n"),
    ])
    func noFalseAlarms(name: String, before: String, after: String) throws {
        let run = try Run()
        defer { run.box.cleanUp() }
        let path = try run.change(name, from: before, to: after)
        #expect(run.guarded.verifyAfterRun().isEmpty, "\(name)")
        #expect(run.box.read(path) == after)
    }

    @Test("a file the run didn't change isn't listed")
    func untouched() throws {
        let run = try Run()
        defer { run.box.cleanUp() }
        let before = instantLines(3)
        try run.change("same.swift", from: before, to: before)
        #expect(run.guarded.changedFiles.isEmpty)
        #expect(!run.guarded.hasChanges)
        #expect(run.guarded.verifyAfterRun().isEmpty)
    }

    // MARK: Undo

    @Test("Undo puts edited files back and deletes new ones, once")
    func undo() throws {
        let run = try Run()
        defer { run.box.cleanUp() }
        let first = try run.change("a.css", from: ".a { color: red; }\n", to: ".a { color: blue; }\n")
        let second = try run.change("b.css", from: ".b { color: red; }\n", to: ".b { color: green; }\n")
        let fresh = run.app + "/c.css"
        #expect(run.guarded.review(toolName: "Write", input: InstantInput.write(fresh, ".c {}\n")) == .allow)
        try run.box.write(".c {}\n", to: fresh)
        #expect(run.guarded.changedFiles == ["a.css", "b.css", "c.css"])
        #expect(run.guarded.verifyAfterRun().isEmpty)

        #expect(run.guarded.undo() == InstantUndoResult(restored: 2, deleted: 1, failed: 0))
        #expect(run.box.read(first) == ".a { color: red; }\n")
        #expect(run.box.read(second) == ".b { color: red; }\n")
        #expect(!run.box.exists(fresh))
        #expect(!run.guarded.hasChanges)
        #expect(run.guarded.changedFiles.isEmpty)
        #expect(run.guarded.undo() == InstantUndoResult(restored: 0, deleted: 0, failed: 0))
    }

    @Test("Undo keeps the original file mode")
    func undoKeepsMode() throws {
        let run = try Run()
        defer { run.box.cleanUp() }
        let path = try run.box.write("echo a\n", to: run.app + "/notes.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: path)
        #expect(run.guarded.review(toolName: "Edit", input: InstantInput.edit(path, "a", "b")) == .allow)
        try FileManager.default.removeItem(atPath: path)
        try run.box.write("echo b\n", to: path)
        #expect(run.guarded.undo().restored == 1)
        #expect(run.box.read(path) == "echo a\n")
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        #expect(mode == 0o640)
    }

    @Test("Undo leaves alone a file the user changed after the run")
    func undoSkipsLaterChanges() throws {
        let run = try Run()
        defer { run.box.cleanUp() }
        let path = try run.change("a.css", from: ".a { color: red; }\n", to: ".a { color: blue; }\n")
        _ = run.guarded.verifyAfterRun()
        try run.box.write(".a { color: purple; }\n", to: path) // the user's own edit
        #expect(run.guarded.undo() == InstantUndoResult(restored: 0, deleted: 0, failed: 1))
        #expect(run.box.read(path) == ".a { color: purple; }\n")
        #expect(!run.guarded.hasChanges)
    }

    @Test("Undo doesn't delete a file the user made after a run whose Write never landed")
    func undoSkipsLaterNewFile() throws {
        let run = try Run()
        defer { run.box.cleanUp() }
        let fresh = run.app + "/badge.css"
        #expect(run.guarded.review(toolName: "Write", input: InstantInput.write(fresh, ".b {}\n")) == .allow)
        _ = run.guarded.verifyAfterRun() // Claude Code didn't write it after all
        try run.box.write(".mine {}\n", to: fresh) // the user's own file
        #expect(run.guarded.undo() == InstantUndoResult(restored: 0, deleted: 0, failed: 1))
        #expect(run.box.read(fresh) == ".mine {}\n")
    }

    @Test("a file restored by the check isn't counted again by Undo")
    func verifyThenUndo() throws {
        let run = try Run()
        defer { run.box.cleanUp() }
        try run.change("a.swift", from: instantLines(5), to: "")
        #expect(run.guarded.verifyAfterRun() == ["a.swift"])
        #expect(!run.guarded.hasChanges)
        #expect(run.guarded.undo() == InstantUndoResult(restored: 0, deleted: 0, failed: 0))
    }

    // MARK: Backups on disk

    @Test("originals are also kept on disk, owner-only, for the last 10 runs")
    func backups() throws {
        let run = try Run()
        defer { run.box.cleanUp() }
        let root = run.box.backups
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for index in 0..<12 {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("20200101-0000\(String(format: "%02d", index))-old"),
                                                    withIntermediateDirectories: true)
        }
        try run.change("a.css", from: ".a { color: red; }\n", to: ".a { color: blue; }\n")
        let runs = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { !$0.hasPrefix(".") }
        #expect(runs.count == 10)
        let newest = try #require(runs.sorted().last)
        let folder = root.appendingPathComponent(newest)
        let folderMode = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int
        #expect(folderMode == 0o700)
        let saved = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(saved.contains("manifest.json"))
        let copy = try #require(saved.first { $0 != "manifest.json" })
        let copyPath = folder.appendingPathComponent(copy).path
        #expect(run.box.read(copyPath) == ".a { color: red; }\n")
        let fileMode = try FileManager.default.attributesOfItem(atPath: copyPath)[.posixPermissions] as? Int
        #expect(fileMode == 0o600)
        let manifest = run.box.read(folder.appendingPathComponent("manifest.json").path) ?? ""
        #expect(manifest.contains("a.css"))
    }

    @Test("a run that changes nothing leaves no backup folder")
    func noBackupWhenNothingChanges() throws {
        let run = try Run()
        defer { run.box.cleanUp() }
        #expect(run.guarded.review(toolName: "Read", input: InstantInput.read(run.app + "/x")) == .allow)
        #expect(!run.box.exists(run.box.backups.path))
    }
}
