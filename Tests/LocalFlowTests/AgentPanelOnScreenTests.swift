import AppKit
import Foundation
import Testing
@testable import LocalFlow

/// The agent's window on the real screen, moved by mouse events queued for it in this
/// process (see `ScreenMouse`).
@MainActor
@Suite("Agent window: on screen", .serialized, .enabled(if: ProcessInfo.processInfo.environment["LOCALFLOW_E2E"] == "1"))
struct AgentPanelOnScreenTests {
    private let events = ScreenMouse()

    @Test("dragged by its background it goes anywhere, snaps to the top right and home, and stays on screen")
    func dragsAndSnaps() throws {
        let (panel, window, screen) = try shown()
        defer { panel.hide() }
        let visible = screen.visibleFrame
        #expect(panel.frame == AgentPlacement.frame(size: panel.frame.size, in: visible, corner: .topRight))

        // Anywhere else, it stays where it's let go.
        let start = panel.frame
        drag(window, by: CGVector(dx: visible.midX - 150 - start.midX, dy: visible.midY + 200 - start.maxY))
        #expect(abs(panel.frame.midX - (visible.midX - 150)) <= 1)
        #expect(abs(panel.frame.maxY - (visible.midY + 200)) <= 1)

        // Near home: home.
        let home = AgentPlacement.home(size: panel.frame.size, in: visible)
        drag(window, by: CGVector(dx: home.midX - panel.frame.midX + 40, dy: home.minY - panel.frame.minY + 30))
        #expect(panel.frame == AgentPlacement.home(size: panel.frame.size, in: visible))

        // Near the top right: the top right.
        let corner = AgentPlacement.frame(size: panel.frame.size, in: visible, corner: .topRight)
        drag(window, by: CGVector(dx: corner.maxX - panel.frame.maxX - 45, dy: corner.maxY - panel.frame.maxY - 35))
        #expect(panel.frame == AgentPlacement.frame(size: panel.frame.size, in: visible, corner: .topRight))

        // Past the edge, it stops at it.
        drag(window, by: CGVector(dx: visible.minX - panel.frame.minX - 200, dy: -300))
        #expect(panel.frame.minX == visible.minX)
    }

    @Test("a press let go of unseen doesn't carry into the next drag")
    func abandonedPressStartsFresh() throws {
        let (panel, window, _) = try shown()
        defer { panel.hide() }
        let grab = headerPoint(in: panel.frame)
        mouse(.leftMouseDown, at: grab, in: window)
        for step in 1...10 { mouse(.leftMouseDragged, at: NSPoint(x: grab.x - CGFloat(step) * 30, y: grab.y - 100), in: window) }
        pump(0.3)
        let left = panel.frame

        // Grabbed again somewhere else in it, with no release in between.
        let again = NSPoint(x: left.minX + 120, y: left.maxY - 29)
        mouse(.leftMouseDown, at: again, in: window)
        for step in 1...10 { mouse(.leftMouseDragged, at: NSPoint(x: again.x, y: again.y - CGFloat(step) * 10), in: window) }
        mouse(.leftMouseUp, at: NSPoint(x: again.x, y: again.y - 100), in: window)
        pump(0.5)

        #expect(panel.frame.minX == left.minX)
        #expect(panel.frame.maxY == left.maxY - 100)
    }

    @Test("dragging over the reply selects it rather than moving the window")
    func replyStaysSelectable() throws {
        let (panel, window, _) = try shown()
        defer { panel.hide() }
        panel.model.status = .done
        panel.setFollowUpHint("⌘ to give it more")
        pump(0.4)
        let before = panel.frame

        // The reply's one line sits above the footer's: 18 pt padding, an 11 pt line, 12 pt
        // apart. All at once: selecting text runs its own loop that takes them from the queue.
        let start = NSPoint(x: before.minX + 18 + 4, y: before.minY + 18 + 13 + 12 + 8)
        let events: [(NSEvent.EventType, NSPoint)] = [(.leftMouseDown, start)]
            + (1...10).map { (.leftMouseDragged, NSPoint(x: start.x + CGFloat($0) * 12, y: start.y)) }
            + [(.leftMouseUp, NSPoint(x: start.x + 120, y: start.y))]
        for (type, point) in events { queue(type, at: point, in: window) }
        pump(0.5)

        #expect(panel.frame == before)
    }

