import AppKit
import SwiftUI
import Testing
@testable import LocalFlow

/// Puts a small window on screen for a moment. Run with LOCALFLOW_E2E=1.
@MainActor
@Suite("Composer window reaches the screen", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["LOCALFLOW_E2E"] == "1"))
struct ComposerPanelTests {
    @Test("a window that didn't reach the screen is swapped for a fresh one, once")
    func rebuildsWhenStuck() async throws {
        var checks = 0
        let panel = ComposerPanel(size: NSSize(width: 200, height: 80)) { _ in
            checks += 1
            return checks > 1 // the first window "missed"; the fresh one lands
        }
        panel.setContent(Text("probe"))
        panel.show(on: NSScreen.main)
        let first = panel.windowNumber

        try await Task.sleep(for: .milliseconds(900))

        #expect(panel.windowNumber != first)
        #expect(panel.isVisible)
        #expect(checks == 2)
        panel.hide()
        #expect(!panel.isVisible)
    }

    @Test("a window that reached the screen is left alone")
    func keepsWindowThatLanded() async throws {
        var checks = 0
        let panel = ComposerPanel(size: NSSize(width: 200, height: 80)) { _ in
            checks += 1
            return true
        }
        panel.setContent(Text("probe"))
        panel.show(on: NSScreen.main)
        let first = panel.windowNumber

        try await Task.sleep(for: .milliseconds(600))

        #expect(panel.windowNumber == first)
        #expect(checks == 1)
        panel.hide()
    }

    @Test("the text box keeps the keyboard when the window is swapped")
    func swapKeepsFocus() async throws {
        var checks = 0
        let panel = ComposerPanel(size: NSSize(width: 200, height: 80)) { _ in
            checks += 1
            return checks > 1
        }
        let holder = TextBoxHolder()
        panel.setContent(TextBox(holder: holder))
        panel.show(on: NSScreen.main)
        try await Task.sleep(for: .milliseconds(100))
        // The second of two boxes, so a window that just picks its first box fails.
        let box = try #require(holder.views.last)
        #expect(box.window?.makeFirstResponder(box) == true)
        let first = panel.windowNumber

        try await Task.sleep(for: .milliseconds(800))

        #expect(panel.windowNumber != first)
        #expect(box.window?.firstResponder === box)
        panel.hide()
    }

    @Test("hiding and showing again quickly checks once, for the latest show")
    func quickReshowChecksOnce() async throws {
        var checks = 0
        let panel = ComposerPanel(size: NSSize(width: 200, height: 80)) { _ in
            checks += 1
            return true
        }
        panel.setContent(Text("probe"))
        panel.show(on: NSScreen.main)
        try await Task.sleep(for: .milliseconds(100))
        panel.hide()
        panel.show(on: NSScreen.main)

        try await Task.sleep(for: .milliseconds(700))

        #expect(checks == 1)
        panel.hide()
    }

    @Test("the real check sees a shown window on screen and a hidden one off it")
    func realCheck() async throws {
        let panel = ComposerPanel(size: NSSize(width: 200, height: 80))
        panel.setContent(Text("probe"))
        panel.show(on: NSScreen.main)
        try await Task.sleep(for: .milliseconds(300))
        #expect(panel.isOnScreenNow)
        panel.hide()
        try await Task.sleep(for: .milliseconds(300)) // the window server catches up
        #expect(!panel.isOnScreenNow)
    }
}

@MainActor
private final class TextBoxHolder {
    var views: [NSTextView] = []
}

/// Two plain text views that can hold the keyboard, like the composer's text box.
private struct TextBox: NSViewRepresentable {
    let holder: TextBoxHolder

    func makeNSView(context: Context) -> NSStackView {
        let views = [NSTextView(), NSTextView()]
        holder.views = views
        return NSStackView(views: views)
    }

    func updateNSView(_ nsView: NSStackView, context: Context) {}
}
