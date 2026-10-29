import AppKit
import Combine
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

extension AgentPlacement {
    /// Where the Ask window sits: centered at the bottom of the screen's visible area.
    static func home(size: NSSize, in visible: NSRect) -> NSRect {
        NSRect(x: visible.midX - size.width / 2, y: visible.minY + 28, width: size.width, height: size.height)
    }
}

/// Where the agent's window goes once the box in it closes.
enum AgentInputExit: Equatable {
    case corner
    /// Out of sight, the conversation kept: the next time Ask opens, it's back with the box.
    case tuck

    /// Sent to the agent: the corner, to watch it work. A question: tucked away so the
    /// answer is the only window, unless the agent is busy or waiting. Esc: back as it was.
    static func after(_ outcome: ComposerOutcome, wasTucked: Bool, isWorking: Bool, isWaiting: Bool) -> AgentInputExit {
        let busy = isWorking || isWaiting
        switch outcome {
        case .handedToAgent: return .corner
        case .asked: return busy ? .corner : .tuck
        case .cancelled: return wasTucked && !busy ? .tuck : .corner
        }
    }
}

/// Takes the keyboard only while the user writes in its box, so the agent's typing
/// otherwise always lands in the app it's working in. Buttons work on the first click.
private final class AgentWindow: NSPanel {
    var takesKeyboard = false
    override var canBecomeKey: Bool { takesKeyboard }
    override var canBecomeMain: Bool { false }
}

/// The agent's floating window, in the top corner of the screen it works on. Left out
/// of the agent's screenshots (as all LocalFlow windows are), so it moves to the other
/// corner before any click that would land on it. Ask's box opens in it while there's a
/// conversation: at home, where the Ask window sits, or in place when ⌘ opened it.
@MainActor
final class AgentPanel: AgentInputHost {
    let model = AgentModel()
    var onAnswer: ((AgentApproval, AgentAnswer) -> Void)?
    var onStop: (() -> Void)?
    var onClose: (() -> Void)?
    var onInputClosed: (() -> Void)?
    var onUndo: (() -> Void)?
    var onInputSend: (() -> Void)?
    var onInputCancel: (() -> Void)?
    var onOpenChats: (() -> Void)?
    var onOpenConnectors: (() -> Void)?
    /// ⌘ tapped on its own while the window sits in its corner: open the box for the agent.
    var onCommandTap: (() -> Void)?
    /// The ⌘ keys whose tap counts (not one that's the Ask or dictation key).
    var modeKeys = CommandTap.keys(askKey: .rightOption, dictationKey: .fnKey)

    private let panel: AgentWindow
    private let hosting: FirstClickHostingView<AgentPanelView>
    private var screen: NSScreen?
    private var corner = AgentPlacement.Corner.topRight
    private var resizeObserver: NSObjectProtocol?
    private let presses = AgentPressLog()
    private let commandTaps = CommandTapWatcher()
    private var watchers: [AnyCancellable] = []
    private var followUpHint = ""
    /// The box, while the user writes in the window.
    private var input: ComposerModel?
    private var keys: ComposerKeys?
    private var atHome = false
    private var isTucked = false
    /// Tucked when the box opened: Esc puts it back.
    private var wasTucked = false

