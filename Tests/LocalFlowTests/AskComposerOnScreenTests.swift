import AppKit
import Foundation
import Testing
@testable import LocalFlow

/// The Ask window on the real screen, moved by mouse events queued for it in this process
/// (see `ScreenMouse`). Run with LOCALFLOW_E2E=1.
@MainActor
@Suite("Ask window: on screen", .serialized, .enabled(if: ProcessInfo.processInfo.environment["LOCALFLOW_E2E"] == "1"))
struct AskComposerOnScreenTests {
    private let events = ScreenMouse()

    @Test("dragged by its background it goes anywhere and opens there next time; it snaps to the top right and home")
    func dragsAndRemembers() throws {
        let (panel, first, screen) = try shown()
        defer { putAway(panel) }
        let visible = screen.visibleFrame
        let home = AgentPlacement.home(size: AskComposerView.size, in: visible)
        #expect(panel.frame == home)

        events.drag(first, from: headerPoint(in: panel.frame), by: CGVector(dx: -400, dy: 300))
        let moved = panel.frame
        #expect(abs(moved.minX - (home.minX - 400)) <= 1)
        #expect(abs(moved.minY - (home.minY + 300)) <= 1)

        // Put away and opened again: where it was left.
        putAway(panel)
        let window = try open(panel, on: screen)
        #expect(abs(panel.frame.minX - moved.minX) <= 1)
        #expect(abs(panel.frame.minY - moved.minY) <= 1)

        // Near the top right: the top right.
        let corner = AgentPlacement.frame(size: panel.frame.size, in: visible, corner: .topRight)
        events.drag(window, from: headerPoint(in: panel.frame),
                    by: CGVector(dx: corner.maxX - panel.frame.maxX - 45, dy: corner.maxY - panel.frame.maxY - 35))
        #expect(panel.frame == corner)

        // Past the edge, it stops at it (the pointer stays on this display).
        events.drag(window, from: headerPoint(in: panel.frame),
                    by: CGVector(dx: visible.minX - panel.frame.minX - 100, dy: -300))
        #expect(panel.frame.minX == visible.minX)

        // Near home: home, and it opens there again.
        events.drag(window, from: headerPoint(in: panel.frame),
                    by: CGVector(dx: home.midX - panel.frame.midX + 40, dy: home.minY - panel.frame.minY + 30))
        #expect(panel.frame == home)
        putAway(panel)
        _ = try open(panel, on: screen)
        #expect(panel.frame == home)
    }

    @Test("dragging over the words selects them rather than moving the window")
    func textStaysSelectable() throws {
        let (panel, window, _) = try shown()
        defer { putAway(panel) }
        let before = panel.frame

        // The box's first line, under the 22 pt header: 20 pt padding, 10 pt apart. All at
        // once: selecting text runs its own loop that takes them from the queue.
        let start = NSPoint(x: before.minX + 20 + 4, y: before.maxY - 20 - 22 - 10 - 10)
        let moves: [(NSEvent.EventType, NSPoint)] = [(.leftMouseDown, start)]
            + (1...10).map { (.leftMouseDragged, NSPoint(x: start.x + CGFloat($0) * 12, y: start.y)) }
            + [(.leftMouseUp, NSPoint(x: start.x + 120, y: start.y))]
        for (type, point) in moves { events.queue(type, at: point, in: window) }
        events.pump(0.5)

        #expect(panel.frame == before)
        let box = try #require(textView(in: window.contentView))
        #expect(box.selectedRange().length > 0)
    }

    @Test("a press on a button isn't a drag: ✕ closes it after it was moved")
    func buttonsStillPress() throws {
        let (panel, window, _) = try shown()
        defer { putAway(panel) }
        var closes = 0
        panel.onCancel = { closes += 1 }
        events.drag(window, from: headerPoint(in: panel.frame), by: CGVector(dx: -300, dy: 200))
        let moved = panel.frame

        // ✕ ends the header: 20 pt padding, a 22 pt button.
        events.click(NSPoint(x: moved.maxX - 20 - 11, y: moved.maxY - 20 - 11), in: window)

        #expect(closes == 1)
        #expect(panel.frame == moved)
    }

    // MARK: - Helpers

    private func shown() throws -> (AskComposerPanel, NSWindow, NSScreen) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let screen = try #require(NSScreen.main)
        let events = self.events
        let panel = AskComposerPanel(pointerLocation: { events.location })
        panel.model.reset(mode: .typing)
        panel.model.text = "What's the total on the Acme invoice from March?"
        return (panel, try open(panel, on: screen), screen)
    }

    /// Shown, and its window once on screen (one that missed the screen is swapped).
    private func open(_ panel: AskComposerPanel, on screen: NSScreen) throws -> NSWindow {
        panel.show(on: screen)
        events.pump(0.6)
        return try #require(NSApp.windows.first { $0.windowNumber == panel.windowNumber })
    }

    /// Hidden from inside the event loop: it has the keyboard, and giving that up wakes the
    /// main loop by stopping it.
    private func putAway(_ panel: AskComposerPanel) {
        events.perform { panel.hide() }
        events.pump(0.1)
    }

    /// The header between the title and the buttons: 20 pt padding, the 22 pt row.
    private func headerPoint(in frame: NSRect) -> NSPoint {
        NSPoint(x: frame.minX + 250, y: frame.maxY - 20 - 11)
    }

    private func textView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let text = view as? NSTextView { return text }
        return view.subviews.lazy.compactMap { textView(in: $0) }.first
    }
}
