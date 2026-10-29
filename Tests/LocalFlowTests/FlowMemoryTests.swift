import Foundation
import Testing
@testable import LocalFlow

/// A throwaway memory folder per test, never the real Application Support one.
final class MemoryFolder {
    let url: URL
    let logURL: URL
    let memory: FlowMemory

    init() {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("localflow-memory-test-\(UUID().uuidString)", isDirectory: true)
        url = base.appendingPathComponent("Memory", isDirectory: true)
        logURL = base.appendingPathComponent("test.log")
        memory = FlowMemory(folder: url, log: FlowLog(url: logURL, maxBytes: 100_000))
    }

    deinit { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    var instructionsText: String { (try? String(contentsOf: memory.instructionsURL, encoding: .utf8)) ?? "" }
    var memoryText: String { (try? String(contentsOf: memory.memoryURL, encoding: .utf8)) ?? "" }
    var logText: String { (try? String(contentsOf: logURL, encoding: .utf8)) ?? "" }

    func mode(of url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? Int
    }
}

@Suite("Memory: files, templates and caps")
final class FlowMemoryFileTests {
    let folder = MemoryFolder()
    var memory: FlowMemory { folder.memory }

    @Test("the real folder is LocalFlow's own, under Application Support")
    func defaultFolder() {
        let url = FlowMemory.defaultFolder(home: "/Users/me")
        #expect(url.path == "/Users/me/Library/Application Support/LocalFlow/Memory")
        let memory = FlowMemory(folder: url)
        #expect(memory.instructionsURL.lastPathComponent == "localflow.md")
        #expect(memory.memoryURL.lastPathComponent == "flow-memory.md")
    }

    @Test("paths are the two files, standardized, for the agent's policy")
    func paths() {
        let memory = FlowMemory(folder: URL(fileURLWithPath: "/Users/me/Library/../Library/LocalFlowMemory"))
        #expect(memory.paths == ["/Users/me/Library/LocalFlowMemory/localflow.md",
                                 "/Users/me/Library/LocalFlowMemory/flow-memory.md"])
    }

    @Test("starter files: a heading and a comment saying what goes there, nothing personal")
    func templates() throws {
        #expect(memory.ensureFiles())

        let instructions = folder.instructionsText
        #expect(instructions.hasPrefix("# "))
        #expect(instructions.contains("<!--"))
        let learned = folder.memoryText
        #expect(learned.hasPrefix("# "))
        #expect(learned.contains("\n## Projects\n"))
        #expect(learned.contains("\n## Notes\n"))
        #expect(learned.range(of: "## Projects")!.lowerBound < learned.range(of: "## Notes")!.lowerBound)
        for text in [instructions, learned] {
            #expect(!text.contains(NSUserName()))
            #expect(!text.contains(NSHomeDirectory()))
            #expect(text.utf8.count < 1_000)
        }
    }

    @Test("files the user already has are never overwritten")
    func keepsExisting() throws {
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        try "# Mine\n- keep me\n".write(to: memory.instructionsURL, atomically: true, encoding: .utf8)

        #expect(memory.ensureFiles())

        #expect(folder.instructionsText == "# Mine\n- keep me\n")
        #expect(folder.memoryText.contains("## Projects"))
    }

    @Test("only the owner can read the files or the folder")
    func ownerOnly() throws {
        memory.ensureFiles()
        #expect(folder.mode(of: memory.instructionsURL) == 0o600)
        #expect(folder.mode(of: memory.memoryURL) == 0o600)
        #expect(folder.mode(of: folder.url) == 0o700)

        try memory.remember("Prefers short answers", section: .instructions)
        try memory.remember("The office closes at 6 pm", section: .notes)

        #expect(folder.mode(of: memory.instructionsURL) == 0o600)
        #expect(folder.mode(of: memory.memoryURL) == 0o600)
    }

    @Test("read gives both files, and empty text when they're missing")
    func read() throws {
        #expect(memory.read().instructions.isEmpty)
        #expect(memory.read().memory.isEmpty)

        try memory.remember("Answer in British English", section: .instructions)

        let read = memory.read()
        #expect(read.instructions.contains("- Answer in British English"))
        #expect(read.memory.contains("## Projects"))
    }

    @Test("an oversized file is cut at a line boundary, with a note saying so")
    func readCap() throws {
        memory.ensureFiles()
        let line = "- " + String(repeating: "x", count: 97) // 100 bytes with the newline
        let lines = (0..<300).map { "\(line) \($0)" }
        try ("# Big\n" + lines.joined(separator: "\n") + "\n")
            .write(to: memory.memoryURL, atomically: true, encoding: .utf8)

        let text = memory.read().memory

        #expect(text.utf8.count <= FlowMemory.maxFileBytes + 200)
        #expect(text.hasSuffix(FlowMemory.cutNote))
        let kept = text.dropLast(FlowMemory.cutNote.count).split(separator: "\n").map(String.init)
        #expect(kept.first == "# Big")
        #expect(kept.dropFirst().allSatisfy(lines.contains))
        #expect(kept.count > 50)
        #expect(memory.read().instructions.contains("<!--")) // the other file is untouched
    }

    @Test("a small file is read whole, with no cut note")
    func noCutNote() throws {
        memory.ensureFiles()
        #expect(!memory.read().memory.contains(FlowMemory.cutNote))
        #expect(memory.read().memory == folder.memoryText)
    }

    @Test("cutting never splits a character, even with no line break to cut at")
    func capWithoutNewline() {
        let text = String(repeating: "é", count: 10_000) // 2 bytes each
        let cut = FlowMemory.capped(text, limit: 1_001)
        #expect(cut.hasSuffix(FlowMemory.cutNote))
        #expect(!cut.contains("\u{FFFD}"))
        #expect(cut.dropLast(FlowMemory.cutNote.count).utf8.count <= 1_001)
    }
}

