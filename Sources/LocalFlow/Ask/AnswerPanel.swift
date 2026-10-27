import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Lets buttons work on the first click, without making the panel key first.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A click anywhere in the bubble, the scrolling answer included, brings it back in
/// front of the apps that were clicked over it. Pressing on the answer's words takes the
/// keyboard so Cmd+C reaches the selection (the text view asks for it; buttons don't, so
/// a click on one leaves the keyboard with the app being worked in).
private final class AnswerWindow: NSPanel {
    /// Whether the latest press landed on the answer's words.
    private var pressedOnText = false

    override var canBecomeKey: Bool { pressedOnText || isKeyWindow }

    /// Only a fresh press on the words takes the keyboard again, never a later makeKey.
    override func resignKey() {
        pressedOnText = false
        super.resignKey()
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            orderFrontRegardless()
            pressedOnText = isText(at: event.locationInWindow)
        }
        super.sendEvent(event)
    }

    /// The selectable answer is a text field over a text view; the buttons and the rest
    /// are drawn by SwiftUI.
    private func isText(at point: NSPoint) -> Bool {
        var view = contentView?.superview?.hitTest(point)
        while let current = view {
            if current is NSTextField || current is NSText { return true }
            view = current.superview
        }
        return false
    }
}

/// The answer bubble, where the pill appears. It opens floating over everything, so the
/// app being worked in can't come back in front of it before it's seen; the first click
/// anywhere else drops it to an ordinary window, so that app (and any app clicked after)
/// comes in front. Non-activating, so clicking it never takes focus from the app being
/// worked in. Minimizes to a chip in the corner (the – button, Esc, or by itself once
/// another window covers it completely) and expands back from the chip.
@MainActor
final class AnswerPanel {
    static let width: CGFloat = 460
    /// Taller answers scroll inside the bubble.
    static let maxBodyHeight: CGFloat = 380
    /// Covering checks wait this long after the bubble appears, while it fades in.
    private static let settleTime: TimeInterval = 0.4

    let model = AnswerModel()
    var onClose: (() -> Void)?
    var onMinimizeChange: (() -> Void)?

    private let panel: NSPanel
    private let hosting: NSHostingView<AnswerView>
    private var chip: AnswerChipPanel!
    private var screen: NSScreen?
    private var shownAt = Date.distantPast
    private var settleCheck: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    /// Waiting for the first click outside the bubble, while it floats.
    private var clickWatchers: [Any] = []
    private var keyMonitor: Any?

    private(set) var isMinimized = false
    /// Up in any form: the full bubble or the chip.
    var isVisible: Bool { panel.isVisible || chip.isVisible }
    var frame: NSRect { panel.frame }
    var isKey: Bool { panel.isKeyWindow }
    var chipFrame: NSRect { chip.frame }

