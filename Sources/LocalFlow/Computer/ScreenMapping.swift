import CoreGraphics

/// How pixels in an agent screenshot map to the global points CGEvent uses (top-left
/// origin, the same space as `CGDisplayBounds`). Worked out from the display alone, so
/// the server and the host app get the same answer for the same display.
struct ScreenMapping: Sendable, Equatable {
    /// Longest side of an agent screenshot, in pixels.
    static let maxLongEdge = 1280

    /// The display in global points.
    let displayBounds: CGRect
    /// The screenshot size: the display scaled down to fit, aspect kept, never upscaled.
    let imageSize: CGSize

    init(displayBounds: CGRect, maxLongEdge: Int = ScreenMapping.maxLongEdge) {
        let fitted = AskImageSizing.fit(width: Int(displayBounds.width.rounded()),
                                        height: Int(displayBounds.height.rounded()),
                                        maxSide: maxLongEdge)
        self.displayBounds = displayBounds
        self.imageSize = CGSize(width: max(fitted.width, 1), height: max(fitted.height, 1))
    }

    /// Nil when that display isn't connected.
    init?(displayID: CGDirectDisplayID, maxLongEdge: Int = ScreenMapping.maxLongEdge) {
        let bounds = CGDisplayBounds(displayID)
        guard !bounds.isEmpty else { return nil }
        self.init(displayBounds: bounds, maxLongEdge: maxLongEdge)
    }

    var imageWidth: Int { Int(imageSize.width) }
    var imageHeight: Int { Int(imageSize.height) }

    /// Global points per screenshot pixel.
    var pointsPerPixel: Double { displayBounds.width / imageSize.width }

    /// True when the pixel is inside the screenshot.
    func contains(x: Int, y: Int) -> Bool {
        x >= 0 && y >= 0 && x < imageWidth && y < imageHeight
    }

    /// The global point for a screenshot pixel, kept inside the display.
    func toGlobal(x: Double, y: Double) -> CGPoint {
        // Multiply before dividing: fewer rounding errors than scaling by pointsPerPixel.
        let globalX = displayBounds.minX + x * displayBounds.width / imageSize.width
        let globalY = displayBounds.minY + y * displayBounds.width / imageSize.width
        return CGPoint(x: min(max(globalX, displayBounds.minX), displayBounds.maxX - 1),
                       y: min(max(globalY, displayBounds.minY), displayBounds.maxY - 1))
    }

    /// The display with the mouse pointer on it, or the main display.
    static func displayUnderMouse() -> CGDirectDisplayID {
        guard let mouse = CGEvent(source: nil)?.location else { return CGMainDisplayID() }
        var displayID: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(mouse, 1, &displayID, &count) == .success, count > 0 else {
            return CGMainDisplayID()
        }
        return displayID
    }
}
