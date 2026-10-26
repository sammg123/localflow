import AppKit
import SwiftUI

/// Lets buttons work on the first click, without making the panel key first.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A click anywhere in the bubble, the scrolling answer included, brings it back in
/// front of the apps that were clicked over it.
private final class AnswerWindow: NSPanel {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown { orderFrontRegardless() }
        super.sendEvent(event)
    }
}

/// The answer bubble, where the pill appears. An ordinary window level, so any app you
/// click comes in front of it; non-activating, so clicking it never takes focus from
/// the app being worked in. Minimizes to a chip in the corner (the – button, or by
/// itself once another window covers it completely) and expands back from the chip.
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

    private(set) var isMinimized = false
    /// Up in any form: the full bubble or the chip.
    var isVisible: Bool { panel.isVisible || chip.isVisible }
    var frame: NSRect { panel.frame }
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

    func show(on screen: NSScreen?) {
        model.reset()
        self.screen = screen
        isMinimized = false
        chip.hide()
        present()
    }

    func hide() {
        settleCheck?.cancel()
        isMinimized = false
        chip.hide()
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }

    func minimize() {
        guard panel.isVisible, !isMinimized else { return }
        settleCheck?.cancel()
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
        hosting.layoutSubtreeIfNeeded()
        pinToBottom()
        shownAt = Date()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
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

    /// Bottom edge where the pill sits, horizontally centered on the working display.
    private func pinToBottom() {
        guard let screen = screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let origin = NSPoint(x: visible.midX - panel.frame.width / 2, y: visible.minY + 28)
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
        panel.invalidateShadow()
    }
}
