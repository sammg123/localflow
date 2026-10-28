import AppKit
import SwiftUI
import Testing
@testable import LocalFlow

@MainActor
@Suite("Hands-free window rendering")
struct DictationWindowRenderTests {
    /// Renders the hands-free window offscreen. Set LOCALFLOW_SNAPSHOT_DIR to also save
    /// PNGs for a visual check, without opening anything on the real screen.
    @Test("renders at its fixed size while talking, writing down and paused", arguments: [
        (ComposerMode.voice, ""),
        (ComposerMode.voice, "Hey, I'm testing the new live window. Words should show up here while I talk, and when I tap Fn it pauses so I can fix things up."),
        (ComposerMode.voice, String(repeating: "This is a long hands-free dictation that keeps going past the size of the window. ", count: 6) + "These are the newest words."),
        (ComposerMode.finishing, "Hello there."),
        (ComposerMode.typing, "Hello there, this is paused and editable."),
        (ComposerMode.typing, ""),
    ])
    func rendersWindow(mode: ComposerMode, text: String) throws {
        let model = ComposerModel()
        model.mode = mode
        model.text = text
        model.level = 0.6
        model.keyName = "Fn"
        let renderer = ImageRenderer(content: DictationComposerView(model: model))
        renderer.scale = 2

        let image = try #require(renderer.nsImage)

        #expect(image.size == DictationComposerView.size)
        if let dir = ProcessInfo.processInfo.environment["LOCALFLOW_SNAPSHOT_DIR"],
           let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            let name = "dictation-\(mode)-\(text.count).png"
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
    }
}
