import AppKit
import SwiftUI
import Testing
@testable import LocalFlow

@MainActor
@Suite("Agent panel: what it shows")
struct AgentModelTests {
    @Test("a new task clears the last one's steps, approvals and reply")
    func startResets() {
        let model = AgentModel()
        model.start(task: "first")
        model.addStep(id: "a", title: "Look at the screen")
        model.ask(AgentApproval(id: "r1", summary: "Run `rm x`", grantKey: "Bash:rm"))
        model.reply = "done"
        model.status = .done

        model.start(task: "second")

        #expect(model.task == "second")
        #expect(model.steps.isEmpty)
        #expect(model.approvals.isEmpty)
        #expect(model.reply.isEmpty)
        #expect(model.status == .starting)
    }

    @Test("a step starts running and finishes done, failed or turned down")
    func stepStates() {
        let model = AgentModel()
        model.start(task: "t")
        model.addStep(id: "a", title: "Run tests")
        model.addStep(id: "b", title: "Click Send")
        model.addStep(id: "c", title: "Delete files")

        model.finishStep(id: "a", state: .done)
        model.finishStep(id: "b", state: .failed)
        model.finishStep(id: "c", state: .denied)
        model.finishStep(id: "unknown", state: .done)

        #expect(model.steps.map(\.state) == [.done, .failed, .denied])
        #expect(model.steps.map(\.title) == ["Run tests", "Click Send", "Delete files"])
    }

    @Test("a step turned down stays turned down when its result comes back")
    func deniedStaysDenied() {
        let model = AgentModel()
        model.start(task: "t")
        model.addStep(id: "a", title: "Push")
        model.finishStep(id: "a", state: .denied)

        model.finishStep(id: "a", state: .failed)

        #expect(model.steps.first?.state == .denied)
    }

    @Test("more for the same session replaces the task and keeps the steps")
    func followUp() {
        let model = AgentModel()
        model.start(task: "first")
        model.addStep(id: "a", title: "Look")
        model.reply = "done the first"
        model.status = .done

        model.followUp(task: "second")

        #expect(model.task == "second")
        #expect(model.status == .working)
        #expect(model.reply.isEmpty)
        #expect(model.steps.count == 1)
    }

    @Test("a step can be renamed once what it acts on is known")
    func retitle() {
        let model = AgentModel()
        model.start(task: "t")
        model.addStep(id: "a", title: "Click")

        model.retitle(id: "a", title: "Click “Send”")

        #expect(model.steps.first?.title == "Click “Send”")
        #expect(model.steps.first?.state == .running)
    }

    @Test("dropping every waiting card goes back to working")
    func clearBackToWorking() {
        let model = AgentModel()
        model.start(task: "t")
        model.status = .working
        model.ask(AgentApproval(id: "r1", summary: "s", grantKey: "k"))

        #expect(model.clearApprovals() == ["r1"])
        #expect(model.status == .working)
    }

    @Test("more while a card is up still says it needs an OK, and the clock restarts")
    func followUpWhileAsking() {
        let model = AgentModel()
        model.start(task: "first")
        model.status = .working
        model.ask(AgentApproval(id: "r1", summary: "s", grantKey: "k"))
        let firstStart = model.startedAt

        model.followUp(task: "second")

        #expect(model.status == .needsApproval)
        #expect(model.startedAt >= firstStart)
    }

    @Test("the same step reported twice shows once")
    func duplicateStep() {
        let model = AgentModel()
        model.start(task: "t")
        model.addStep(id: "a", title: "Run tests")
        model.addStep(id: "a", title: "Run tests")

        #expect(model.steps.count == 1)
    }

    @Test("only the newest steps show, with a count of the earlier ones")
    func visibleSteps() {
        let model = AgentModel()
        model.start(task: "t")
        for index in 0..<8 { model.addStep(id: "\(index)", title: "Step \(index)") }

        let shown = model.visibleSteps(limit: 5)

        #expect(shown.steps.map(\.id) == ["3", "4", "5", "6", "7"])
        #expect(shown.earlier == 3)
    }

