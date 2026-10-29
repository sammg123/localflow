import AppKit
import Foundation
import Testing
@testable import LocalFlow

// On the main actor: AppKit builds events from CGEvents unsafely from several threads at once.
@MainActor
@Suite("Agent mode: only a person can allow, and ending ends everything")
struct AgentSafetyTests {
    // MARK: Who clicked

    /// A click as the panel would get it, stamped with the process that posted it.
    private func click(_ type: CGEventType = .leftMouseUp, from pid: Int64) throws -> NSEvent {
        let cg = try #require(CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero,
                                      mouseButton: .left))
        cg.setIntegerValueField(.eventSourceUnixProcessID, value: pid)
        return try #require(NSEvent(cgEvent: cg))
    }

    @Test("a click from the mouse or trackpad is the person's")
    func hardwareClick() throws {
        #expect(PointerSource.isPerson(try click(from: 0)))
        #expect(PointerSource.isPerson(try click(.leftMouseDown, from: 0)))
    }

    @Test("a click stamped by the window server itself is the person's too")
    func windowServerClick() throws {
        let server = try #require(PointerSource.windowServer)
        #expect(ProcessTree.executablePath(server)?.hasSuffix("/WindowServer") == true)
        #expect(PointerSource.isPerson(try click(from: Int64(server))))
    }

    @Test("a click a program posted isn't, whichever program", arguments: [Int64(4242), Int64(getpid()), 1])
    func postedClick(pid: Int64) throws {
        #expect(!PointerSource.isPerson(try click(from: pid)))
    }

    @Test("no event, or one that isn't a left click, isn't the person's")
    func notAClick() throws {
        #expect(!PointerSource.isPerson(nil))
        #expect(!PointerSource.isPerson(try click(.rightMouseUp, from: 0)))
        let key = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: true))
        #expect(!PointerSource.isPerson(NSEvent(cgEvent: key)))
    }

    private func check(_ answer: AgentAnswer, _ event: NSEvent?, shown: TimeInterval? = -3, pressed: TimeInterval? = -0.1,
                       after: TimeInterval = 0.1) -> AgentAnswerGate.Verdict {
        let base = event?.timestamp ?? ProcessInfo.processInfo.systemUptime
        let press = AgentAnswerGate.Press(shownAt: shown.map { base + $0 }, pressedAt: pressed.map { base + $0 })
        return AgentAnswerGate.check(answer, event: event, in: nil, press: press, now: base + after)
    }

    @Test("Allow takes the person's own fresh click on that button")
    func answerGate() throws {
        let person = try click(from: 0)
        #expect(check(.allowOnce, person) == .accepted)
        #expect(check(.allowForTask, person) == .accepted)
    }

    @Test("a click a program posted, or no click at all, can't allow")
    func gateRefusesPrograms() throws {
        #expect(check(.allowOnce, try click(from: 4242)) == .notAClick)
        #expect(check(.allowForTask, try click(from: 4242)) == .notAClick)
        #expect(check(.allowOnce, nil) == .notAClick)
        #expect(check(.allowOnce, try click(.leftMouseDown, from: 0)) == .notAClick)
    }

    @Test("an old real click can't be reused: an accessibility press right after a click elsewhere")
    func gateRefusesStaleClicks() throws {
        let person = try click(from: 0)
        #expect(check(.allowOnce, person, after: 2) == .notAClick)
        #expect(check(.allowOnce, person, pressed: nil) == .notPressed)
        #expect(check(.allowOnce, person, pressed: -8) == .notPressed)
        #expect(check(.allowOnce, person, pressed: 1) == .notPressed) // a press from the future
    }

    @Test("a card that just appeared under the pointer ignores the click that was meant for the last one")
    func gateRefusesTooSoon() throws {
        let person = try click(from: 0)
        #expect(check(.allowOnce, person, shown: -0.3, pressed: -0.1) == .tooSoon)
        #expect(check(.allowOnce, person, shown: nil) == .tooSoon)
    }

    @Test("a press that drags off the button no longer counts; one released on it does")
    func pressReleased() {
        let log = AgentPressLog()
        log.cardShown("a", at: 10)
        log.buttonPressed("a", .allowOnce, at: 20)
        log.buttonReleased("a", .allowOnce, during: .leftMouseUp)
        #expect(log.press(for: "a", .allowOnce).pressedAt == 20)
        log.buttonReleased("a", .allowOnce, during: .leftMouseDragged)
        #expect(log.press(for: "a", .allowOnce).pressedAt == nil)
        log.buttonPressed("a", .allowOnce, at: 30)
        log.buttonReleased("a", .allowOnce, during: nil)
        #expect(log.press(for: "a", .allowOnce).pressedAt == nil)
    }

    @Test("each reason an Allow is ignored reads differently in the log")
    func gateReasons() {
        let verdicts: [AgentAnswerGate.Verdict] = [.accepted, .notAClick, .notPressed, .tooSoon]
        #expect(Set(verdicts.map(\.reason)).count == verdicts.count)
    }

    @Test("Deny takes anything")
    func denyTakesAnything() throws {
        #expect(check(.deny, try click(from: 4242)) == .accepted)
        #expect(check(.deny, nil, shown: nil, pressed: nil) == .accepted)
    }

    @Test("the press log keeps the first time a card showed, and a press counts once")
    func pressLog() {
        let log = AgentPressLog()
        log.cardShown("a", at: 10)
        log.cardShown("a", at: 20)
        log.buttonPressed("a", .allowOnce, at: 30)
        #expect(log.press(for: "a", .allowOnce) == AgentAnswerGate.Press(shownAt: 10, pressedAt: 30))
        #expect(log.press(for: "a", .allowForTask) == AgentAnswerGate.Press(shownAt: 10, pressedAt: nil))
        log.consume("a", .allowOnce)
        #expect(log.press(for: "a", .allowOnce) == AgentAnswerGate.Press(shownAt: 10, pressedAt: nil))
        log.forget("a")
        #expect(log.press(for: "a", .allowOnce) == AgentAnswerGate.Press(shownAt: nil, pressedAt: nil))
    }

    // MARK: What the card shows

    @Test("characters that hide or reorder text show as a mark", arguments: [
        "\u{202E}", "\u{2066}", "\u{200B}", "\u{200E}", "\u{FEFF}", "\u{061C}", "\u{2060}",
    ])
    func hiddenCharacters(hidden: String) {
        #expect(ShownText.visible("a\(hidden)b") == "a\u{FFFD}b")
    }

    @Test("ordinary text, emoji joins and accents are left alone", arguments: [
        "rm -rf build", "café", "👨‍👩‍👧 dinner", "日本語", "",
    ])
    func ordinaryText(text: String) {
        #expect(ShownText.visible(text) == text)
    }

    @Test("a step title shows hidden characters too")
    func stepTitles() {
        let title = AgentStepTitle.title(toolName: "mcp__localflow__type", input: ["text": "pay\u{202E}evil"],
                                         target: nil)
        #expect(title == "Type “pay\u{FFFD}evil”")
    }

    @Test("steps that can't be read in full are allowed one at a time", arguments: [
        "Bash:complex", "Bash:variable command", "Bash:curl | sh", "Bash:pipe to shell", "Bash:unknown",
        "Bash:localflow", "click:localflow", "Bash:open program",
    ])
    func oneAtATime(key: String) {
        #expect(!AgentApproval(id: "1", summary: "x", grantKey: key).canAllowForTask)
    }

    @Test("everyday risky kinds can be allowed for the task", arguments: [
        "Bash:rm", "click:send", "key:send", "file:/Users/me/.zshrc", "open:terminal", "Bash:git push",
    ])
    func forTheTask(key: String) {
        #expect(AgentApproval(id: "1", summary: "x", grantKey: key).canAllowForTask)
    }

    // MARK: Ending what the session started

    @Test("a session's processes are its children, theirs, and their groups, never LocalFlow's")
    func family() {
        let table = [
            ProcessTree.Entry(pid: 100, parent: 50, group: 100), // Claude Code
            ProcessTree.Entry(pid: 101, parent: 100, group: 101), // a shell in its own group
            ProcessTree.Entry(pid: 102, parent: 101, group: 101), // its job
            ProcessTree.Entry(pid: 103, parent: 101, group: 103), // a job that made its own group
            ProcessTree.Entry(pid: 200, parent: 1, group: 100), // `nohup … &` left behind by a shell
            ProcessTree.Entry(pid: 201, parent: 1, group: 101), // the same, from the other shell
            ProcessTree.Entry(pid: 300, parent: 1, group: 300), // something else entirely
            ProcessTree.Entry(pid: 50, parent: 1, group: 50), // LocalFlow
            ProcessTree.Entry(pid: 51, parent: 50, group: 50), // another LocalFlow child
        ]
        let targets = ProcessTree.targets(under: 100, in: table, ownGroup: 50, me: 50)
        #expect(Set(targets) == [101, 102, 103, 200, 201])
    }

    @Test("a process can't be its own ancestor, and launchd is never a target")
    func odd() {
        let table = [
            ProcessTree.Entry(pid: 0, parent: 0, group: 0),
            ProcessTree.Entry(pid: 1, parent: 0, group: 1),
            ProcessTree.Entry(pid: 100, parent: 1, group: 100),
        ]
        #expect(ProcessTree.targets(under: 0, in: table, ownGroup: 50, me: 50).isEmpty)
        #expect(ProcessTree.targets(under: 1, in: table, ownGroup: 50, me: 50).isEmpty)
    }

    @Test("ending a session ends its background jobs, even ones whose shell already exited")
    func endsBackgroundJobs() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tree-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = Process()
        root.executableURL = URL(fileURLWithPath: "/bin/sh")
        root.currentDirectoryURL = folder
        // Everything here ends on its own within 30 s, and none of it holds the test runner's
        // output open, in case the test process ends before `defer` runs.
        root.arguments = ["-c", "sleep 30 & echo $! > attached; (sleep 30 & echo $! > orphan); "
                            + "i=0; while [ $i -lt 30 ]; do sleep 1; i=$((i+1)); done"]
        root.standardOutput = FileHandle.nullDevice
        root.standardError = FileHandle.nullDevice
        try root.run()
        defer { root.terminate() }

        let attached = try await pid(in: folder.appendingPathComponent("attached"))
        let orphan = try await pid(in: folder.appendingPathComponent("orphan"))
        #expect(isAlive(attached) && isAlive(orphan))

        ProcessTree.endDescendants(of: root.processIdentifier, grace: .milliseconds(300))
        #expect(await gone(attached))
        #expect(await gone(orphan))
        #expect(root.isRunning) // the session itself closes on its own terms
    }

    /// A session (Claude Code, 100, started at 50) under LocalFlow (10), with an Ask run (200) beside it.
    private let adoptionTable = [
        ProcessTree.Entry(pid: 10, parent: 1, group: 10, started: 1),
        ProcessTree.Entry(pid: 100, parent: 10, group: 100, started: 50),
        ProcessTree.Entry(pid: 101, parent: 100, group: 101, started: 60), // in the tree already
        ProcessTree.Entry(pid: 300, parent: 1, group: 299, started: 70), // `nohup … &` from a shell now gone
        ProcessTree.Entry(pid: 301, parent: 1, group: 301, started: 71), // one that made its own group
        ProcessTree.Entry(pid: 302, parent: 300, group: 299, started: 72), // and its child
        ProcessTree.Entry(pid: 200, parent: 10, group: 200, started: 80), // an Ask answer running
        ProcessTree.Entry(pid: 201, parent: 200, group: 200, started: 81), // its helper
        ProcessTree.Entry(pid: 400, parent: 1, group: 400, started: 90), // a system helper working for LocalFlow
        ProcessTree.Entry(pid: 401, parent: 1, group: 401, started: 91), // a system program
        ProcessTree.Entry(pid: 402, parent: 1, group: 402, started: 20), // left by an earlier session
        ProcessTree.Entry(pid: 500, parent: 1, group: 500, started: 75), // someone else's
    ]

    @Test("jobs the session left outside its tree and groups are found by who macOS holds responsible")
    func adoptedJobs() {
        let responsible: (pid_t) -> pid_t? = { $0 == 500 ? 500 : 10 }
        let path: (pid_t) -> String? = { pid in
            switch pid {
            case 400: return "/System/Library/Frameworks/X.framework/XPCServices/H.xpc/Contents/MacOS/H"
            case 401: return "/usr/libexec/helper"
            default: return "/bin/sleep"
            }
        }
        let adopted = ProcessTree.adopted(under: 100, in: adoptionTable, owner: 10, responsible: responsible, path: path)
        #expect(Set(adopted) == [101, 300, 301, 302])
    }

    @Test("without knowing who's responsible, or when the session started, nothing is adopted")
    func adoptedNeedsBoth() {
        #expect(ProcessTree.adopted(under: 100, in: adoptionTable, owner: 10, responsible: { _ in nil },
                                    path: { _ in "/bin/sleep" }).isEmpty)
        let noStart = adoptionTable.map { ProcessTree.Entry(pid: $0.pid, parent: $0.parent, group: $0.group) }
        #expect(ProcessTree.adopted(under: 100, in: noStart, owner: 10, responsible: { _ in 10 },
                                    path: { _ in "/bin/sleep" }).isEmpty)
    }

    @Test("macOS says who's responsible for a process")
    func responsibleForSelf() {
        #expect(ProcessTree.responsiblePID(getpid()) != nil)
    }

    @Test("quitting stops even a job that ignores the polite stop, before it returns")
    func quitKillsStubbornJobs() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tree-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = Process()
        root.executableURL = URL(fileURLWithPath: "/bin/sh")
        root.currentDirectoryURL = folder
        root.arguments = ["-c", #"sh -c 'trap "" TERM; sleep 30' & echo $! > stubborn; sleep 30"#]
        root.standardOutput = FileHandle.nullDevice
        root.standardError = FileHandle.nullDevice
        try root.run()
        defer { root.terminate() }
        let stubborn = try await pid(in: folder.appendingPathComponent("stubborn"))
        try await Task.sleep(for: .milliseconds(200)) // let it set its trap

        ProcessTree.endDescendantsNow(of: root.processIdentifier, wait: .milliseconds(300))
        #expect(await gone(stubborn, within: .milliseconds(500)))
    }

    private func pid(in file: URL) async throws -> pid_t {
        for _ in 0..<50 {
            if let text = try? String(contentsOf: file, encoding: .utf8),
               let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return pid
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw CancellationError()
    }

    private func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 && ProcessTree.snapshot().contains { $0.pid == pid && !$0.isZombie }
    }

    private func gone(_ pid: pid_t, within limit: Duration = .seconds(3)) async -> Bool {
        let end = ContinuousClock.now + limit
        while ContinuousClock.now < end {
            if !isAlive(pid) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }
}