    @Test("– collapses it to a bar where it is; the bar drags and snaps; the chevron opens it back up")
    func collapsesAnywhere() throws {
        let (panel, window, screen) = try shown()
        defer { panel.hide() }
        let visible = screen.visibleFrame
        drag(window, by: CGVector(dx: -500, dy: -150))
        let top = NSPoint(x: panel.frame.midX, y: panel.frame.maxY)

        // – sits left of ✕ at the top right: 18 pt padding, 22 pt buttons 8 pt apart.
        click(NSPoint(x: panel.frame.maxX - 18 - 30 - 11, y: panel.frame.maxY - 18 - 11), in: window)

        #expect(panel.frame.size == AgentPanelView.collapsedSize)
        #expect(abs(panel.frame.midX - top.x) <= 1)
        #expect(panel.frame.maxY == top.y)

        let home = AgentPlacement.home(size: AgentPanelView.collapsedSize, in: visible)
        drag(window, by: CGVector(dx: home.midX - panel.frame.midX - 30, dy: home.minY - panel.frame.minY + 25),
             grabbing: NSPoint(x: panel.frame.minX + 120, y: panel.frame.midY))
        #expect(panel.frame == home)

        // The chevron sits left of the bar's ✕: 9 pt padding, 22 pt buttons 8 pt apart.
        click(NSPoint(x: panel.frame.maxX - 9 - 30 - 11, y: panel.frame.midY), in: window)

        #expect(panel.frame.width == AgentPanelView.width)
        #expect(panel.frame == AgentPlacement.home(size: panel.frame.size, in: visible))
    }

    @Test("a press on a button isn't a drag: Deny answers after the window was moved")
    func buttonsStillPress() throws {
        let (panel, window, _) = try shown()
        defer { panel.hide() }
        var answers: [AgentAnswer] = []
        panel.onAnswer = { _, answer in answers.append(answer) }
        drag(window, by: CGVector(dx: -400, dy: -100))
        panel.model.reply = ""
        panel.model.ask(AgentApproval(id: "r1", summary: "Click “Send” in Mail", grantKey: "click:irreversible"))
        pump(0.6)
        let moved = panel.frame

        // Deny leads the card's last row, above the footer's 28 pt Stop: 18 pt padding,
        // 12 pt apart, the card's own 12 pt padding.
        click(NSPoint(x: moved.minX + 18 + 12 + 20, y: moved.minY + 18 + 28 + 12 + 12 + 14), in: window)

        #expect(answers == [.deny])
        #expect(panel.frame.minX == moved.minX)
    }

    // MARK: - Helpers

    private func shown() throws -> (AgentPanel, NSWindow, NSScreen) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let screen = try #require(NSScreen.main)
        let events = self.events
        let panel = AgentPanel(pointerLocation: { events.location })
        panel.model.start(task: "Find the invoice PDF from Acme in my Downloads and email it to Dana")
        panel.model.status = .working
        for (index, title) in ["Open Mail", "Click New Message", "Type the message"].enumerated() {
            panel.model.addStep(id: "\(index)", title: title)
            if index < 2 { panel.model.finishStep(id: "\(index)", state: .done) }
        }
        panel.model.reply = "Found it. Writing the email now."
        panel.show(on: screen)
        pump(0.6)
        let window = try #require(NSApp.windows.first { $0.isVisible && $0.frame == panel.frame })
        return (panel, window, screen)
    }

    /// The header between the status and the buttons: 18 pt padding, the 22 pt row.
    private func headerPoint(in frame: NSRect) -> NSPoint {
        NSPoint(x: frame.minX + 230, y: frame.maxY - 18 - 11)
    }

    /// Grabs the header (or `grabbing`), moves in steps the way a hand does, lets go.
    private func drag(_ window: NSWindow, by delta: CGVector, grabbing: NSPoint? = nil) {
        events.drag(window, from: grabbing ?? headerPoint(in: window.frame), by: delta)
    }

    private func click(_ point: NSPoint, in window: NSWindow) { events.click(point, in: window) }

    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) {
        events.press(type, at: point, in: window)
    }

    private func queue(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) {
        events.queue(type, at: point, in: window)
    }

    private func pump(_ seconds: TimeInterval) { events.pump(seconds) }
}