    var isVisible: Bool { panel.isVisible }
    var frame: NSRect { panel.frame }
    var isTakingInput: Bool { input != nil }
    var hasConversation: Bool { panel.isVisible || isTucked }
    var isInCorner: Bool { panel.isVisible && !atHome }

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
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hosting = FirstClickHostingView(rootView: AgentPanelView(model: model, input: ComposerModel()))
        panel.contentView = hosting
        refreshView()
        // The hosting view resizes the window to its content; keep it in its spot.
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
        commandTaps.onTap = { [weak self] in self?.commandTapped() }
        // Tucked away, it comes back when the agent needs an OK or starts working again.
        watchers = [
            model.$approvals.sink { [weak self] approvals in
                MainActor.assumeIsolated { if !approvals.isEmpty { self?.untuck() } }
            },
            model.$status.sink { [weak self] status in
                MainActor.assumeIsolated { if status.isWorking { self?.untuck() } }
            },
        ]
    }

    private func refreshView() {
        hosting.rootView = AgentPanelView(
            model: model,
            input: input ?? ComposerModel(),
            showsInput: input != nil,
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
            onClose: { [weak self] in self?.onClose?() },
            onInputSend: { [weak self] in self?.onInputSend?() },
            onOpenChats: { [weak self] in self?.onOpenChats?() },
            onOpenConnectors: { [weak self] in self?.onOpenConnectors?() },
            onUndo: { [weak self] in self?.onUndo?() }
        )
    }

    func setFollowUpHint(_ hint: String) {
        followUpHint = hint
        refreshView()
    }

    /// A new task: in the top-right corner of the screen it works on.
    func show(on screen: NSScreen?) {
        self.screen = screen ?? NSScreen.main
        corner = .topRight
        atHome = false
        isTucked = false
        refreshView()
        present()
    }

    /// Everything put away (✕, or a new task replacing this one). A box open in it closes too.
    func hide() {
        let hadInput = input != nil
        endInput()
        isTucked = false
        atHome = false
        commandTaps.stop()
        if panel.isVisible { panel.orderOut(nil) }
        if hadInput { onInputCancel?() }
    }

    // MARK: - The box

    func showInput(_ model: ComposerModel, on screen: NSScreen?, inPlace: Bool) {
        if let screen { self.screen = screen } else if self.screen == nil { self.screen = NSScreen.main }
        wasTucked = isTucked
        isTucked = false
        input = model
        atHome = !inPlace
        let keys = ComposerKeys(model: model) { [weak self] in self?.panel }
        keys.takesModeKeys = true
        keys.onSend = { [weak self] in self?.onInputSend?() }
        keys.onCancel = { [weak self] in self?.onInputCancel?() }
        self.keys = keys
        panel.takesKeyboard = true
        commandTaps.stop()
        refreshView()
        present()
        panel.makeKey()
        keys.install()
    }

    /// The Ask key while the box is open in the corner: back home, to ask.
    func moveInputHome() {
        guard let input, !atHome else { return }
        input.agentMode = false
        atHome = true
        fitAndPlace()
    }

    func hideInput(after outcome: ComposerOutcome) {
        guard input != nil else { return }
        let exit = AgentInputExit.after(outcome, wasTucked: wasTucked, isWorking: model.status.isWorking,
                                        isWaiting: !model.approvals.isEmpty)
        endInput()
        // Out first, so the app being worked in gets the keyboard back.
        panel.orderOut(nil)
        atHome = false
        refreshView()
        if exit == .corner {
            present()
        } else {
            isTucked = true
        }
        onInputClosed?()
    }

    private func endInput() {
        keys?.remove()
        keys = nil
        input = nil
        panel.takesKeyboard = false
    }

    private func untuck() {
        guard isTucked else { return }
        isTucked = false
        atHome = false
        present()
    }

    // MARK: - On screen

    private func present() {
        fitAndPlace()
        if !panel.isVisible {
            panel.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
                panel.animator().alphaValue = 1
            }
        }
        panel.orderFrontRegardless()
        updateCommandTaps()
    }

    private func fitAndPlace() {
        hosting.layoutSubtreeIfNeeded()
        panel.setContentSize(hosting.fittingSize)
        place()
    }

    /// Moves to a corner clear of every point a click, drag or scroll acts on (global,
    /// top-left origin, as CGEvent uses). Returns whether it moved. Never while the user
    /// writes in it: such a click is looked up as landing on LocalFlow, and asks.
    @discardableResult
    func moveAside(avoiding points: [CGPoint]) -> Bool {
        guard input == nil, panel.isVisible, !points.isEmpty, let screen, let primary = NSScreen.screens.first else {
            return false
        }
        let best = AgentPlacement.corner(keeping: corner, size: panel.frame.size, in: screen.visibleFrame,
                                         primaryHeight: primary.frame.height, avoiding: points)
        guard best != corner else { return false }
        corner = best
        place()
        return true
    }

    private func place() {
        guard let screen else { return }
        let size = panel.frame.size
        let target = atHome ? AgentPlacement.home(size: size, in: screen.visibleFrame)
                            : AgentPlacement.frame(size: size, in: screen.visibleFrame, corner: corner)
        guard target != panel.frame else { return }
        panel.setFrame(target, display: true)
    }

    // MARK: - ⌘ in the corner

    /// Listening for ⌘ only while the window sits in its corner with no box.
    private func updateCommandTaps() {
        if panel.isVisible, input == nil, !atHome {
            commandTaps.start(keys: modeKeys)
        } else {
            commandTaps.stop()
        }
    }

    /// Not while another LocalFlow window has the keyboard (the hands-free window).
    private func commandTapped() {
        guard panel.isVisible, input == nil, NSApp.keyWindow == nil else { return }
        onCommandTap?()
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