    @Test("a very long task keeps a bounded list of steps")
    func stepsCapped() {
        let model = AgentModel()
        model.start(task: "t")
        for index in 0..<(AgentModel.maxSteps + 20) { model.addStep(id: "\(index)", title: "Step") }

        #expect(model.steps.count == AgentModel.maxSteps)
        #expect(model.steps.first?.id == "20")
        #expect(model.visibleSteps(limit: 5).earlier == AgentModel.maxSteps + 15)
    }

    @Test("approvals wait in order and leave once answered")
    func approvalsQueue() {
        let model = AgentModel()
        model.start(task: "t")
        model.status = .working
        model.ask(AgentApproval(id: "r1", summary: "one", grantKey: "k1"))
        model.ask(AgentApproval(id: "r2", summary: "two", grantKey: "k2"))

        #expect(model.status == .needsApproval)
        #expect(model.approvals.first?.id == "r1")

        model.resolve(id: "r1")
        #expect(model.approvals.map(\.id) == ["r2"])
        #expect(model.status == .needsApproval)

        model.resolve(id: "r2")
        #expect(model.approvals.isEmpty)
        #expect(model.status == .working)
    }

    @Test("each state has a plain title", arguments: [
        (AgentStatus.starting, "Starting"),
        (.working, "Working"),
        (.needsApproval, "Needs your OK"),
        (.done, "Done"),
        (.stopped, "Stopped"),
        (.failed("x"), "Couldn't finish"),
    ])
    func titles(status: AgentStatus, title: String) {
        #expect(status.title == title)
    }

    @Test("working means starting, working or waiting for an OK")
    func isWorking() {
        #expect(AgentStatus.starting.isWorking)
        #expect(AgentStatus.working.isWorking)
        #expect(AgentStatus.needsApproval.isWorking)
        #expect(!AgentStatus.done.isWorking)
        #expect(!AgentStatus.stopped.isWorking)
        #expect(!AgentStatus.failed("x").isWorking)
    }
}

@Suite("Agent panel: inline code in approvals")
struct CodeSpansTests {
    @Test("backticked parts are code, the rest is plain")
    func splits() {
        #expect(CodeSpans.split("Run `git push` now") == [
            CodeSpans.Span(text: "Run ", isCode: false),
            CodeSpans.Span(text: "git push", isCode: true),
            CodeSpans.Span(text: " now", isCode: false),
        ])
    }

    @Test("an unclosed backtick stays as written")
    func unclosed() {
        #expect(CodeSpans.split("Run `rm") == [CodeSpans.Span(text: "Run `rm", isCode: false)])
    }

    @Test("text without backticks is one plain span; empty is none")
    func plain() {
        #expect(CodeSpans.split("Click Send") == [CodeSpans.Span(text: "Click Send", isCode: false)])
        #expect(CodeSpans.split("").isEmpty)
    }

    @Test("markdown links are never made clickable")
    func noLinks() {
        let spans = CodeSpans.split("Open [here](https://evil.example)")
        #expect(spans == [CodeSpans.Span(text: "Open [here](https://evil.example)", isCode: false)])
    }
}

@Suite("Agent panel: where it sits")
struct AgentPlacementTests {
    let visible = NSRect(x: 0, y: 0, width: 1512, height: 944)
    let size = NSSize(width: 400, height: 200)

    @Test("it starts in the top-right corner of the screen, inset from the edges")
    func topRight() {
        let frame = AgentPlacement.frame(size: size, in: visible, corner: .topRight)

        #expect(frame == NSRect(x: 1512 - 400 - 16, y: 944 - 200 - 16, width: 400, height: 200))
    }

