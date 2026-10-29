import AppKit
import Foundation
import Testing
@testable import LocalFlow

/// Stands in for one Claude Code session; the test pushes its events.
final class FakeAgentSession: AgentSession, @unchecked Sendable {
    let events: AsyncStream<AgentEvent>
    private let continuation: AsyncStream<AgentEvent>.Continuation
    private(set) var started: [String] = []
    private(set) var sent: [String] = []
    private(set) var answers: [(id: String, allow: Bool, input: AgentJSON)] = []
    private(set) var interrupts = 0
    private(set) var closes = 0
    /// Order of calls across the session and the panel, for "moved before allowed".
    var journal: (String) -> Void = { _ in }

    init() { (events, continuation) = AsyncStream.makeStream(of: AgentEvent.self) }

    func emit(_ event: AgentEvent) { continuation.yield(event) }
    func end(_ error: AskError?) {
        continuation.yield(.ended(error))
        continuation.finish()
    }

    func start(task: String, imagePNGBase64: String?) { started.append(task) }
    func send(text: String, imagePNGBase64: String?) { sent.append(text) }
    func answer(requestID: String, allow: Bool, input: AgentJSON, message: String?) {
        journal("answer \(requestID) \(allow)")
        answers.append((requestID, allow, input))
    }
    func interrupt() { interrupts += 1 }
    func close() { closes += 1 }
    private(set) var terminations = 0
    func terminate() { terminations += 1 }
}

@MainActor
final class FakeAgentSurface: AgentSurface {
    let model = AgentModel()
    var onAnswer: ((AgentApproval, AgentAnswer) -> Void)?
    var onStop: (() -> Void)?
    var onClose: (() -> Void)?
    private(set) var isVisible = false
    private(set) var hint = ""
    /// The panel's spot in global points; a click inside it makes it move.
    var covers = CGRect(x: 900, y: 0, width: 380, height: 200)
    private(set) var movedFor: [CGPoint] = []
    private(set) var isAside = false
    var journal: (String) -> Void = { _ in }

    func show(on screen: NSScreen?) { isVisible = true }
    func hide() { isVisible = false }
    func setFollowUpHint(_ hint: String) { self.hint = hint }
    func moveAside(avoiding points: [CGPoint]) -> Bool {
        let hit = points.filter { covers.contains($0) }
        guard !hit.isEmpty else { return false }
        journal("moved")
        movedFor += hit
        isAside = true
        covers = .zero
        return true
    }
}

@MainActor
@Suite("Agent: running a task", .serialized)
struct AgentControllerTests {
    let surface = FakeAgentSurface()
    let glow = FakeIndicator()

    private final class Made { var sessions: [FakeAgentSession] = [] }
    private let made = Made()
    private var session: FakeAgentSession { made.sessions.last! }

    private func makeController(target: String? = nil, frontApp: String? = nil,
                                lookUp: (@MainActor (CGPoint) async -> ClickTarget.Found)? = nil) -> AgentController {
        AgentController(
            surface: surface,
            indicator: glow,
            makeSession: { [made] _, _ in
                let session = FakeAgentSession()
                made.sessions.append(session)
                return session
            },
            displayID: { _ in 1 },
            mapping: { _ in ScreenMapping(displayBounds: CGRect(x: 0, y: 0, width: 1280, height: 800)) },
            lookUp: lookUp ?? { _ in target.map { .named($0) } ?? .unnamed },
            frontApp: { frontApp },
            chime: {},
            finished: { _ in }
        )
    }

