import Foundation
import Testing
@testable import LocalFlow

@MainActor
@Suite("Instant Edits: reading and changing files")
struct InstantGuardFileTests {
    private func makeGuard(_ box: InstantSandbox, _ projects: [String],
                           limits: InstantLimits = .standard) -> InstantGuard {
        InstantGuard(projects: projects, home: box.home, limits: limits, backupFolder: box.backups)
    }

    // MARK: Reading

    @Test("Read, Glob and Grep work inside the projects")
    func readsInside() throws {
        let box = try InstantSandbox()
        defer { box.cleanUp() }
        let app = try box.project()
        let file = try box.write("body { color: red; }\n", to: app + "/src/app.css")
        let guarded = makeGuard(box, [app])
        #expect(guarded.review(toolName: "Read", input: InstantInput.read(file)) == .allow)
        #expect(guarded.review(toolName: "Read", input: InstantInput.read(app + "/DESIGN.md")) == .allow)
        #expect(guarded.review(toolName: "Glob", input: ["pattern": "**/*.css", "path": .string(app)]) == .allow)
        #expect(guarded.review(toolName: "Glob", input: ["pattern": .string(app + "/src/**/*.tsx")]) == .allow)
        #expect(guarded.review(toolName: "Grep", input: ["pattern": "Save", "path": .string(app + "/src")]) == .allow)
    }

    @Test("reading anywhere else is refused")
    func readsOutside() throws {
        let box = try InstantSandbox()
        defer { box.cleanUp() }
        let app = try box.project()
        let other = try box.project("other")
        let secret = try box.write("token", to: other + "/notes.txt")
        try FileManager.default.createSymbolicLink(atPath: app + "/link", withDestinationPath: other)
        let guarded = makeGuard(box, [app])
        let outside = ["/etc/hosts", box.home + "/.zshrc", secret, app + "/../other/notes.txt", app + "/link/notes.txt",
                       "src/app.css", "~/.ssh/id_rsa"]
        for path in outside {
            #expect(!guarded.review(toolName: "Read", input: InstantInput.read(path)).isAllowed, "\(path)")
        }
        #expect(!guarded.review(toolName: "Glob", input: ["pattern": "**/*"]).isAllowed)
        #expect(!guarded.review(toolName: "Glob", input: ["pattern": "*", "path": .string(other)]).isAllowed)
        #expect(!guarded.review(toolName: "Glob", input: ["pattern": "/etc/*"]).isAllowed)
        #expect(!guarded.review(toolName: "Glob", input: ["pattern": "../**", "path": .string(app)]).isAllowed)
        #expect(!guarded.review(toolName: "Grep", input: ["pattern": "x"]).isAllowed)
        #expect(!guarded.review(toolName: "Grep", input: ["pattern": "x", "path": "/"]).isAllowed)
    }

    @Test("reads stay cheap: no generated folders, secrets or huge files; images are fine")
    func cheapReads() throws {
        let box = try InstantSandbox()
        defer { box.cleanUp() }
        let app = try box.project()
        let vendored = try box.write("x", to: app + "/node_modules/react/index.js")
        let built = try box.write("x", to: app + "/dist/main.js")
        let env = try box.write("KEY=1", to: app + "/.env.local")
        let huge = try box.write(String(repeating: "a\n", count: 600_000), to: app + "/data/big.txt")
        let icon = try box.writeData(Data([0x89, 0x50, 0x4E, 0x47, 0x00]), to: app + "/public/icon.png")
        let guarded = makeGuard(box, [app])
        for path in [vendored, built, env, huge] {
            #expect(!guarded.review(toolName: "Read", input: InstantInput.read(path)).isAllowed, "\(path)")
        }
        #expect(guarded.review(toolName: "Read", input: InstantInput.read(icon)) == .allow)
        #expect(!guarded.review(toolName: "Grep", input: ["pattern": "x", "path": .string(app + "/node_modules")]).isAllowed)
        #expect(!guarded.review(toolName: "Glob", input: ["pattern": "*.js", "path": .string(app + "/dist")]).isAllowed)
    }

