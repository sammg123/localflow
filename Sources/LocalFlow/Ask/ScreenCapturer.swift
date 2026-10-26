import AppKit
import ScreenCaptureKit

enum AskImageSizing {
    /// Longest side sent to the model. A 1512-point laptop screen goes at full size
    /// (about 1,500 image tokens, enough to read menu-bar text); bigger displays scale down.
    static let maxSide = 1920

    static func fit(width: Int, height: Int, maxSide: Int = maxSide) -> (width: Int, height: Int) {
        let longest = max(width, height)
        guard longest > maxSide, longest > 0 else { return (width, height) }
        let scale = Double(maxSide) / Double(longest)
        return (Int((Double(width) * scale).rounded()), Int((Double(height) * scale).rounded()))
    }
}

/// Takes the screenshot Ask answers from: the display under the mouse, in points,
/// with LocalFlow's own windows (the glow, the pill, the bubble) left out.
@MainActor
enum ScreenCapturer {
    /// The display the user is working on: the one with the mouse pointer.
    static func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    static func capturePNG(of screen: NSScreen) async throws -> Data {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let displayID = screen.deviceDescription[key] as? CGDirectDisplayID else {
            throw AskError.screenCaptureFailed("no display under the mouse")
        }
        // All windows, not just on-screen ones, so LocalFlow is listed (and left out)
        // even in the instant before the outline and pill appear.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw AskError.screenCaptureFailed("that display isn't available to capture")
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownApp = content.applications.filter { $0.processID == ownPID }
        let filter = SCContentFilter(display: display, excludingApplications: ownApp, exceptingWindows: [])

        let size = AskImageSizing.fit(width: display.width, height: display.height)
        let configuration = SCStreamConfiguration()
        configuration.width = size.width
        configuration.height = size.height
        // The pointer stays in: "what is this?" usually means the thing it's on.
        configuration.showsCursor = true

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw AskError.screenCaptureFailed("couldn't encode the image")
        }
        return png
    }
}
