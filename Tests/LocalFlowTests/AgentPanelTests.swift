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
        let corner = AgentPlacement.corner(keeping: .topRight, size: size, in: visible, primaryHeight: 944,
                                           avoiding: [CGPoint(x: 600, y: 500)])
        #expect(corner == .topRight)
    }

    @Test("a click under it sends it to the other top corner")
    func movesForClick() {
        let corner = AgentPlacement.corner(keeping: .topRight, size: size, in: visible, primaryHeight: 944,
                                           avoiding: [CGPoint(x: 1300, y: 100)])
        #expect(corner == .topLeft)
    }

    @Test("a drag from under one top corner to under the other sends it to a bottom corner")
    func dragAcrossTop() {
        let corner = AgentPlacement.corner(keeping: .topRight, size: size, in: visible, primaryHeight: 944,
                                           avoiding: [CGPoint(x: 1300, y: 100), CGPoint(x: 100, y: 100)])
        #expect(corner == .bottomRight)
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
}

@MainActor
@Suite("Agent panel: rendering")
struct AgentPanelRenderTests {
    private func render(_ model: AgentModel, name: String) throws {
        let view = AgentPanelView(model: model, followUpHint: "Right ⌥, then ⌘Return to give it more",
                                  scrolls: false)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        #expect(image.size.width == AgentPanelView.width)
        guard let dir = ProcessInfo.processInfo.environment["LOCALFLOW_SNAPSHOT_DIR"],
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("agent-\(name).png"))
    }

    private func working() -> AgentModel {
        let model = AgentModel()
        model.start(task: "Find the invoice PDF from Acme in my Downloads and email it to Brady")
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
        model.reply = "Sent the Acme invoice (invoice-2026-10.pdf, 212 KB) to Brady from your Gmail account."
        try render(model, name: "done")

        model.status = .failed(AskError.claudeOutOfUsage(resetsAt: nil, detail: nil).message)
        try render(model, name: "failed")
    }
}