    init(closeHint: String) {
        panel = AnswerWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .normal
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
            onMinimize: { [weak self] in self?.minimize() },
            onClose: { [weak self] in self?.onClose?() }
        )
        chip = AnswerChipPanel(
            model: model,
            onExpand: { [weak self] in self?.expand() },
            onClose: { [weak self] in self?.onClose?() }
        )
        observe()
    }

    func updateCloseHint(_ hint: String) {
        hosting.rootView.closeHint = hint
    }

    func show(question: String, on screen: NSScreen?) {
        model.reset()
        model.question = question
        self.screen = screen
        isMinimized = false
        chip.hide()
        present()
    }

    func hide() {
        settleCheck?.cancel()
        stopWatchingClicks()
        removeKeyMonitor()
        isMinimized = false
        chip.hide()
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }

    func minimize() {
        guard panel.isVisible, !isMinimized else { return }
        settleCheck?.cancel()
        stopWatchingClicks()
        removeKeyMonitor()
        isMinimized = true
        panel.orderOut(nil)
        chip.show(on: screen)
        onMinimizeChange?()
    }

    func expand() {
        guard isMinimized else { return }
        isMinimized = false
        chip.hide()
        present()
        onMinimizeChange?()
    }

    private func present() {
        // Fit the content now: a question set after the first layout, or a long one,
        // didn't always grow the window and squeezed out the working row or a line.
        hosting.layoutSubtreeIfNeeded()
        panel.setContentSize(hosting.fittingSize)
        pinToBottom()
        shownAt = Date()
        panel.alphaValue = 0
        panel.level = .floating
        panel.orderFrontRegardless()
        watchForClickElsewhere()
        installKeyMonitor()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
            panel.animator().alphaValue = 1
        }
    }

    private func observe() {
        let center = NotificationCenter.default
        // The hosting view sizes the window to the answer, keeping the TOP edge fixed.
        // Re-pin the bottom edge after every resize so the bubble grows upward.
        observers.append(center.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pinToBottom() }
        })
        observers.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkCovered() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated { self?.otherAppActivated(pid) }
        })
    }

    /// Clicks in other apps (global) and in LocalFlow's other windows (local).
    private func watchForClickElsewhere() {
        guard clickWatchers.isEmpty else { return }
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] event in
            let underClick = event.cgEvent?.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent) ?? 0
            MainActor.assumeIsolated {
                self?.stepBack(behind: underClick > 0 ? Int(underClick)
                    : NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0))
            }
        }) {
            clickWatchers.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: clicks, handler: { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window !== self.panel { self.stepBack(behind: event.windowNumber) }
            }
            return event
        }) {
            clickWatchers.append(local)
        }
    }

    private func stopWatchingClicks() {
        clickWatchers.forEach(NSEvent.removeMonitor)
        clickWatchers = []
    }

    /// Cmd+C and Cmd+A for selected words. (LocalFlow has no Edit menu, which is what
    /// normally routes them, and the app is usually not active.)
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event.window === self.panel, let action = Self.editAction(for: event) else { return event }
                return self.panel.firstResponder?.tryToPerform(action, with: nil) == true ? nil : event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    static func editAction(for event: NSEvent) -> Selector? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command else { return nil }
        switch Int(event.keyCode) {
        case kVK_ANSI_C: return #selector(NSText.copy(_:))
        case kVK_ANSI_A: return #selector(NSText.selectAll(_:))
        default: return nil
        }
    }

    /// Becomes an ordinary window behind the clicked one, so that app comes in front
    /// however its own click and this one race.
    private func stepBack(behind clicked: Int) {
        stopWatchingClicks()
        panel.level = .normal
        guard let id = CGWindowID(exactly: clicked),
              let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]],
              let number = Self.windowToGoBehind(clicked, among: windows) else { return }
        panel.order(.below, relativeTo: number)
    }

    /// Switching apps without a click (Cmd-Tab) counts as clicking that app. The app being
    /// worked in taking the keyboard back as the Ask window closes doesn't.
    private func otherAppActivated(_ pid: pid_t?) {
        guard let pid, pid != ProcessInfo.processInfo.processIdentifier, !clickWatchers.isEmpty,
              Date().timeIntervalSince(shownAt) >= Self.settleTime else { return }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        stepBack(behind: Self.frontWindow(of: pid, among: windows) ?? 0)
    }

    /// Completely covered by another window: tuck into the chip so it's one click away
    /// instead of lost behind it.
    private func checkCovered() {
        guard panel.isVisible, !isMinimized, !panel.occlusionState.contains(.visible) else { return }
        let settling = Self.settleTime - Date().timeIntervalSince(shownAt)
        guard settling <= 0 else {
            settleCheck?.cancel()
            settleCheck = Task { [weak self] in
                try? await Task.sleep(for: .seconds(settling))
                guard !Task.isCancelled else { return }
                self?.checkCovered()
            }
            return
        }
        guard isCoveredByAWindow() else { return }
        minimize()
    }

    /// Occlusion also reports a locked screen, a sleeping display and Mission Control,
    /// none of which should tuck the bubble away; only a real window over it does.
    private func isCoveredByAWindow() -> Bool {
        let options: CGWindowListOption = [.optionOnScreenAboveWindow, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, CGWindowID(panel.windowNumber)) as? [[String: Any]] else {
            return false
        }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? panel.frame.maxY
        let frame = panel.frame
        let bubble = CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
        return Self.isCovered(bubble, by: windows)
    }

    /// Whether one ordinary, visible window (as CGWindowListCopyWindowInfo lists them)
    /// sits over all of `bubble`. Both in top-left screen coordinates.
    static func isCovered(_ bubble: CGRect, by windows: [[String: Any]]) -> Bool {
        windows.contains { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
            return rect.contains(bubble)
        }
    }

    /// The clicked window, when it's an ordinary app window (as CGWindowListCopyWindowInfo
    /// lists them) the bubble can go behind. The desktop, Dock and menu bar don't count.
    static func windowToGoBehind(_ number: Int, among windows: [[String: Any]]) -> Int? {
        guard number > 0 else { return nil }
        let isOrdinary = windows.contains { info in
            (info[kCGWindowNumber as String] as? Int) == number && (info[kCGWindowLayer as String] as? Int) == 0
        }
        return isOrdinary ? number : nil
    }

    /// An app's frontmost ordinary window, from CGWindowListCopyWindowInfo's
    /// front-to-back list.
    static func frontWindow(of pid: pid_t, among windows: [[String: Any]]) -> Int? {
        let front = windows.first { info in
            (info[kCGWindowOwnerPID as String] as? Int) == Int(pid) && (info[kCGWindowLayer as String] as? Int) == 0
        }
        return front?[kCGWindowNumber as String] as? Int
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
