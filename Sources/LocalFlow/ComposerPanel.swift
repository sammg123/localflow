import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Borderless panels refuse key status by default; this one takes typing.
private final class ComposerWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// A floating window where words are written: the Ask window and the hands-free
/// dictation window. Non-activating, so the app being worked in stays frontmost, but
/// it takes the keyboard while open so typing and Return land here.
@MainActor
class ComposerPanel: ComposerSurface {
    let model = ComposerModel()
    var onSend: (() -> Void)? {
        didSet { keys.onSend = onSend }
    }
    var onCancel: (() -> Void)? {
        didSet { keys.onCancel = onCancel }
    }
    /// ⌘ switches Ask and agent mode and ⌘I Instant (the Ask window).
    var takesModeKeys: Bool {
        get { keys.takesModeKeys }
        set { keys.takesModeKeys = newValue }
    }

    /// How long after showing the window it's checked for having reached the screen.
    static let landingCheckDelay: Duration = .milliseconds(300)

    private var panel: ComposerWindow
    private let size: NSSize
    private let isOnScreen: @MainActor (NSWindow) -> Bool
    private lazy var keys = ComposerKeys(model: model) { [weak self] in self?.panel }
    /// Bumped per show and hide, so only the latest show's landing check runs.
    private var landingCheck = 0

    var isVisible: Bool { panel.isVisible }
    var isKey: Bool { panel.isKeyWindow }
    var frame: NSRect { panel.frame }
    // For the on-screen tests.
    var windowNumber: Int { panel.windowNumber }
    var isOnScreenNow: Bool { isOnScreen(panel) }

    init(size: NSSize, isOnScreen: @escaping @MainActor (NSWindow) -> Bool = ComposerPanel.windowIsOnScreen) {
        self.size = size
        self.isOnScreen = isOnScreen
        panel = Self.makeWindow(size: size)
    }

    private static func makeWindow(size: NSSize) -> ComposerWindow {
        let window = ComposerWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        window.level = .screenSaver // above native-fullscreen apps, same as the pill
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return window
    }

    /// Whether the window server has the window on the screen the user is looking at.
    static func windowIsOnScreen(_ window: NSWindow) -> Bool {
        guard window.windowNumber > 0,
              let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(window.windowNumber))
                as? [[String: Any]] else { return false }
        return info.first?[kCGWindowIsOnscreen as String] as? Bool ?? false
    }

    func setContent<Content: View>(_ view: Content) {
        panel.contentView = FirstClickHostingView(rootView: view)
    }

    func show(on screen: NSScreen?) {
        position(on: screen ?? NSScreen.main)
        if !panel.isVisible {
            panel.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
                panel.animator().alphaValue = 1
            }
        }
        panel.orderFrontRegardless()
        panel.makeKey()
        keys.install()
        landingCheck += 1
        confirmLanded(isRetry: false)
    }

    /// LocalFlow's long-lived windows have been seen to stop reaching the screen (over a
    /// full-screen app) while a fresh window always does, so one that misses is swapped
    /// for a fresh one, once. Logged without any text, to find the cause.
    private func confirmLanded(isRetry: Bool) {
        let shown = panel
        let check = landingCheck
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.landingCheckDelay)
            guard let self, self.landingCheck == check, self.panel === shown, shown.isVisible,
                  !self.isOnScreen(shown) else { return }
            let state = "app active \(NSApp.isActive), hidden \(NSApp.isHidden), on active Space \(shown.isOnActiveSpace)"
            guard !isRetry else {
                FlowLog.shared.write("composer window still off screen after a fresh one (\(state))")
                return
            }
            FlowLog.shared.write("composer window didn't reach the screen (\(state)); using a fresh one")
            self.swapInFreshWindow()
            self.panel.orderFrontRegardless()
            self.panel.makeKey()
            self.confirmLanded(isRetry: true)
        }
    }

    /// Moves the content, and the text box holding the keyboard, into a new window.
    private func swapInFreshWindow() {
        let old = panel
        let fresh = Self.makeWindow(size: size)
        let content = old.contentView
        let focused = old.firstResponder as? NSView
        old.contentView = NSView()
        fresh.contentView = content
        if let focused, let content, focused.isDescendant(of: content) { fresh.makeFirstResponder(focused) }
        fresh.setFrame(old.frame, display: false)
        fresh.alphaValue = 1
        old.orderOut(nil)
        panel = fresh
    }

    func takeKeyboard() {
        guard panel.isVisible else { return }
        panel.makeKey()
    }

    func hide() {
        keys.remove()
        landingCheck += 1
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }

    func updateLevel(_ level: Float) {
        guard panel.isVisible else { return }
        model.level = model.level * 0.6 + level * 0.4
    }

    private func position(on screen: NSScreen?) {
        guard let screen else { return }
        let visible = screen.visibleFrame
        panel.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.minY + 28,
                              width: size.width, height: size.height),
                       display: false)
    }
}