    private func until(_ condition: () -> Bool) async {
        for _ in 0..<400 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func bash(_ command: String) -> AgentJSON {
        .object(["command": .string(command), "description": .string("")])
    }

    private func click(_ x: Double, _ y: Double) -> AgentJSON {
        .object(["x": .number(x), "y": .number(y)])
    }

    @Test("a task starts a session, shows the panel and outlines the screen")
    func starts() async {
        let agent = makeController()

        agent.run("tidy my desktop", on: nil)

        #expect(made.sessions.count == 1)
        #expect(session.started == ["tidy my desktop"])
        #expect(surface.isVisible)
        #expect(surface.model.task == "tidy my desktop")
        #expect(surface.model.status == .starting)
        #expect(glow.isShowing)
        session.emit(.sessionStarted(sessionID: "s"))
        await until { surface.model.status == .working }
        #expect(surface.model.status == .working)
    }

    @Test("tools show as plain steps that tick off when they finish")
    func steps() async {
        let agent = makeController()
        agent.run("t", on: nil)

        session.emit(.toolStarted(id: "a", name: "Bash", input: .object(["command": .string("ls"),
                                                                       "description": .string("List files")])))
        session.emit(.toolFinished(id: "a", isError: false, summary: "x"))
        await until { surface.model.steps.first?.state == .done }

        #expect(surface.model.steps.map(\.title) == ["List files"])
        #expect(surface.model.steps.first?.state == .done)
    }

    @Test("a safe request is allowed at once, with its input unchanged and no card")
    func safeAllowed() async {
        let agent = makeController()
        agent.run("t", on: nil)
        let input = AgentJSON.object([:])

        session.emit(.permissionRequest(requestID: "r1", toolName: "mcp__localflow__screenshot", input: input,
                                        description: nil, toolUseID: "u1"))
        await until { !session.answers.isEmpty }

        #expect(session.answers.first?.id == "r1")
        #expect(session.answers.first?.allow == true)
        #expect(session.answers.first?.input == input)
        #expect(surface.model.approvals.isEmpty)
    }

    @Test("a risky command waits for the user, then goes ahead when allowed")
    func riskyAllowed() async {
        let agent = makeController()
        agent.run("t", on: nil)
        let input = bash("rm -rf build")

        session.emit(.permissionRequest(requestID: "r1", toolName: "Bash", input: input, description: nil,
                                        toolUseID: "u1"))
        await until { !surface.model.approvals.isEmpty }
        #expect(session.answers.isEmpty)
        #expect(surface.model.status == .needsApproval)

        surface.onAnswer?(surface.model.approvals[0], .allowOnce)

        #expect(session.answers.map(\.allow) == [true])
        #expect(session.answers.first?.input == input)
        #expect(surface.model.approvals.isEmpty)
    }

    @Test("denying keeps the step marked as turned down, even when its error comes back")
    func denied() async {
        let agent = makeController()
        agent.run("t", on: nil)
        session.emit(.toolStarted(id: "u1", name: "Bash", input: bash("git push")))
        session.emit(.permissionRequest(requestID: "r1", toolName: "Bash", input: bash("git push"),
                                        description: nil, toolUseID: "u1"))
        await until { !surface.model.approvals.isEmpty }

        surface.onAnswer?(surface.model.approvals[0], .deny)
        session.emit(.toolFinished(id: "u1", isError: true, summary: "denied"))
        try? await Task.sleep(for: .milliseconds(30))

        #expect(session.answers.map(\.allow) == [false])
        #expect(surface.model.steps.first?.state == .denied)
    }

    @Test("allow for this task lets the same kind of step through without asking again")
    func allowForTask() async {
        let agent = makeController()
        agent.run("t", on: nil)
        session.emit(.permissionRequest(requestID: "r1", toolName: "Bash", input: bash("rm a"), description: nil,
                                        toolUseID: "u1"))
        session.emit(.permissionRequest(requestID: "r2", toolName: "Bash", input: bash("rm b"), description: nil,
                                        toolUseID: "u2"))
        await until { surface.model.approvals.count == 2 }

        surface.onAnswer?(surface.model.approvals[0], .allowForTask)
        #expect(session.answers.map(\.id) == ["r1", "r2"])
        #expect(surface.model.approvals.isEmpty)

        session.emit(.permissionRequest(requestID: "r3", toolName: "Bash", input: bash("rm c"), description: nil,
                                        toolUseID: "u3"))
        await until { session.answers.count == 3 }
        #expect(session.answers.last?.allow == true)
        #expect(surface.model.approvals.isEmpty)
    }

    @Test("return asks when a chat app is in front, and goes ahead elsewhere")
    func returnInChat() async {
        let chat = makeController(frontApp: "com.apple.MobileSMS")
        chat.run("t", on: nil)
        session.emit(.permissionRequest(requestID: "r1", toolName: "mcp__localflow__key",
                                        input: .object(["keys": .string("return")]), description: nil, toolUseID: "u1"))
        await until { surface.model.approvals.count == 1 }
        #expect(surface.model.approvals.first?.grantKey == "key:send")
        #expect(session.answers.isEmpty)
        chat.close()

        let browser = makeController(frontApp: "com.apple.Safari")
        browser.run("t", on: nil)
        session.emit(.permissionRequest(requestID: "r2", toolName: "mcp__localflow__key",
                                        input: .object(["keys": .string("return")]), description: nil, toolUseID: "u2"))
        await until { session.answers.count == 1 }
        #expect(session.answers.first?.allow == true)
    }

    @Test("allow for this task on a step that can't be read in full allows just that one")
    func oneAtATime() async {
        let agent = makeController()
        agent.run("t", on: nil)
        session.emit(.permissionRequest(requestID: "r1", toolName: "Bash", input: bash("eval \"$X\""),
                                        description: nil, toolUseID: "u1"))
        await until { surface.model.approvals.count == 1 }
        let approval = surface.model.approvals[0]
        #expect(!approval.canAllowForTask)

        surface.onAnswer?(approval, .allowForTask)
        #expect(session.answers.map(\.allow) == [true])
        session.emit(.permissionRequest(requestID: "r2", toolName: "Bash", input: bash("eval \"$Y\""),
                                        description: nil, toolUseID: "u2"))
        await until { surface.model.approvals.count == 1 }
        #expect(session.answers.count == 1)
    }

    @Test("a click where the panel sits moves the panel first, then goes ahead")
    func clickMovesPanel() async {
        let agent = makeController()
        var order: [String] = []
        surface.journal = { order.append($0) }
        agent.run("t", on: nil)
        session.journal = { order.append($0) }

        session.emit(.permissionRequest(requestID: "r1", toolName: "mcp__localflow__click", input: click(1000, 100),
                                        description: nil, toolUseID: "u1"))
        await until { !session.answers.isEmpty }

        #expect(surface.movedFor == [CGPoint(x: 1000, y: 100)])
        #expect(order == ["moved", "answer r1 true"])
    }

    @Test("the panel moves out of the way before what's under a click is looked up")
    func movesBeforeLookingUp() async {
        var order: [String] = []
        let agent = makeController(lookUp: { [surface] _ in
            order.append(surface.isAside ? "looked up after moving" : "looked up under the panel")
            return .named("Delete")
        })
        surface.journal = { order.append($0) }
        agent.run("t", on: nil)

        session.emit(.permissionRequest(requestID: "r1", toolName: "mcp__localflow__click", input: click(1000, 100),
                                        description: nil, toolUseID: "u1"))
        await until { !surface.model.approvals.isEmpty }

        #expect(order == ["moved", "looked up after moving"])
        #expect(surface.model.approvals.first?.summary.contains("Delete") == true)
        #expect(surface.model.steps.first?.title == "Click “Delete”")
    }

    @Test("a click that would land on a LocalFlow window asks first")
    func clickOnLocalFlow() async {
        let agent = makeController(lookUp: { _ in .localFlow })
        agent.run("t", on: nil)

        session.emit(.permissionRequest(requestID: "r1", toolName: "mcp__localflow__click", input: click(300, 300),
                                        description: nil, toolUseID: "u1"))
        await until { !surface.model.approvals.isEmpty }

        #expect(session.answers.isEmpty)
        #expect(surface.model.approvals.first?.summary.contains("LocalFlow") == true)
    }

    @Test("a drag moves the panel off both of its ends")
    func dragMovesPanel() async {
        let agent = makeController()
        agent.run("t", on: nil)
        let input = AgentJSON.object(["from_x": .number(1000), "from_y": .number(100),
                                      "to_x": .number(100), "to_y": .number(100)])

        session.emit(.permissionRequest(requestID: "r1", toolName: "mcp__localflow__drag", input: input,
                                        description: nil, toolUseID: "u1"))
        await until { !session.answers.isEmpty }

        #expect(surface.movedFor == [CGPoint(x: 1000, y: 100)])
        #expect(session.answers.first?.allow == true)
    }

    @Test("Stop before it has started ends that session, and the next task starts a new one")
    func stopWhileStarting() async {
        let agent = makeController()
        agent.run("first", on: nil)

        surface.onStop?()
        agent.run("second", on: nil)

        #expect(made.sessions.first?.closes == 1)
        #expect(made.sessions.count == 2)
        #expect(session.started == ["second"])
    }

    @Test("Stop with more waiting to run ends the session instead of leaving it half-stopped")
    func stopWithQueuedMore() async {
        let agent = makeController()
        agent.run("first", on: nil)
        session.emit(.sessionStarted(sessionID: "s"))
        await until { surface.model.status == .working }
        agent.run("more", on: nil)

        surface.onStop?()

        #expect(session.closes == 1)
        #expect(session.interrupts == 0)
        session.end(nil)
        await until { surface.model.status == .stopped }
        #expect(surface.model.status == .stopped)
    }

    @Test("quitting LocalFlow stops the session at once")
    func shutdown() {
        let agent = makeController()
        agent.run("t", on: nil)

        agent.shutdown()

        #expect(session.terminations == 1)
        #expect(!surface.isVisible)
    }

    @Test("a click on a Send button asks first, naming the button")
    func clickOnSend() async {
        let agent = makeController(target: "Send")
        agent.run("t", on: nil)

        session.emit(.permissionRequest(requestID: "r1", toolName: "mcp__localflow__click", input: click(300, 300),
                                        description: nil, toolUseID: "u1"))
        await until { !surface.model.approvals.isEmpty }

        #expect(session.answers.isEmpty)
        #expect(surface.model.approvals.first?.summary.contains("Send") == true)
    }

    @Test("a finished turn shows the reply, ticks off the steps and drops the outline")
    func finished() async {
        let agent = makeController()
        agent.run("t", on: nil)
        session.emit(.toolStarted(id: "a", name: "mcp__localflow__screenshot", input: .object([:])))
        session.emit(.textDelta("Working on it"))

        session.emit(.turnFinished(failure: nil, finalText: "Moved 12 files into Archive."))
        await until { surface.model.status == .done }

        #expect(surface.model.reply == "Moved 12 files into Archive.")
        #expect(surface.model.steps.allSatisfy { $0.state == .done })
        #expect(!glow.isShowing)
        #expect(surface.isVisible)
    }

    @Test("Stop turns down what's waiting, interrupts, and shows Stopped")
    func stop() async {
        let agent = makeController()
        agent.run("t", on: nil)
        session.emit(.permissionRequest(requestID: "r1", toolName: "Bash", input: bash("rm a"), description: nil,
                                        toolUseID: "u1"))
        await until { !surface.model.approvals.isEmpty }

        surface.onStop?()
        session.emit(.turnFinished(failure: "interrupted", finalText: nil))
        await until { surface.model.status == .stopped }

        #expect(session.answers.map(\.allow) == [false])
        #expect(session.interrupts == 1)
        #expect(surface.model.status == .stopped)
        #expect(surface.model.approvals.isEmpty)
        #expect(!glow.isShowing)
    }

    @Test("a session that ends with an error says why, and the next task starts a new one")
    func endedWithError() async {
        let agent = makeController()
        agent.run("t", on: nil)

        session.end(.claudeSignedOut)
        await until { surface.model.status != .starting }

        #expect(surface.model.status == .failed(AskError.claudeSignedOut.message))
        #expect(!glow.isShowing)
        agent.run("again", on: nil)
        #expect(made.sessions.count == 2)
        #expect(session.started == ["again"])
    }

    @Test("more for a running session goes to the same session, and it's done after both")
    func followUp() async {
        let agent = makeController()
        agent.run("first", on: nil)
        session.emit(.sessionStarted(sessionID: "s"))

        agent.run("and then this", on: nil)

        #expect(made.sessions.count == 1)
        #expect(session.sent == ["and then this"])
        #expect(surface.model.task == "and then this")
        session.emit(.turnFinished(failure: nil, finalText: "did the first"))
        try? await Task.sleep(for: .milliseconds(30))
        #expect(surface.model.status.isWorking)
        session.emit(.turnFinished(failure: nil, finalText: "did both"))
        await until { surface.model.status == .done }
        #expect(surface.model.reply == "did both")
    }

    @Test("more after it's done carries on in the same session")
    func followUpAfterDone() async {
        let agent = makeController()
        agent.run("first", on: nil)
        session.emit(.turnFinished(failure: nil, finalText: "done"))
        await until { surface.model.status == .done }

        agent.run("now this", on: nil)

        #expect(made.sessions.count == 1)
        #expect(session.sent == ["now this"])
        #expect(surface.model.status.isWorking)
        #expect(glow.isShowing)
    }

    @Test("closing ends the session and hides everything; nothing after it shows")
    func close() async {
        let agent = makeController()
        agent.run("t", on: nil)

        surface.onClose?()
        session.emit(.toolStarted(id: "late", name: "Bash", input: bash("ls")))
        try? await Task.sleep(for: .milliseconds(30))

        #expect(session.closes == 1)
        #expect(!surface.isVisible)
        #expect(!glow.isShowing)
        #expect(surface.model.steps.isEmpty)
        agent.run("next", on: nil)
        #expect(made.sessions.count == 2)
    }
}

@Suite("Agent: steps in plain words")
struct AgentStepTitleTests {
    @Test("each tool reads as a plain step", arguments: [
        ("Bash", AgentJSON.object(["command": .string("npm test"), "description": .string("Run the tests")]), "Run the tests"),
        ("Bash", .object(["command": .string("ls -la")]), "Run ls -la"),
        ("Read", .object(["file_path": .string("/Users/x/notes/plan.md")]), "Read plan.md"),
        ("Write", .object(["file_path": .string("/tmp/a.txt"), "content": .string("hi")]), "Write a.txt"),
        ("Edit", .object(["file_path": .string("/tmp/b.swift")]), "Edit b.swift"),
        ("Glob", .object(["pattern": .string("**/*.pdf")]), "Find files matching **/*.pdf"),
        ("Grep", .object(["pattern": .string("invoice")]), "Search files for “invoice”"),
        ("WebFetch", .object(["url": .string("https://example.com/a/b")]), "Open example.com"),
        ("WebSearch", .object(["query": .string("swift 6 actors")]), "Search the web for “swift 6 actors”"),
        ("TodoWrite", .object([:]), "Update the plan"),
        ("mcp__localflow__screenshot", .object([:]), "Look at the screen"),
        ("mcp__localflow__click", .object(["x": .number(1), "y": .number(2)]), "Click"),
        ("mcp__localflow__click", .object(["x": .number(1), "y": .number(2), "clicks": .number(2)]), "Double-click"),
        ("mcp__localflow__click", .object(["x": .number(1), "y": .number(2), "button": .string("right")]), "Right-click"),
        ("mcp__localflow__type", .object(["text": .string("hello there")]), "Type “hello there”"),
        ("mcp__localflow__key", .object(["keys": .string("cmd+t")]), "Press cmd+t"),
        ("mcp__localflow__scroll", .object(["x": .number(1), "y": .number(1), "direction": .string("down")]), "Scroll down"),
        ("mcp__localflow__open_app", .object(["name": .string("Safari")]), "Open Safari"),
        ("mcp__localflow__list_apps", .object([:]), "Check which apps are open"),
        ("mcp__localflow__wait", .object(["seconds": .number(2)]), "Wait 2s"),
        ("mcp__localflow__drag", .object([:]), "Drag"),
        ("mcp__localflow__move", .object([:]), "Move the pointer"),
        ("mcp__other__thing", .object([:]), "Use thing"),
    ])
    func titles(tool: String, input: AgentJSON, title: String) {
        #expect(AgentStepTitle.title(toolName: tool, input: input, target: nil) == title)
    }

    @Test("a click names what it lands on when that's known")
    func clickTarget() {
        let title = AgentStepTitle.title(toolName: "mcp__localflow__click", input: .object([:]), target: "New Message")
        #expect(title == "Click “New Message”")
    }

    @Test("long typed text and commands are cut to one short line")
    func clipped() {
        let long = String(repeating: "word ", count: 40)
        let title = AgentStepTitle.title(toolName: "mcp__localflow__type", input: .object(["text": .string(long)]),
                                         target: nil)
        #expect(title.count <= 60)
        #expect(!title.contains("\n"))
    }
}