    @Test("the other corners are inset the same way")
    func corners() {
        #expect(AgentPlacement.frame(size: size, in: visible, corner: .topLeft)
                 == NSRect(x: 16, y: 944 - 200 - 16, width: 400, height: 200))
        #expect(AgentPlacement.frame(size: size, in: visible, corner: .bottomRight)
                 == NSRect(x: 1512 - 400 - 16, y: 16, width: 400, height: 200))
    }

    @Test("it stays put when nothing it covers is clicked")
    func staysPut() {
        let spot = AgentPlacement.spot(keeping: .corner(.topRight), size: size, in: visible, primaryHeight: 944,
                                       avoiding: [CGPoint(x: 600, y: 500)])
        #expect(spot == .corner(.topRight))
    }

    @Test("a click under it sends it to the other top corner")
    func movesForClick() {
        let spot = AgentPlacement.spot(keeping: .corner(.topRight), size: size, in: visible, primaryHeight: 944,
                                       avoiding: [CGPoint(x: 1300, y: 100)])
        #expect(spot == .corner(.topLeft))
    }

    @Test("a drag from under one top corner to under the other sends it to a bottom corner")
    func dragAcrossTop() {
        let spot = AgentPlacement.spot(keeping: .corner(.topRight), size: size, in: visible, primaryHeight: 944,
                                       avoiding: [CGPoint(x: 1300, y: 100), CGPoint(x: 100, y: 100)])
        #expect(spot == .corner(.bottomRight))
    }

    @Test("a window's frame converts to the top-left coordinates clicks use")
    func toGlobal() {
        let window = NSRect(x: 1096, y: 728, width: 400, height: 200)

        let global = AgentPlacement.globalRect(window, primaryHeight: 982)

        #expect(global == CGRect(x: 1096, y: 982 - 928, width: 400, height: 200))
    }

    @Test("a click on or just beside the panel counts as covering it")
    func covering() {
        let panel = CGRect(x: 1096, y: 54, width: 400, height: 200)

        #expect(AgentPlacement.isCovering(CGPoint(x: 1200, y: 100), panel: panel))
        #expect(AgentPlacement.isCovering(CGPoint(x: 1090, y: 100), panel: panel))
        #expect(!AgentPlacement.isCovering(CGPoint(x: 600, y: 400), panel: panel))
        // Room is left for it to grow as steps come in.
        #expect(AgentPlacement.isCovering(CGPoint(x: 1200, y: 300), panel: panel))
        #expect(!AgentPlacement.isCovering(CGPoint(x: 1200, y: 500), panel: panel))
    }

    // MARK: Dragged anywhere

    @Test("a corner spot is the corner frame, home is home, and a free spot hangs from its top middle")
    func spotFrames() {
        #expect(AgentPlacement.frame(size: size, in: visible, spot: .corner(.topRight))
                 == AgentPlacement.frame(size: size, in: visible, corner: .topRight))
        #expect(AgentPlacement.frame(size: size, in: visible, spot: .home)
                 == AgentPlacement.home(size: size, in: visible))
        #expect(AgentPlacement.frame(size: size, in: visible, spot: .free(CGPoint(x: 500, y: 700)))
                 == NSRect(x: 300, y: 500, width: 400, height: 200))
    }

    @Test("a free spot past the screen's edge is pulled back inside it")
    func freeSpotStaysOnScreen() {
        let pastRight = AgentPlacement.frame(size: size, in: visible, spot: .free(CGPoint(x: 1500, y: 2000)))
        #expect(pastRight == NSRect(x: 1112, y: 744, width: 400, height: 200))

        let pastBottomLeft = AgentPlacement.frame(size: size, in: visible, spot: .free(CGPoint(x: -50, y: 40)))
        #expect(pastBottomLeft == NSRect(x: 0, y: 0, width: 400, height: 200))
    }

    @Test("let go near the top-right corner, it snaps into the corner")
    func snapsTopRight() {
        let corner = AgentPlacement.frame(size: size, in: visible, corner: .topRight)
        let dropped = corner.offsetBy(dx: -40, dy: -30)

        #expect(AgentPlacement.spot(droppedAt: dropped, in: visible) == .corner(.topRight))
    }

    @Test("let go near the bottom middle, it snaps home where the Ask window sits")
    func snapsHome() {
        let home = AgentPlacement.home(size: size, in: visible)
        let dropped = home.offsetBy(dx: 50, dy: 40)

        #expect(AgentPlacement.spot(droppedAt: dropped, in: visible) == .home)
    }

    @Test("let go anywhere else, it stays right where it was dropped")
    func staysWhereDropped() {
        let dropped = NSRect(x: 100, y: 400, width: 400, height: 200)

        #expect(AgentPlacement.spot(droppedAt: dropped, in: visible) == .free(CGPoint(x: 300, y: 600)))
    }

    @Test("dropped half off the screen, it's kept on it")
    func droppedOffScreen() {
        let dropped = NSRect(x: -150, y: 400, width: 400, height: 200)

        #expect(AgentPlacement.spot(droppedAt: dropped, in: visible) == .free(CGPoint(x: 200, y: 600)))
    }

    @Test("a dragged window follows the pointer from where the drag began")
    func dragFollowsPointer() {
        let drag = AgentDrag(startPointer: CGPoint(x: 1300, y: 900), startFrame: NSRect(x: 1096, y: 728, width: 400, height: 200))

        #expect(drag.frame(at: CGPoint(x: 700, y: 500)) == NSRect(x: 496, y: 328, width: 400, height: 200))
    }

    @Test("the window keeps the spot it was grabbed by, counting the points moved before the drag began")
    func dragCountsTheFirstPoints() {
        // SwiftUI's translation runs down; AppKit's screen points run up.
        let drag = AgentDrag(pointer: CGPoint(x: 1330, y: 880), translation: CGSize(width: 30, height: 20),
                             frame: NSRect(x: 1096, y: 728, width: 400, height: 200))

        #expect(drag.startPointer == CGPoint(x: 1300, y: 900))
        #expect(drag.frame(at: CGPoint(x: 1330, y: 880)) == NSRect(x: 1126, y: 708, width: 400, height: 200))
    }

    @Test("dragged somewhere, a click under it still sends it to a clear corner")
    func freeSpotMovesForClick() {
        let spot = AgentSpot.free(CGPoint(x: 700, y: 600))
        let clear = AgentPlacement.spot(keeping: spot, size: size, in: visible, primaryHeight: 944,
                                        avoiding: [CGPoint(x: 1300, y: 900)])
        let covered = AgentPlacement.spot(keeping: spot, size: size, in: visible, primaryHeight: 944,
                                          avoiding: [CGPoint(x: 700, y: 400)])
        #expect(clear == spot)
        #expect(covered == .corner(.topRight))
    }

    @Test("after the box: to the agent, the top right; otherwise back where it was before home, or where it is")
    func spotAfterTheBox() {
        let free = AgentSpot.free(CGPoint(x: 300, y: 600))
        #expect(AgentPlacement.spot(after: .handedToAgent, current: free, beforeHome: nil) == .corner(.topRight))
        #expect(AgentPlacement.spot(after: .handedToAgent, current: .home, beforeHome: free) == .corner(.topRight))
        #expect(AgentPlacement.spot(after: .asked, current: .home, beforeHome: free) == free)
        #expect(AgentPlacement.spot(after: .cancelled, current: .home, beforeHome: .corner(.topLeft)) == .corner(.topLeft))
        #expect(AgentPlacement.spot(after: .cancelled, current: free, beforeHome: nil) == free)
        #expect(AgentPlacement.spot(after: .asked, current: .home, beforeHome: nil) == .home)
    }

    @Test("the box opens on the window's own screen when it opens in place, else on the one Ask is on")
    func screenForTheBox() {
        #expect(AgentPlacement.screen(forBoxInPlace: true, current: "left", asked: "right") == "left")
        #expect(AgentPlacement.screen(forBoxInPlace: false, current: "left", asked: "right") == "right")
        #expect(AgentPlacement.screen(forBoxInPlace: true, current: nil, asked: "right") == "right")
        #expect(AgentPlacement.screen(forBoxInPlace: false, current: "left", asked: nil) == "left")
        #expect(AgentPlacement.screen(forBoxInPlace: false, current: nil as String?, asked: nil) == nil)
    }
}