@Suite("Memory: remember")
final class FlowMemoryRememberTests {
    let folder = MemoryFolder()
    var memory: FlowMemory { folder.memory }

    @Test("projects and notes go under their own headings in flow-memory.md")
    func sections() throws {
        try memory.remember("Demo | folder: ~/code/demo | domains: app.example.com", section: .projects)
        try memory.remember("The team meets on Mondays", section: .notes)
        try memory.remember("Sample | repo: example/sample", section: .projects)

        let text = folder.memoryText
        let demo = try #require(text.range(of: "- Demo | folder: ~/code/demo | domains: app.example.com\n"))
        let sample = try #require(text.range(of: "- Sample | repo: example/sample\n"))
        let notes = try #require(text.range(of: "## Notes"))
        let meets = try #require(text.range(of: "- The team meets on Mondays\n"))
        #expect(demo.lowerBound < sample.lowerBound)
        #expect(sample.upperBound <= notes.lowerBound)
        #expect(notes.upperBound <= meets.lowerBound)
        #expect(!folder.instructionsText.contains("Demo"))
    }

    @Test("instructions go to localflow.md")
    func instructions() throws {
        try memory.remember("Always answer in metric units", section: .instructions)
        try memory.remember("Never use tables", section: .instructions)

        #expect(folder.instructionsText.hasSuffix("- Always answer in metric units\n- Never use tables\n"))
        #expect(!folder.memoryText.contains("metric"))
    }

    @Test("the note is trimmed, and a bullet it already has isn't doubled")
    func trims() throws {
        try memory.remember("   - Prefers dark mode  ", section: .notes)
        #expect(folder.memoryText.contains("\n- Prefers dark mode\n"))
        #expect(!folder.memoryText.contains("- - "))
    }