    @Test("a path with .. is refused, since through a link it reads two ways")
    func dotDotThroughLink() throws {
        let box = try InstantSandbox()
        defer { box.cleanUp() }
        let app = try box.project()
        let other = try box.project("other")
        try FileManager.default.createDirectory(atPath: other + "/dir", withIntermediateDirectories: true)
        try box.write("theirs\n", to: other + "/notes.txt")
        try box.write("ours\n", to: app + "/notes.txt")
        try FileManager.default.createSymbolicLink(atPath: app + "/link", withDestinationPath: other + "/dir")
        let guarded = makeGuard(box, [app])
        // Read as text this is app/notes.txt; the system follows the link first and reaches other/notes.txt.
        let twoWays = app + "/link/../notes.txt"
        #expect(!guarded.review(toolName: "Read", input: InstantInput.read(twoWays)).isAllowed)
        #expect(!guarded.review(toolName: "Edit", input: InstantInput.edit(twoWays, "ours", "mine")).isAllowed)
        #expect(!guarded.review(toolName: "Bash", input: InstantInput.bash("cat " + twoWays)).isAllowed)
        #expect(!guarded.review(toolName: "Read", input: InstantInput.read(app + "/src/../notes.txt")).isAllowed)
    }

    // MARK: Edit

    @Test("a small edit inside a project is allowed and remembered")
    func editAllowed() throws {
        let box = try InstantSandbox()
        defer { box.cleanUp() }
        let app = try box.project()
        let file = try box.write(".save { color: red; }\n", to: app + "/src/app.css")
        let guarded = makeGuard(box, [app])
        #expect(guarded.review(toolName: "Edit", input: InstantInput.edit(file, "color: red", "color: blue")) == .allow)
        #expect(!guarded.hasChanges) // nothing has changed on disk yet
        try box.write(".save { color: blue; }\n", to: file)
        #expect(guarded.changedFiles == ["app.css"])
        #expect(guarded.hasChanges)
    }

    @Test("edits outside the projects are refused, however the path is spelled")
    func editOutside() throws {
        let box = try InstantSandbox()
        defer { box.cleanUp() }
        let app = try box.project()
        let other = try box.project("other")
        let target = try box.write("x = 1\n", to: other + "/main.py")
        try FileManager.default.createSymbolicLink(atPath: app + "/out", withDestinationPath: other)
        try FileManager.default.createSymbolicLink(atPath: app + "/main.py", withDestinationPath: target)
        let guarded = makeGuard(box, [app])
        let paths = ["/etc/hosts", target, app + "/../other/main.py", app + "/out/main.py", app + "/main.py",
                     "main.py", box.home + "/.zshrc"]
        for path in paths {
            let decision = guarded.review(toolName: "Edit", input: InstantInput.edit(path, "x = 1", "x = 2"))
            #expect(!decision.isAllowed, "\(path)")
        }
        #expect(!guarded.hasChanges)
    }

    @Test("a file hard-linked to one elsewhere can't be edited")
    func hardLink() throws {
        let box = try InstantSandbox()
        defer { box.cleanUp() }
        let app = try box.project()
        let outside = try box.write("a { color: red; }\n", to: box.home + "/shared.css")
        try FileManager.default.linkItem(atPath: outside, toPath: app + "/shared.css")
        let guarded = makeGuard(box, [app])
        let decision = guarded.review(toolName: "Edit", input: InstantInput.edit(app + "/shared.css", "red", "blue"))
        #expect(!decision.isAllowed)
    }