@MainActor
@Suite("Agent panel: rendering")
struct AgentPanelRenderTests {
    private func render(_ model: AgentModel, name: String, input: ComposerModel? = nil,
                        showsInput: Bool = false, collapsed: Bool = false) throws {
        let view = AgentPanelView(model: model, input: input ?? ComposerModel(), showsInput: showsInput,
                                  collapsed: collapsed,
                                  followUpHint: "⌘ to give it more  ·  Right ⌥ to ask", scrolls: false)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let width = collapsed ? AgentPanelView.collapsedSize.width
                              : showsInput ? AgentPanelView.inputWidth : AgentPanelView.width
        #expect(image.size.width == width)
        if collapsed { #expect(image.size.height == AgentPanelView.collapsedSize.height) }
        guard let dir = ProcessInfo.processInfo.environment["LOCALFLOW_SNAPSHOT_DIR"],
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("agent-\(name).png"))
    }

    private func working() -> AgentModel {
        let model = AgentModel()
        model.start(task: "Find the invoice PDF from Acme in my Downloads and email it to Dana")
        model.status = .working
        for (index, title) in ["Search Downloads for “Acme”", "Read invoice-2026-10.pdf", "Open Mail",
                               "Look at the screen", "Click New Message", "Type the message"].enumerated() {
            model.addStep(id: "\(index)", title: title)
            if index < 5 { model.finishStep(id: "\(index)", state: .done) }
        }
        model.reply = "Found it. Writing the email now."
        return model
    }

