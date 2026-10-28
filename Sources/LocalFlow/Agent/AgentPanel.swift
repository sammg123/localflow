import AppKit
import SwiftUI

/// Where the agent's window sits, and when it's in the way of a click.
enum AgentPlacement {
    enum Corner: Equatable {
        case topRight
        case topLeft

        var other: Corner { self == .topRight ? .topLeft : .topRight }
    }

    static let inset: CGFloat = 16
    /// A click this close to the window counts as on it.
    static let margin: CGFloat = 8

    /// The window's frame in a corner of the screen's visible area (AppKit coordinates).
    static func frame(size: NSSize, in visible: NSRect, corner: Corner) -> NSRect {
        let x = corner == .topRight ? visible.maxX - size.width - inset : visible.minX + inset
        return NSRect(x: x, y: visible.maxY - size.height - inset, width: size.width, height: size.height)
    }

    /// An AppKit frame (bottom-left origin) in the top-left global coordinates clicks use.
    static func globalRect(_ frame: NSRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }

    static func isCovering(_ point: CGPoint, panel: CGRect) -> Bool {
        panel.insetBy(dx: -margin, dy: -margin).contains(point)
    }
}

/// Never takes the keyboard, so the agent's typing always lands in the app it's working
/// in. Buttons still work on the first click.
private final class AgentWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The agent's floating window, in the top corner of the screen it works on. Left out
/// of the agent's screenshots (as all LocalFlow windows are), so it moves to the other
/// corner before any click that would land on it.
@MainActor
final class AgentPanel {
    let model = AgentModel()
    var onAnswer: ((AgentApproval, AgentAnswer) -> Void)?
    var onStop: (() -> Void)?
    var onClose: (() -> Void)?

    private let panel: AgentWindow
    private let hosting: FirstClickHostingView<AgentPanelView>
    private var screen: NSScreen?
    private var corner = AgentPlacement.Corner.topRight
    private var resizeObserver: NSObjectProtocol?

    var isVisible: Bool { panel.isVisible }
    var frame: NSRect { panel.frame }

    init() {
        panel = AgentWindow(
            contentRect: NSRect(x: 0, y: 0, width: AgentPanelView.width, height: 160),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .screenSaver // over full-screen apps, like the Ask window
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hosting = FirstClickHostingView(rootView: AgentPanelView(model: model))
        panel.contentView = hosting
        hosting.rootView = makeView(followUpHint: "")
        // The hosting view resizes the window to its content; keep it in its corner.
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
    }

    private func makeView(followUpHint: String) -> AgentPanelView {
        AgentPanelView(
            model: model,
            followUpHint: followUpHint,
            onAnswer: { [weak self] approval, answer in self?.onAnswer?(approval, answer) },
            onStop: { [weak self] in self?.onStop?() },
            onCopy: { [weak self] in self?.copyReply() },
            onClose: { [weak self] in self?.onClose?() }
        )
    }

    func setFollowUpHint(_ hint: String) {
        hosting.rootView = makeView(followUpHint: hint)
    }

    func show(on screen: NSScreen?) {
        self.screen = screen ?? NSScreen.main
        corner = .topRight
        hosting.layoutSubtreeIfNeeded()
        panel.setContentSize(hosting.fittingSize)
        place()
        if !panel.isVisible {
            panel.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
                panel.animator().alphaValue = 1
            }
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }

    /// Moves to the other corner when a click or drag at this global point (top-left
    /// origin, as CGEvent uses) would land on the window. Returns whether it moved.
    @discardableResult
    func moveAside(ifCovering point: CGPoint) -> Bool {
        guard panel.isVisible, let primary = NSScreen.screens.first else { return false }
        let global = AgentPlacement.globalRect(panel.frame, primaryHeight: primary.frame.height)
        guard AgentPlacement.isCovering(point, panel: global) else { return false }
        corner = corner.other
        place()
        return true
    }

    private func place() {
        guard let screen else { return }
        let target = AgentPlacement.frame(size: panel.frame.size, in: screen.visibleFrame, corner: corner)
        guard target != panel.frame else { return }
        panel.setFrame(target, display: true)
    }

    private func copyReply() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.reply, forType: .string)
    }
}