    @Test("build output, dependencies, git internals, lockfiles, secrets and binaries are off limits", arguments: [
        ".git/config", "node_modules/react/index.js", "build/app.js", "dist/main.css", ".build/x.swift",
        "DerivedData/x.swift", ".next/page.js", "Pods/A/a.m", "vendor/lib.rb", "package-lock.json", "yarn.lock",
        "pnpm-lock.yaml", "bun.lockb", "Package.resolved", "Podfile.lock", "Cargo.lock", "Gemfile.lock", "poetry.lock",
        "composer.lock", ".env", ".env.local", ".envrc", "certs/server.pem", "keys/app.key", "id_rsa", "cert.p12",
        "config/secrets.json", "credentials.json", "public/logo.png", "assets/font.woff2",
        // Agent, editor and git-hook settings run code or steer agents the next time they open.
        ".claude/settings.json", ".claude/settings.local.json", ".claude/commands/ship.md", ".mcp.json",
        ".vscode/tasks.json", ".vscode/settings.json", ".idea/workspace.xml", ".husky/pre-commit",
        ".pre-commit-config.yaml", "lefthook.yml", "CLAUDE.md", "docs/AGENTS.md", "GEMINI.md", ".cursorrules",
        ".cursor/rules/ui.mdc", ".windsurfrules", ".clinerules", ".devcontainer/devcontainer.json",
    ])
    func refusedPlaces(relative: String) throws {
        let box = try InstantSandbox()
        defer { box.cleanUp() }
        let app = try box.project()
        let file = try box.write("color = red\n", to: app + "/" + relative)
        let guarded = makeGuard(box, [app])
        let decision = guarded.review(toolName: "Edit", input: InstantInput.edit(file, "red", "blue"))
        #expect(!decision.isAllowed, "\(relative)")
    }

    @Test("a file that isn't text can't be edited, whatever its name")
    func binaryContent() throws {
        let box = try InstantSandbox()
        defer { box.cleanUp() }
        let app = try box.project()
        let file = try box.writeData(Data([0x63, 0x6F, 0x00, 0x6C, 0xFF, 0x00]), to: app + "/data.txt")
        let guarded = makeGuard(box, [app])
        #expect(!guarded.review(toolName: "Edit", input: InstantInput.edit(file, "co", "do")).isAllowed)
    }

    @Test("the file must exist and be at most 1 MB")
    func fileSize() throws {
        let box = try InstantSandbox()
        defer { box.cleanUp() }
        let app = try box.project()
        let big = try box.write(String(repeating: "a = 1\n", count: 200_000), to: app + "/big.swift")
        let guarded = makeGuard(box, [app])
        #expect(!guarded.review(toolName: "Edit", input: InstantInput.edit(big, "a = 1", "a = 2")).isAllowed)
        #expect(!guarded.review(toolName: "Edit", input: InstantInput.edit(app + "/missing.swift", "a", "b")).isAllowed)
    }

    @Test("edit text must be present and short")
    func editText() throws {
        let box = try InstantSandbox()
        defer { box.cleanUp() }
        let app = try box.project()
        let file = try box.write("let title = \"Save\"\n", to: app + "/View.swift")
        let guarded = makeGuard(box, [app])
        let long = String(repeating: "x", count: 6_001)
        #expect(!guarded.review(toolName: "Edit", input: InstantInput.edit(file, "", "x")).isAllowed)
        #expect(!guarded.review(toolName: "Edit", input: InstantInput.edit(file, long, "x")).isAllowed)
        #expect(!guarded.review(toolName: "Edit", input: InstantInput.edit(file, "Save", long)).isAllowed)
        #expect(!guarded.review(toolName: "Edit", input: ["file_path": .string(file)]).isAllowed)
        #expect(guarded.review(toolName: "Edit", input: InstantInput.edit(file, "Save", "Submit")) == .allow)
    }

    @Test("replace_all is only for a few places")
    func replaceAll() throws {
        let box = try InstantSandbox()
        defer { box.cleanUp() }
        let app = try box.project()
        let few = try box.write(String(repeating: "color: red;\n", count: 20), to: app + "/few.css")
        let many = try box.write(String(repeating: "color: red;\n", count: 21), to: app + "/many.css")
        let guarded = makeGuard(box, [app])
        #expect(guarded.review(toolName: "Edit", input: InstantInput.edit(few, "red", "blue", replaceAll: true)) == .allow)
        let decision = guarded.review(toolName: "Edit", input: InstantInput.edit(many, "red", "blue", replaceAll: true))
        #expect(!decision.isAllowed)
    }

    // MARK: Write

    @Test("Write makes new files only, and Undo knows to delete them")
    func writeNew() throws {
        let box = try InstantSandbox()
        defer { box.cleanUp() }
        let app = try box.project()
        let existing = try box.write("a {}\n", to: app + "/src/a.css")
        let guarded = makeGuard(box, [app])
        let fresh = app + "/src/badge.css"
        #expect(guarded.review(toolName: "Write", input: InstantInput.write(fresh, ".badge { color: red; }\n")) == .allow)
        let over = guarded.review(toolName: "Write", input: InstantInput.write(existing, "b {}\n"))
        #expect(over.message?.contains("Use Edit") == true)
        try box.write(".badge { color: red; }\n", to: fresh)
        #expect(guarded.changedFiles == ["badge.css"])
        let undone = guarded.undo()
        #expect(undone.deleted == 1)
        #expect(!box.exists(fresh))
        #expect(box.read(existing) == "a {}\n")
    }