    @Test("working, waiting for an OK, done, and failed all render at the panel's width")
    func states() throws {
        let model = working()
        try render(model, name: "working")

        model.ask(AgentApproval(id: "r1", summary: "Click “Send” in Mail", grantKey: "click:irreversible"))
        model.ask(AgentApproval(id: "r2", summary: "Run `rm -rf ~/Downloads/old-invoices`", grantKey: "Bash:rm"))
        try render(model, name: "approval")

        model.resolve(id: "r1")
        try render(model, name: "approval-command")

        _ = model.clearApprovals()
        model.endRunningSteps(as: .done)
        model.status = .done
        model.reply = "Sent the Acme invoice (invoice-2026-10.pdf, 212 KB) to Dana from your Gmail account."
        try render(model, name: "done")

        model.status = .failed(AskError.claudeOutOfUsage(resetsAt: nil, detail: nil).message)
        try render(model, name: "failed")
    }

    @Test("an Instant run shows its stages, then the summary with Undo")
    func instantRun() throws {
        let model = AgentModel()
        model.start(task: "make the save button round", instant: true)
        model.status = .working
        model.addStep(id: "screen", title: "Viewing screen")
        model.finishStep(id: "screen", state: .done)
        model.addStep(id: "project", title: "Locating project")
        try render(model, name: "instant-locating")

        model.retitle(id: "project", title: "Northwind")
        model.finishStep(id: "project", state: .done)
        model.addStep(id: "profile", title: "Reading design profile")
        model.finishStep(id: "profile", state: .done)
        model.addStep(id: "change", title: "Making the Save button round instead of square")
        try render(model, name: "instant-changing")

        model.endRunningSteps(as: .done)
        model.status = .done
        model.canUndo = true
        model.reply = "Rounded the Save button in the job header (corner radius 8 to full), matching the pill buttons in your design profile."
        try render(model, name: "instant-done")
    }

    @Test("the box in the agent's window renders green in agent mode, with Instant on, and blue for Ask")
    func inputBox() throws {
        let model = working()
        let input = ComposerModel()
        input.reset(mode: .typing, agentMode: true)
        input.text = "Also attach the receipt"
        try render(model, name: "input-agent", input: input, showsInput: true)

        _ = input.toggleInstant()
        try render(model, name: "input-instant", input: input, showsInput: true)

        input.toggleAgentMode()
        input.text = ""
        try render(model, name: "input-ask", input: input, showsInput: true)
    }

    @Test("collapsed, it's a small capsule with the status, working, waiting or done")
    func collapsed() throws {
        let model = working()
        try render(model, name: "collapsed-working", collapsed: true)

        model.ask(AgentApproval(id: "r1", summary: "Click “Send” in Mail", grantKey: "click:irreversible"))
        try render(model, name: "collapsed-approval", collapsed: true)

        _ = model.clearApprovals()
        model.status = .done
        try render(model, name: "collapsed-done", collapsed: true)
    }
}
