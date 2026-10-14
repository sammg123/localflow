import AppKit
import SwiftUI
import Testing
@testable import LocalFlow

@MainActor
@Suite("Live window rendering")
struct LivePanelRenderTests {
    /// Renders the live window offscreen. Set LOCALFLOW_SNAPSHOT_DIR to also save PNGs
    /// for a visual check, without opening anything on the real screen.
    @Test("renders at its fixed size, empty and with text", arguments: [
        "",
        "Hey, I'm testing the new live window. Words should show up here while I talk, and when I tap Fn again it pastes into whatever box I was typing in.",
        String(repeating: "This is a long hands-free dictation that keeps going past the size of the window. ", count: 6) + "These are the newest words.",
    ])
    func rendersLiveWindow(text: String) throws {
        let model = LiveModel()
        model.text = text
        model.level = 0.6
        let renderer = ImageRenderer(content: LiveView(model: model))
        renderer.scale = 2

        let image = try #require(renderer.nsImage)

        #expect(image.size == LivePanel.size)
        if let dir = ProcessInfo.processInfo.environment["LOCALFLOW_SNAPSHOT_DIR"],
           let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            let name = "live-\(text.count).png"
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
    }
}
