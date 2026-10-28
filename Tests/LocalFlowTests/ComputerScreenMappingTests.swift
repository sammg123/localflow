import CoreGraphics
import Testing
@testable import LocalFlow

@Suite("Computer: screen mapping")
struct ComputerScreenMappingTests {
    private let laptop = ScreenMapping(displayBounds: CGRect(x: 0, y: 0, width: 1512, height: 982))
    private let second = ScreenMapping(displayBounds: CGRect(x: 1512, y: -200, width: 1920, height: 1080))

    private func expectPoint(_ point: CGPoint, _ x: Double, _ y: Double,
                             sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(abs(point.x - x) < 0.001, "x was \(point.x)", sourceLocation: sourceLocation)
        #expect(abs(point.y - y) < 0.001, "y was \(point.y)", sourceLocation: sourceLocation)
    }

    @Test("a 1512x982 display becomes a 1280-wide image with its aspect kept")
    func laptopImageSize() {
        #expect(laptop.imageSize == CGSize(width: 1280, height: 831))
        #expect(laptop.imageWidth == 1280)
        #expect(laptop.imageHeight == 831)
        #expect(laptop.displayBounds == CGRect(x: 0, y: 0, width: 1512, height: 982))
    }

    @Test("a display within the limit is never upscaled; a tall one limits its height", arguments: [
        (CGSize(width: 1024, height: 768), CGSize(width: 1024, height: 768)),
        (CGSize(width: 1280, height: 800), CGSize(width: 1280, height: 800)),
        (CGSize(width: 1080, height: 1920), CGSize(width: 720, height: 1280)),
    ])
    func imageSizes(display: CGSize, image: CGSize) {
        let mapping = ScreenMapping(displayBounds: CGRect(origin: .zero, size: display))
        #expect(mapping.imageSize == image)
    }

    @Test("corners and center map back to global points")
    func laptopPoints() {
        expectPoint(laptop.toGlobal(x: 0, y: 0), 0, 0)
        expectPoint(laptop.toGlobal(x: 640, y: 415), 756, 490.21875)
        expectPoint(laptop.toGlobal(x: 1279, y: 830), 1510.81875, 980.4375)
    }

    @Test("points past the edges are clamped inside the display")
    func clamping() {
        expectPoint(laptop.toGlobal(x: 5000, y: 5000), 1511, 981)
        expectPoint(laptop.toGlobal(x: -10, y: -10), 0, 0)
    }

    @Test("a second display with a non-zero origin maps into its own bounds")
    func secondDisplay() {
        #expect(second.imageSize == CGSize(width: 1280, height: 720))
        expectPoint(second.toGlobal(x: 0, y: 0), 1512, -200)
        expectPoint(second.toGlobal(x: 640, y: 360), 2472, 340)
        expectPoint(second.toGlobal(x: 9999, y: 9999), 3431, 879)
        expectPoint(second.toGlobal(x: -5, y: -5), 1512, -200)
    }

    @Test("only pixels inside the image count as inside")
    func contains() {
        #expect(laptop.contains(x: 0, y: 0))
        #expect(laptop.contains(x: 1279, y: 830))
        #expect(!laptop.contains(x: 1280, y: 0))
        #expect(!laptop.contains(x: 0, y: 831))
        #expect(!laptop.contains(x: -1, y: 0))
    }

    @Test("the same display always gives the same mapping")
    func deterministic() {
        let bounds = CGRect(x: 0, y: 0, width: 1512, height: 982)
        #expect(ScreenMapping(displayBounds: bounds) == ScreenMapping(displayBounds: bounds))
        #expect(laptop.pointsPerPixel == 1512.0 / 1280.0)
    }

    @Test("a display id that isn't connected gives no mapping")
    func unknownDisplay() {
        #expect(ScreenMapping(displayID: 0xDEAD_BEEF) == nil)
    }
}
