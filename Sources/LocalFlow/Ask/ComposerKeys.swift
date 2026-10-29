import AppKit
import Carbon.HIToolbox

/// A tap of ⌘ on its own (down and up quickly, nothing else pressed in between): what
/// switches the box between Ask and agent mode. Pure, so every sequence is testable.
struct CommandTap {
    /// Both ⌘ keys, less one that's the Ask or dictation key (its taps are already taken).
    static func keys(askKey: HotkeyChoice?, dictationKey: HotkeyChoice) -> Set<UInt16> {
        let both: Set<UInt16> = [UInt16(kVK_Command), UInt16(kVK_RightCommand)]
        let taken = [askKey, dictationKey].contains(.rightCommand)
        return taken ? both.subtracting([UInt16(kVK_RightCommand)]) : both
    }

    let keys: Set<UInt16>
    private var downAt: TimeInterval?

    init(keys: Set<UInt16>) {
        self.keys = keys
    }

    /// ⌘ and no other modifier (Caps Lock doesn't count).
    static func isCommandOnly(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.intersection(counted) == .command
    }

    private static let counted: NSEvent.ModifierFlags = [.command, .shift, .option, .control, .function]

    /// A modifier went down or up. True when this ends a tap.
    mutating func flagsChanged(keyCode: UInt16, flags: NSEvent.ModifierFlags, at time: TimeInterval) -> Bool {
        let held = flags.intersection(Self.counted)
        guard keys.contains(keyCode) else {
            downAt = nil
            return false
        }
        if held == .command {
            if downAt == nil { downAt = time }
            return false
        }
        guard held.isEmpty, let start = downAt else {
            downAt = nil
            return false
        }
        downAt = nil
        return time - start < HotkeyMonitor.tapThreshold
    }

    /// Another key or a click while ⌘ was down: it was a shortcut, not a tap.
    mutating func interrupted() {
        downAt = nil
    }
}

/// The keys a window with a box takes while it has the keyboard: Return sends (⌘Return
/// too; Shift+Return is a new line), Esc cancels, the edit shortcuts work (LocalFlow has
/// no Edit menu to route them, and the app is usually not active), and in a box with
/// modes a tap of ⌘ switches Ask and agent mode and ⌘I turns Instant Edits on or off.
@MainActor
final class ComposerKeys {
    var onSend: (() -> Void)?
    var onCancel: (() -> Void)?
    /// ⌘ and ⌘I change the mode (the Ask box); the hands-free box has no modes.
    var takesModeKeys = false

    private let model: ComposerModel
    private let window: @MainActor () -> NSWindow?
    private var monitor: Any?
    private var tap = CommandTap(keys: [])

    init(model: ComposerModel, window: @escaping @MainActor () -> NSWindow?) {
        self.model = model
        self.window = window
    }

    func install() {
        guard monitor == nil else { return }
        tap = CommandTap(keys: model.modeKeys)
        let events: NSEvent.EventTypeMask = [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        monitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let window = self.window(), event.window === window else { return event }
                return self.handle(event, in: window) ? nil : event
            }
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent, in window: NSWindow) -> Bool {
        // A ⌘-click is a shortcut, not a tap.
        if event.type != .keyDown, event.type != .flagsChanged {
            tap.interrupted()
            return false
        }
        guard event.type == .keyDown else {
            if takesModeKeys, tap.flagsChanged(keyCode: event.keyCode, flags: event.modifierFlags,
                                               at: event.timestamp) {
                model.toggleAgentMode()
            }
            return false
        }
        tap.interrupted()
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch Int(event.keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter:
            // Return while an input method is composing (Japanese, Chinese) confirms the
            // characters instead of sending.
            let composing = (window.firstResponder as? NSTextView)?.hasMarkedText() == true
            guard !flags.contains(.shift), !composing else { return false }
            onSend?()
            return true
        case kVK_Escape:
            onCancel?()
            return true
        case kVK_ANSI_I where takesModeKeys && flags == .command:
            if !model.toggleInstant() { NSSound.beep() }
            return true
        default:
            guard flags.contains(.command), let action = Self.editAction(for: event, shift: flags.contains(.shift)) else {
                return false
            }
            return window.firstResponder?.tryToPerform(action, with: nil) ?? false
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
