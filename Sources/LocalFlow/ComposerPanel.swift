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
    var onSend: (() -> Void)?
    var onCancel: (() -> Void)?

    /// How long after showing the window it's checked for having reached the screen.
    static let landingCheckDelay: Duration = .milliseconds(300)

    private var panel: ComposerWindow
    private let size: NSSize
    private let isOnScreen: @MainActor (NSWindow) -> Bool
    private var keyMonitor: Any?
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
        installKeyMonitor()
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
        removeKeyMonitor()
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

    /// Return sends, Esc cancels, and the edit shortcuts work. (LocalFlow has no Edit
    /// menu, which is what normally routes Cmd+V and friends to a text field.)
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event.window === self.panel else { return event }
                return self.handleKey(event) ? nil : event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch Int(event.keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter:
            // Shift+Return is a new line; Return while an input method is composing
            // (Japanese, Chinese) confirms the characters instead of sending.
            let composing = (panel.firstResponder as? NSTextView)?.hasMarkedText() == true
            guard !flags.contains(.shift), !composing else { return false }
            onSend?()
            return true
        case kVK_Escape:
            onCancel?()
            return true
        default:
            guard flags.contains(.command), let action = Self.editAction(for: event, shift: flags.contains(.shift)) else {
                return false
            }
            // Straight to the text box's responder chain: the app is usually not active.
            return panel.firstResponder?.tryToPerform(action, with: nil) ?? false
        }
    }

    private static func editAction(for event: NSEvent, shift: Bool) -> Selector? {
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "v": return #selector(NSText.paste(_:))
        case "c": return #selector(NSText.copy(_:))
        case "x": return #selector(NSText.cut(_:))
        case "a": return #selector(NSText.selectAll(_:))
        case "z": return shift ? Selector(("redo:")) : Selector(("undo:"))
        default: return nil
        }
    }
}
