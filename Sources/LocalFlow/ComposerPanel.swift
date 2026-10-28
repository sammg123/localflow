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

    private let panel: ComposerWindow
    private let size: NSSize
    private var keyMonitor: Any?

    var isVisible: Bool { panel.isVisible }
    var isKey: Bool { panel.isKeyWindow }
    var frame: NSRect { panel.frame }

    init(size: NSSize) {
        self.size = size
        panel = ComposerWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .screenSaver // above native-fullscreen apps, same as the pill
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
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
    }

    func takeKeyboard() {
        guard panel.isVisible else { return }
        panel.makeKey()
    }

    func hide() {
        removeKeyMonitor()
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
