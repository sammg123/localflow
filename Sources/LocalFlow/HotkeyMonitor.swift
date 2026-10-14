import AppKit
import Carbon.HIToolbox

/// What releasing a Control + hotkey press means. A quick tap pastes the last
/// transcript again; a hold is command mode (edit the selection by voice).
enum ControlHotkeyAction: Equatable {
    case pasteLastTranscript
    case finishCommand
    case commandUnavailable

    static func forRelease(held: TimeInterval, commandAvailable: Bool) -> ControlHotkeyAction {
        if held < HotkeyMonitor.tapThreshold { return .pasteLastTranscript }
        return commandAvailable ? .finishCommand : .commandUnavailable
    }
}

/// Watches for the push-to-talk modifier via global/local NSEvent monitors.
/// Global monitors for key events require Accessibility trust (which we need anyway to paste),
/// so this adds no extra permission beyond what pasting requires.
///
/// Gesture model:
///  - Press and hold (>= tapThreshold): push-to-talk. Release ends the utterance.
///  - Hold with Control also down: command mode (edit the selected text by voice).
///  - Tap, then tap again quickly: hands-free toggle on. Next tap (or Escape) stops.
///  - Escape while recording: cancel, discard audio.
@MainActor
final class HotkeyMonitor {
    /// `command` is true when Control was held as the press began (Fn+Ctrl gesture).
    var onPressBegan: ((_ command: Bool) -> Void)?
    var onPressEnded: ((_ heldDuration: TimeInterval) -> Void)?
    var onDoubleTap: (() -> Void)?
    var onEscape: (() -> Void)?

    /// Set true while recording so the Escape monitor is live.
    var escapeEnabled = false

    private var monitors: [Any] = []
    private var pressStartedAt: TimeInterval?
    private var lastTapEndedAt: TimeInterval = 0
    private var swallowRelease = false

    nonisolated static let tapThreshold: TimeInterval = 0.35
    static let doubleTapWindow: TimeInterval = 0.45

    private var choice: HotkeyChoice

    init(choice: HotkeyChoice) {
        self.choice = choice
    }

    func updateHotkey(_ newChoice: HotkeyChoice) {
        choice = newChoice
        // Reset any half-tracked press so a stale "down" can't wedge the state machine.
        pressStartedAt = nil
        swallowRelease = false
    }

    /// Called when the current press was consumed as an action on key-DOWN (e.g. the tap
    /// that stops hands-free): its release must not count as a tap or feed double-tap.
    func swallowCurrentPress() {
        swallowRelease = true
    }

    func startMonitoring() {
        stopMonitoring()
        let flagsHandler: (NSEvent) -> Void = { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        let keyHandler: (NSEvent) -> Void = { [weak self] event in
            self?.handleKeyDown(event)
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flagsHandler) {
            monitors.append(m)
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: keyHandler) {
            monitors.append(m)
        }
        // Local monitors so the hotkey also works while a LocalFlow window is frontmost.
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            flagsHandler(event)
            return event
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.escapeEnabled == true, event.keyCode == UInt16(kVK_Escape) {
                self?.onEscape?()
                return nil
            }
            return event
        } as Any)
    }

    func stopMonitoring() {
        for m in monitors {
            NSEvent.removeMonitor(m)
        }
        monitors.removeAll()
        pressStartedAt = nil
    }

    private func handleKeyDown(_ event: NSEvent) {
        guard escapeEnabled, event.keyCode == UInt16(kVK_Escape) else { return }
        onEscape?()
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let isDown = isHotkeyDown(event)
        if isDown, pressStartedAt == nil {
            pressStartedAt = ProcessInfo.processInfo.systemUptime
            // Command gesture: Control held together with the hotkey (not available when
            // the hotkey itself is Ctrl+Opt). Mode is fixed at press time.
            let command = choice != .controlOption && event.modifierFlags.contains(.control)
            onPressBegan?(command)
        } else if !isDown, let start = pressStartedAt {
            pressStartedAt = nil
            if swallowRelease {
                swallowRelease = false
                lastTapEndedAt = 0
                return
            }
            let now = ProcessInfo.processInfo.systemUptime
            let held = now - start
            if held < Self.tapThreshold, now - lastTapEndedAt < Self.doubleTapWindow {
                lastTapEndedAt = 0
                onDoubleTap?()
            } else {
                if held < Self.tapThreshold { lastTapEndedAt = now }
                onPressEnded?(held)
            }
        }
    }

    // Device-dependent modifier bits (IOLLEvent.h): the side-agnostic .option/.command
    // flags stay set while the OPPOSITE-side key is held, which would wedge recording on.
    private static let rightOptionMask: UInt = 0x40  // NX_DEVICERALTKEYMASK
    private static let rightCommandMask: UInt = 0x10 // NX_DEVICERCMDKEYMASK

    /// Whether, per this flagsChanged event, our chosen hotkey is currently held.
    private func isHotkeyDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags
        switch choice {
        case .fnKey:
            // Fn arrives as flagsChanged with keyCode 63; the .function bit tracks hold state.
            guard event.keyCode == UInt16(kVK_Function) else { return pressStartedAt != nil && flags.contains(.function) }
            return flags.contains(.function)
        case .rightOption:
            guard event.keyCode == UInt16(kVK_RightOption) else { return pressStartedAt != nil }
            return flags.rawValue & Self.rightOptionMask != 0
        case .rightCommand:
            guard event.keyCode == UInt16(kVK_RightCommand) else { return pressStartedAt != nil }
            return flags.rawValue & Self.rightCommandMask != 0
        case .controlOption:
            // Down when both are held; up when either is released.
            return flags.contains(.control) && flags.contains(.option)
        }
    }
}
