import AppKit
import Testing
@testable import LocalFlow

/// The Ask window following a drag, off screen: the pointer is a stand-in and the window
/// is never shown.
@MainActor
@Suite("Ask window: dragged")
struct ComposerDragTests {
    private let mouse = ScreenMouse()
    private let grab = CGPoint(x: 250, y: 31)

    @Test("it follows the pointer, and stops at the screen's edge")
    func follows() throws {
        let (panel, visible) = try inTheMiddle()
        let middle = panel.frame

        mouse.location.x += 120
        mouse.location.y -= 80
        panel.dragMoved(CGSize(width: 120, height: 80), grabbed: grab)
        #expect(panel.frame == middle.offsetBy(dx: 120, dy: -80))

        mouse.location.x = visible.minX - 300
        panel.dragMoved(CGSize(width: -900, height: 80), grabbed: grab)
        #expect(panel.frame.minX == visible.minX)
    }

    @Test("put away mid-drag, the next drag starts afresh rather than jumping")
    func putAwayMidDrag() throws {
        let (panel, _) = try inTheMiddle()
        mouse.location.x += 120
        panel.dragMoved(CGSize(width: 120, height: 0), grabbed: grab)

        // Esc closed it while the button was down: the release never came.
        panel.hide()
        let before = panel.frame

        // Grabbed again at the same place in it.
        panel.dragMoved(CGSize(width: 5, height: 0), grabbed: grab)
        #expect(panel.frame == before.offsetBy(dx: 5, dy: 0))
    }

    /// Never shown, the window sits at the screen's origin: the first move's pull brings it
    /// to the middle of the main display, with the pointer there.
    private func inTheMiddle() throws -> (AskComposerPanel, NSRect) {
        _ = NSApplication.shared
        let visible = try #require(NSScreen.main).visibleFrame
        let mouse = self.mouse
        let panel = AskComposerPanel(pointerLocation: { mouse.location })
        let size = AskComposerView.size
        mouse.location = CGPoint(x: visible.midX, y: visible.midY)
        panel.dragMoved(CGSize(width: visible.midX - size.width / 2 - panel.frame.minX,
                               height: panel.frame.minY - (visible.midY - size.height / 2)),
                        grabbed: grab)
        #expect(panel.frame == NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                                      width: size.width, height: size.height))
        return (panel, visible)
    }
}
