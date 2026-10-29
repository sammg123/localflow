import AppKit
import SwiftUI

/// Where the agent's window sits, and when it's in the way of a click.
enum AgentPlacement {
    enum Corner: Equatable, CaseIterable {
        case topRight
        case topLeft
        case bottomRight
        case bottomLeft
    }

    static let inset: CGFloat = 16
    /// A click this close to the window counts as on it.
    static let margin: CGFloat = 8
    /// Room above and below for the window to grow (a step, a card) after a check.
    static let growth: CGFloat = 120

    /// The window's frame in a corner of the screen's visible area (AppKit coordinates).
    static func frame(size: NSSize, in visible: NSRect, corner: Corner) -> NSRect {
        let right = corner == .topRight || corner == .bottomRight
        let top = corner == .topRight || corner == .topLeft
        let x = right ? visible.maxX - size.width - inset : visible.minX + inset
        let y = top ? visible.maxY - size.height - inset : visible.minY + inset
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// The corner to be in so none of `points` (global, top-left origin) lands on the
    /// window: the current one if it's clear, else the first clear one.
    static func corner(keeping current: Corner, size: NSSize, in visible: NSRect, primaryHeight: CGFloat,
                       avoiding points: [CGPoint]) -> Corner {
        let candidates = [current] + Corner.allCases.filter { $0 != current }
        let clear = candidates.first { corner in
            let global = globalRect(frame(size: size, in: visible, corner: corner), primaryHeight: primaryHeight)
            return !points.contains { isCovering($0, panel: global) }
        }
        return clear ?? current
    }

    /// An AppKit frame (bottom-left origin) in the top-left global coordinates clicks use.
    static func globalRect(_ frame: NSRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }

    static func isCovering(_ point: CGPoint, panel: CGRect) -> Bool {
        panel.insetBy(dx: -margin, dy: -margin - growth).contains(point)
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
    private let presses = AgentPressLog()

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
            onAnswer: { [weak self] approval, answer in self?.answer(approval, answer) },
            onPressed: { [weak self] approval, answer, isPressed in
                guard isPressed else {
                    self?.presses.buttonReleased(approval.id, answer, during: NSApp.currentEvent?.type)
                    return
                }
                FlowLog.shared.write("agent: pointer down on an Allow button")
                self?.presses.buttonPressed(approval.id, answer, at: ProcessInfo.processInfo.systemUptime)
            },
            onShown: { [weak self] approval in
                self?.presses.cardShown(approval.id, at: ProcessInfo.processInfo.systemUptime)
            },
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

    /// Moves to a corner clear of every point a click, drag or scroll acts on (global,
    /// top-left origin, as CGEvent uses). Returns whether it moved.
    @discardableResult
    func moveAside(avoiding points: [CGPoint]) -> Bool {
        guard panel.isVisible, !points.isEmpty, let screen, let primary = NSScreen.screens.first else { return false }
        let best = AgentPlacement.corner(keeping: corner, size: panel.frame.size, in: screen.visibleFrame,
                                         primaryHeight: primary.frame.height, avoiding: points)
        guard best != corner else { return false }
        corner = best
        place()
        return true
    }

    private func place() {
        guard let screen else { return }
        let target = AgentPlacement.frame(size: panel.frame.size, in: screen.visibleFrame, corner: corner)
        guard target != panel.frame else { return }
        panel.setFrame(target, display: true)
    }

    /// An Allow that isn't the person's own click on it (one the agent posted or pressed
    /// through accessibility, a stale click) does nothing but beep.
    private func answer(_ approval: AgentApproval, _ answer: AgentAnswer) {
        let verdict = AgentAnswerGate.check(answer, event: NSApp.currentEvent, in: panel,
                                            press: presses.press(for: approval.id, answer),
                                            now: ProcessInfo.processInfo.systemUptime)
        guard verdict == .accepted else {
            presses.consume(approval.id, answer)
            FlowLog.shared.write("agent: ignored an Allow (\(verdict.reason))")
            NSSound.beep()
            return
        }
        presses.forget(approval.id)
        onAnswer?(approval, answer)
    }

    private func copyReply() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.reply, forType: .string)
    }
}