    @Test("Write is refused when too long, outside, in a new folder or a protected place")
    func writeRefused() throws {
        let box = try InstantSandbox()
        defer { box.cleanUp() }
        let app = try box.project()
        try box.write("x\n", to: app + "/src/keep.css")
        let guarded = makeGuard(box, [app])
        let long = String(repeating: "a", count: 4_001)
        #expect(!guarded.review(toolName: "Write", input: InstantInput.write(app + "/src/new.css", long)).isAllowed)
        #expect(!guarded.review(toolName: "Write", input: InstantInput.write("/tmp/new.css", "a")).isAllowed)
        #expect(!guarded.review(toolName: "Write", input: InstantInput.write(app + "/fresh/new.css", "a")).isAllowed)
        #expect(!guarded.review(toolName: "Write", input: InstantInput.write(app + "/.env.production", "A=1")).isAllowed)
        #expect(!guarded.review(toolName: "Write", input: InstantInput.write(app + "/src/icon.png", "a")).isAllowed)
        #expect(!guarded.review(toolName: "Write", input: ["file_path": .string(app + "/src/x.css")]).isAllowed)
    }

    // MARK: Budget

    @Test("changed lines across the run are capped")
    func lineBudget() throws {
        let box = try InstantSandbox()
        defer { box.cleanUp() }
        let app = try box.project()
        let file = try box.write(instantLines(30), to: app + "/Values.swift")
        let guarded = makeGuard(box, [app], limits: InstantLimits(maxChangedLines: 3))
        #expect(guarded.review(toolName: "Edit", input: InstantInput.edit(file, "value1 = 1", "value1 = 9")) == .allow)
        let two = "let value2 = 2\nlet value3 = 3"
        #expect(guarded.review(toolName: "Edit", input: InstantInput.edit(file, two, two + " ")) == .allow)
        let over = guarded.review(toolName: "Edit", input: InstantInput.edit(file, "value4 = 4", "value4 = 8"))
        #expect(over.message?.contains("limit reached") == true)
    }

    @Test("changed files across the run are capped")
    func fileBudget() throws {
        let box = try InstantSandbox()
        defer { box.cleanUp() }
        let app = try box.project()
        let guarded = makeGuard(box, [app], limits: InstantLimits(maxFiles: 2))
        let files = try (1...3).map { try box.write("a { color: red; }\n", to: app + "/s\($0).css") }
        #expect(guarded.review(toolName: "Edit", input: InstantInput.edit(files[0], "red", "blue")) == .allow)
        #expect(guarded.review(toolName: "Edit", input: InstantInput.edit(files[1], "red", "blue")) == .allow)
        #expect(guarded.review(toolName: "Edit", input: InstantInput.edit(files[0], "a {", "b {")) == .allow)
        let over = guarded.review(toolName: "Edit", input: InstantInput.edit(files[2], "red", "blue"))
        #expect(over.message?.contains("limit reached") == true)
        let write = guarded.review(toolName: "Write", input: InstantInput.write(app + "/s4.css", "a {}\n"))
        #expect(write.message?.contains("limit reached") == true)
    }

    // MARK: LocalFlow's memory