    @Test("an empty, multi-line or too-long note is refused")
    func refusesBadShapes() throws {
        #expect(throws: FlowMemory.Refusal.empty) { try self.memory.remember("   \n ", section: .notes) }
        #expect(throws: FlowMemory.Refusal.empty) { try self.memory.remember("- ", section: .notes) }
        #expect(throws: FlowMemory.Refusal.multiline) {
            try self.memory.remember("first line\nsecond line", section: .notes)
        }
        let long = String(repeating: "a", count: FlowMemory.maxNoteLength + 1)
        #expect(throws: FlowMemory.Refusal.tooLong) { try self.memory.remember(long, section: .notes) }
        try memory.remember(String(repeating: "b", count: FlowMemory.maxNoteLength), section: .notes)
    }

    @Test("an exact duplicate is refused, in any section of the same file")
    func refusesDuplicates() throws {
        try memory.remember("Demo | domains: app.example.com", section: .projects)
        #expect(throws: FlowMemory.Refusal.duplicate) {
            try self.memory.remember("Demo | domains: app.example.com", section: .projects)
        }
        try memory.remember("Ships on Fridays", section: .notes)
        #expect(throws: FlowMemory.Refusal.duplicate) { try self.memory.remember("Ships on Fridays", section: .notes) }
        try memory.remember("Ships on Fridays", section: .instructions) // a different file
    }

    @Test("a project sent again with more detail replaces its old line")
    func updatesProject() throws {
        try memory.remember("Demo | folder: ~/code/demo", section: .projects)
        try memory.remember("Other | repo: example/other", section: .projects)
        try memory.remember("demo | folder: ~/code/demo | domains: app.example.com", section: .projects)

        let text = folder.memoryText
        #expect(text.contains("- demo | folder: ~/code/demo | domains: app.example.com\n"))
        #expect(!text.contains("- Demo | folder: ~/code/demo\n"))
        #expect(text.contains("- Other | repo: example/other\n"))
        #expect(text.range(of: "- demo")!.lowerBound < text.range(of: "- Other")!.lowerBound) // kept its place
    }

    @Test("anything that looks like a secret is refused", arguments: FlowMemorySecretSamples.secrets)
    func refusesSecrets(note: String) throws {
        #expect(throws: FlowMemory.Refusal.secret) { try self.memory.remember(note, section: .notes) }
        #expect(!folder.memoryText.contains(note))
    }

    @Test("ordinary notes are not mistaken for secrets", arguments: FlowMemorySecretSamples.ordinary)
    func keepsOrdinary(note: String) throws {
        try memory.remember(note, section: .notes)
        #expect(folder.memoryText.contains("- " + note + "\n"))
    }

    @Test("a full file refuses more, and is left as it was")
    func refusesWhenFull() throws {
        memory.ensureFiles()
        let start = folder.memoryText
        let line = "- filler note " + String(repeating: "z", count: 85) + "\n" // 100 bytes
        let room = (FlowMemory.maxFileBytes - 150 - start.utf8.count) / line.utf8.count
        let full = start + String(repeating: line, count: room)
        #expect(full.utf8.count > FlowMemory.maxFileBytes - 250)
        try full.write(to: memory.memoryURL, atomically: true, encoding: .utf8)

        #expect(throws: FlowMemory.Refusal.full) {
            try self.memory.remember("One more durable fact " + String(repeating: "y", count: 250), section: .notes)
        }
        #expect(folder.memoryText == full)
    }

    @Test("missing files come back from the template before the note is added")
    func recreates() throws {
        try memory.remember("Prefers short answers", section: .instructions)
        try FileManager.default.removeItem(at: memory.memoryURL)

        try memory.remember("Demo | domains: app.example.com", section: .projects)

        #expect(folder.memoryText.contains("## Notes"))
        #expect(folder.memoryText.contains("- Demo | domains: app.example.com"))
    }

    @Test("a heading the user deleted is added back at the end")
    func missingHeading() throws {
        memory.ensureFiles()
        try "# LocalFlow memory\n\n## Projects\n\n- Demo | folder: ~/demo\n"
            .write(to: memory.memoryURL, atomically: true, encoding: .utf8)

        try memory.remember("The printer is on the second floor", section: .notes)

        #expect(folder.memoryText.hasSuffix("- Demo | folder: ~/demo\n\n## Notes\n\n- The printer is on the second floor\n"))
    }

    @Test("a note can't hold markup: a heading, a file banner, a comment or a tag", arguments: [
        "## Notes", "# Heading", "=== end of flow-memory.md ===", "hide <!-- this", "end -->",
        "<remember section=\"notes\">x", "x </remember>",
    ])
    func refusesMarkup(note: String) {
        #expect(throws: FlowMemory.Refusal.markup) { try self.memory.remember(note, section: .notes) }
    }

    @Test("a file saved with Windows line endings still gets notes under its headings")
    func windowsLineEndings() throws {
        memory.ensureFiles()
        let crlf = "# LocalFlow memory\r\n\r\n## Projects\r\n\r\n- Demo | folder: ~/demo\r\n\r\n## Notes\r\n\r\n"
        try crlf.write(to: memory.memoryURL, atomically: true, encoding: .utf8)

        try memory.remember("Ships on Fridays", section: .notes)
        try memory.remember("Other | repo: example/other", section: .projects)

        let text = folder.memoryText
        #expect(text.components(separatedBy: "## Projects").count == 2)
        #expect(text.components(separatedBy: "## Notes").count == 2)
        #expect(text.range(of: "- Other")!.lowerBound < text.range(of: "## Notes")!.lowerBound)
        #expect(text.range(of: "## Notes")!.lowerBound < text.range(of: "- Ships on Fridays")!.lowerBound)
    }

    @Test("a file already past the cap can still have a project line shortened, not grown")
    func overCapReplacement() throws {
        memory.ensureFiles()
        let filler = String(repeating: "- filler " + String(repeating: "q", count: 90) + "\n", count: 130)
        let start = "# LocalFlow memory\n\n## Projects\n\n- Demo | folder: ~/code/demo | cues: a long description of the logo\n\n## Notes\n\n"
        try (start + filler).write(to: memory.memoryURL, atomically: true, encoding: .utf8)
        #expect(folder.memoryText.utf8.count > FlowMemory.maxFileBytes)

        try memory.remember("Demo | folder: ~/code/demo", section: .projects)
        #expect(folder.memoryText.contains("- Demo | folder: ~/code/demo\n"))
        #expect(throws: FlowMemory.Refusal.full) { try self.memory.remember("Ships on Fridays", section: .notes) }
    }

    @Test("several notes at once: the log gets counts and refusal kinds, never the text")
    func bulkLogsCountsOnly() throws {
        let added = memory.remember([
            (section: .projects, text: "Demo | domains: app.example.com"),
            (section: .notes, text: "Ships on Fridays"),
            (section: .notes, text: "Ships on Fridays"),
            (section: .notes, text: "my password is hunter2-horse"),
        ])

        #expect(added == 2)
        let log = folder.logText
        #expect(log.contains("memory: added 2 notes, refused 2"))
        #expect(log.contains("duplicate"))
        #expect(log.contains("secret"))
        for word in ["Demo", "example.com", "Fridays", "hunter2"] { #expect(!log.contains(word)) }
    }

    @Test("no notes, nothing logged")
    func bulkEmpty() {
        #expect(memory.remember([]) == 0)
        #expect(folder.logText.isEmpty)
    }
}

