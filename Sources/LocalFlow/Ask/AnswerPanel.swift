import AppKit
import SwiftUI

/// Lets the ✕ and copy buttons work on the first click, without making the panel key.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The floating answer bubble, where the pill appears. Non-activating like the pill and
/// the live window, so clicking ✕ never pulls focus out of the app being worked in, but
/// unlike them it takes clicks.
@MainActor
final class AnswerPanel {
    static let width: CGFloat = 460
    /// Taller answers scroll inside the bubble.
    static let maxBodyHeight: CGFloat = 380

    let model = AnswerModel()
    var onClose: (() -> Void)?

    private let panel: NSPanel
    private let hosting: NSHostingView<AnswerView>
    private var screen: NSScreen?
    private var resizeObserver: NSObjectProtocol?

    var isVisible: Bool { panel.isVisible }
    var frame: NSRect { panel.frame }

    init(closeHint: String) {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .screenSaver // above native-fullscreen apps, same as the pill
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let pasteboardCopy = { [model] in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(model.answer, forType: .string)
        }
        hosting = FirstClickHostingView(rootView: AnswerView(model: model, closeHint: closeHint))
        panel.contentView = hosting
        hosting.rootView = AnswerView(
            model: model,
            closeHint: closeHint,
            onCopy: { pasteboardCopy() },
            onClose: { [weak self] in self?.onClose?() }
        )
        // The hosting view sizes the window to the answer, keeping the TOP edge fixed.
        // Re-pin the bottom edge after every resize so the bubble grows upward.
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pinToBottom() }
        }
    }

    func updateCloseHint(_ hint: String) {
        hosting.rootView.closeHint = hint
    }

    func show(on screen: NSScreen?) {
        model.reset()
        self.screen = screen
        hosting.layoutSubtreeIfNeeded()
        pinToBottom()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }

    /// Bottom edge where the pill sits, horizontally centered on the working display.
    private func pinToBottom() {
        guard let screen = screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let origin = NSPoint(x: visible.midX - panel.frame.width / 2, y: visible.minY + 28)
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
        panel.invalidateShadow()
    }
}