    @Test("LocalFlow's memory files can be read and noted in, and Undo leaves them be")
    func memory() throws {
        let box = try InstantSandbox()
        defer { box.cleanUp() }
        let app = try box.project()
        let folder = box.home + "/Library/Application Support/LocalFlow"
        let notes = try box.write("# Projects\n- Sundial: ~/code/sundial\n", to: folder + "/memory.md")
        let fresh = folder + "/projects.json"
        let neighbor = try box.write("{}\n", to: folder + "/settings.json")
        let guarded = InstantGuard(projects: [app], memoryPaths: [notes, fresh], home: box.home,
                                   backupFolder: box.backups)
        #expect(guarded.review(toolName: "Read", input: InstantInput.read(notes)) == .allow)
        let line = "- Invoices: ~/code/invoices, domain invoices.example.com\n"
        #expect(guarded.review(toolName: "Edit", input: InstantInput.edit(notes, "# Projects\n", "# Projects\n" + line)) == .allow)
        #expect(guarded.review(toolName: "Write", input: InstantInput.write(fresh, "{\"projects\": []}\n")) == .allow)
        #expect(!guarded.review(toolName: "Edit", input: InstantInput.edit(neighbor, "{}", "{\"a\":1}")).isAllowed)
        #expect(!guarded.review(toolName: "Read", input: InstantInput.read(neighbor)).isAllowed)
        try box.write("# Projects\n" + line + "- Sundial: ~/code/sundial\n", to: notes)
        try box.write("{\"projects\": []}\n", to: fresh)
        #expect(guarded.changedFiles.isEmpty)
        #expect(guarded.undo() == InstantUndoResult(restored: 0, deleted: 0, failed: 0))
        #expect(box.read(notes)?.contains("Invoices") == true)
        #expect(box.exists(fresh))
    }

    @Test("a memory file that the run emptied is put back")
    func memoryProtected() throws {
        let box = try InstantSandbox()
        defer { box.cleanUp() }
        let app = try box.project()
        let notes = try box.write(instantLines(40), to: box.home + "/memory.md")
        let guarded = InstantGuard(projects: [app], memoryPaths: [notes], home: box.home, backupFolder: box.backups)
        #expect(guarded.review(toolName: "Edit", input: InstantInput.edit(notes, "value1 = 1", "value1 = 2")) == .allow)
        try box.write("", to: notes)
        #expect(guarded.verifyAfterRun() == ["memory.md"])
        #expect(box.read(notes) == instantLines(40))
    }

    // MARK: Other tools

    @Test("looking at the screen is fine; acting on it isn't", arguments: ["screenshot", "list_apps", "wait"])
    func screenLooks(action: String) throws {
        let box = try InstantSandbox()
        defer { box.cleanUp() }
        let guarded = makeGuard(box, [try box.project()])
        #expect(guarded.review(toolName: "mcp__localflow__" + action, input: [:]) == .allow)
    }

    @Test("screen actions are refused", arguments: ["click", "type", "key", "drag", "scroll", "move", "open_app"])
    func screenActs(action: String) throws {
        let box = try InstantSandbox()
        defer { box.cleanUp() }
        let guarded = makeGuard(box, [try box.project()])
        let decision = guarded.review(toolName: "mcp__localflow__" + action, input: ["x": 1, "y": 2])
        #expect(decision.message?.contains("only changes code") == true)
    }

    @Test("every other tool is refused with a reason", arguments: [
        "NotebookEdit", "Task", "WebFetch", "WebSearch", "Monitor", "TaskStop", "ToolSearch", "TodoWrite",
        "MultiEdit", "mcp__github__create_pull_request", "SomethingNew",
    ])
    func otherTools(tool: String) throws {
        let box = try InstantSandbox()
        defer { box.cleanUp() }
        let guarded = makeGuard(box, [try box.project()])
        let message = guarded.review(toolName: tool, input: [:]).message
        #expect(message?.isEmpty == false)
    }

    @Test("refusals are short and say what to do instead")
    func refusalWording() throws {
        let box = try InstantSandbox()
        defer { box.cleanUp() }
        let app = try box.project()
        let file = try box.write("a { color: red; }\n", to: app + "/a.css")
        let guarded = makeGuard(box, [app])
        let refusals: [InstantDecision] = [
            guarded.review(toolName: "Read", input: InstantInput.read("/etc/hosts")),
            guarded.review(toolName: "Edit", input: InstantInput.edit(app + "/.env", "a", "b")),
            guarded.review(toolName: "Write", input: InstantInput.write(file, "b")),
            guarded.review(toolName: "Bash", input: InstantInput.bash("npm test")),
            guarded.review(toolName: "mcp__localflow__click", input: [:]),
            guarded.review(toolName: "WebFetch", input: [:]),
        ]
        for refusal in refusals {
            let message = try #require(refusal.message)
            #expect(message.count <= 260, "\(message)")
        }
    }
}