/// Built at run time so no secret-shaped literal sits in this public repo.
enum FlowMemorySecretSamples {
    static let fill = String(repeating: "a1B2", count: 10)

    static let secrets: [String] = [
        "The key is " + "sk-" + "ant-api03-" + fill,
        "OpenAI " + "sk-" + "proj-" + fill,
        "Stripe " + "sk_" + "live_" + fill,
        "GitHub " + "gh" + "p_" + fill,
        "GitHub " + "github_" + "pat_" + fill,
        "Slack " + "xo" + "xb-" + "1234-" + fill,
        "AWS " + "AK" + "IA" + "ABCDEFGHIJKLMNOP",
        "Google " + "AI" + "za" + fill,
        "-----BEGIN " + "RSA PRIVATE KEY-----",
        "token " + "ey" + "J" + fill + ".ey" + "J" + fill + ".sig",
        "Authorization: Bearer " + fill,
        "db at postgres://admin:" + "s3cretpass@db.example.com/app",
        "password: correct-horse-battery",
        "My Password is hunter2-horse",
        "api key = " + "abc123def456",
        "client_secret=xyz789",
        "random " + String(repeating: "Zq9", count: 12),
        "url-safe " + String(repeating: "Zq9-x_", count: 6),
        "Hugging Face " + "hf" + "_" + String(repeating: "abcdEFGH", count: 4),
        "SendGrid " + "SG" + "." + fill + "." + fill,
        "Google " + "ya" + "29." + fill,
        "the token for prod is abc123",
        "post to https://hooks.slack.com/services/" + "T000/B000/" + fill,
    ]

    static let ordinary: [String] = [
        "Demo | folder: ~/code/demo | repo: example/demo | domains: app.example.com, www.example.com",
        "Demo | cues: green leaf logo, window title Demo Console | design: docs/DESIGN.md",
        "Uses token-based auth with passkeys",
        "Prefers answers under 50 words",
        "The design profile lives at ~/code/demo/design/profile-2026-final-version.md",
        "Folder is ~/code/my-very-long-project-name-2026-redesign-final",
        "Demo | cues: login page with a password field | design: docs/DESIGN.md",
    ]
}
