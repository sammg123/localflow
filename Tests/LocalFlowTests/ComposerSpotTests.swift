import AppKit
import Testing
@testable import LocalFlow

/// Where the Ask window opens: home until it's dragged, then where it was let go, on
/// whichever display Ask opens on.
@Suite("Ask window: where it opens")
struct ComposerSpotTests {
    private let size = AskComposerView.size
    private let laptop = NSRect(x: 0, y: 0, width: 1512, height: 944)
    private let monitor = NSRect(x: 1512, y: -200, width: 2560, height: 1400)

    @Test("never dragged, it opens at home: the bottom middle")
    func opensHome() {
        #expect(ComposerSpot.home.frame(size: size, in: laptop) == AgentPlacement.home(size: size, in: laptop))
        #expect(ComposerSpot.home.frame(size: size, in: monitor) == AgentPlacement.home(size: size, in: monitor))
    }

    @Test("let go near home or the top right, it snaps there")
    func snaps() {
        let home = AgentPlacement.home(size: size, in: laptop)
        #expect(ComposerSpot.dropped(home.offsetBy(dx: 40, dy: 30), in: laptop) == .home)

        let corner = AgentPlacement.frame(size: size, in: laptop, corner: .topRight)
        let nearCorner = ComposerSpot.dropped(corner.offsetBy(dx: -45, dy: -35), in: laptop)
        #expect(nearCorner == .corner(.topRight))
        #expect(nearCorner.frame(size: size, in: laptop) == corner)
    }

    @Test("let go anywhere else, it opens there next time, and in the same place on another display")
    func keepsSpot() {
        let dropped = NSRect(x: 300, y: 500, width: size.width, height: size.height)
        let spot = ComposerSpot.dropped(dropped, in: laptop)

        let again = spot.frame(size: size, in: laptop)
        #expect(abs(again.minX - dropped.minX) <= 0.5)
        #expect(abs(again.minY - dropped.minY) <= 0.5)

        // Its top middle sits the same share of the way across and up.
        let there = spot.frame(size: size, in: monitor)
        #expect(abs((there.midX - monitor.minX) / monitor.width - dropped.midX / laptop.width) < 0.001)
        #expect(abs((there.maxY - monitor.minY) / monitor.height - dropped.maxY / laptop.height) < 0.001)
    }

    @Test("dropped past an edge, or opened on a smaller display, it's wholly on screen")
    func staysOnScreen() {
        let past = ComposerSpot.dropped(NSRect(x: -200, y: 800, width: size.width, height: size.height), in: laptop)
        let kept = past.frame(size: size, in: laptop)
        #expect(kept.minX == laptop.minX)
        #expect(kept.maxY == laptop.maxY)

        let small = NSRect(x: 0, y: 0, width: 800, height: 600)
        let right = ComposerSpot.dropped(NSRect(x: 1040, y: 360, width: size.width, height: size.height), in: laptop)
        #expect(small.contains(right.frame(size: size, in: small)))
    }
}
