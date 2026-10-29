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

    /// An AppKit frame (bottom-left origin) in the top-left global coordinates clicks use.
    static func globalRect(_ frame: NSRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }

    static func isCovering(_ point: CGPoint, panel: CGRect) -> Bool {
        panel.insetBy(dx: -margin, dy: -margin - growth).contains(point)
    }
}

extension AgentPlacement {
    /// Let go this close to the top-right corner or home, the window snaps there.
    static let snapDistance: CGFloat = 80

    /// Where the Ask window sits: centered at the bottom of the screen's visible area.
    static func home(size: NSSize, in visible: NSRect) -> NSRect {
        NSRect(x: visible.midX - size.width / 2, y: visible.minY + 28, width: size.width, height: size.height)
    }

    static func frame(size: NSSize, in visible: NSRect, spot: AgentSpot) -> NSRect {
        switch spot {
        case .corner(let corner):
            return frame(size: size, in: visible, corner: corner)
        case .home:
            return home(size: size, in: visible)
        case .free(let top):
            let hanging = NSRect(x: top.x - size.width / 2, y: top.y - size.height, width: size.width, height: size.height)
            return clamped(hanging, in: visible)
        }
    }

    /// Moved just enough to be wholly on the screen's visible area.
    static func clamped(_ frame: NSRect, in visible: NSRect) -> NSRect {
        let x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        let y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        return NSRect(x: x, y: y, width: frame.width, height: frame.height)
    }

    /// Where a dragged window lands when let go: the top-right corner or home when it's
    /// close to one, else right where it was dropped.
    static func spot(droppedAt frame: NSRect, in visible: NSRect) -> AgentSpot {
        let corner = self.frame(size: frame.size, in: visible, corner: .topRight)
        if hypot(frame.maxX - corner.maxX, frame.maxY - corner.maxY) <= snapDistance {
            return .corner(.topRight)
        }
        let home = home(size: frame.size, in: visible)
        if hypot(frame.midX - home.midX, frame.minY - home.minY) <= snapDistance {
            return .home
        }
        let kept = clamped(frame, in: visible)
        return .free(CGPoint(x: kept.midX, y: kept.maxY))
    }

    /// The spot to be in so none of `points` (global, top-left origin) lands on the
    /// window: the current one if it's clear, else the first clear corner.
    static func spot(keeping current: AgentSpot, size: NSSize, in visible: NSRect, primaryHeight: CGFloat,
                     avoiding points: [CGPoint]) -> AgentSpot {
        let isClear = { (frame: NSRect) -> Bool in
            let global = globalRect(frame, primaryHeight: primaryHeight)
            return !points.contains { isCovering($0, panel: global) }
        }
        if isClear(frame(size: size, in: visible, spot: current)) { return current }
        let first: Corner = if case .corner(let corner) = current { corner } else { .topRight }
        let corners = [first] + Corner.allCases.filter { $0 != first }
        return corners.first { isClear(frame(size: size, in: visible, corner: $0)) }.map(AgentSpot.corner) ?? current
    }

    /// Where the window sits once the box in it closes: sent to the agent, the top right,
    /// to watch it work; otherwise back where it was before the box brought it home, or
    /// where it is.
    static func spot(after outcome: ComposerOutcome, current: AgentSpot, beforeHome: AgentSpot?) -> AgentSpot {
        outcome == .handedToAgent ? .corner(.topRight) : beforeHome ?? current
    }

    /// The screen the box opens on: the window's own when it opens in place, so it never
    /// jumps to another display; otherwise the one Ask is on.
    static func screen<Screen>(forBoxInPlace inPlace: Bool, current: Screen?, asked: Screen?) -> Screen? {
        inPlace ? current ?? asked : asked ?? current
    }
}

/// Where the agent's window is: in a corner, at home where the Ask window sits, or
/// wherever it was dragged.
enum AgentSpot: Equatable {
    case corner(AgentPlacement.Corner)
    case home
    /// Dragged here: the window's top middle (AppKit coordinates), so it grows downward
    /// and widens evenly for the box.
    case free(CGPoint)
}

/// The window dragged by its background: it moves with the pointer from where the drag began.
struct AgentDrag: Equatable {
    let startPointer: CGPoint
    let startFrame: NSRect

    init(startPointer: CGPoint, startFrame: NSRect) {
        self.startPointer = startPointer
        self.startFrame = startFrame
    }

    /// Begun once the pointer is a few points along (`translation`, SwiftUI's, which runs
    /// down) and the window hasn't moved yet: it began where the button went down.
    init(pointer: CGPoint, translation: CGSize, frame: NSRect) {
        self.init(startPointer: CGPoint(x: pointer.x - translation.width, y: pointer.y + translation.height),
                  startFrame: frame)
    }

    func frame(at pointer: CGPoint) -> NSRect {
        startFrame.offsetBy(dx: pointer.x - startPointer.x, dy: pointer.y - startPointer.y)
    }
}

/// Where the agent's window goes once the box in it closes.
enum AgentInputExit: Equatable {
    case stays
    /// Out of sight, the conversation kept: the next time Ask opens, it's back with the box.
    case tuck

    /// Sent to the agent: it stays, to watch it work. A question: tucked away so the
    /// answer is the only window, unless the agent is busy or waiting. Esc: back as it was.
    static func after(_ outcome: ComposerOutcome, wasTucked: Bool, isWorking: Bool, isWaiting: Bool) -> AgentInputExit {
        let busy = isWorking || isWaiting
        switch outcome {
        case .handedToAgent: return .stays
        case .asked: return busy ? .stays : .tuck
        case .cancelled: return wasTucked && !busy ? .tuck : .stays
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

/// The agent's floating window, in the top-right corner of the screen it works on, or
/// wherever it's dragged (it snaps to the top right and to home). Left out of the agent's
/// screenshots (as all LocalFlow windows are), so it moves to a clear corner before any
/// click that would land on it. Ask's box opens in it while there's a conversation, right
/// where it is, or at home when it was tucked away. It collapses to a small bar anywhere.
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
    /// ⌘ tapped on its own while the window is up: open the box for the agent.
    var onCommandTap: (() -> Void)?
    /// The ⌘ keys whose tap counts (not one that's the Ask or dictation key).
    var modeKeys = CommandTap.keys(askKey: .rightOption, dictationKey: .fnKey)

    private let panel: AgentWindow
    private let hosting: FirstClickHostingView<AgentPanelView>
    private var screen: NSScreen?
    private var spot = AgentSpot.corner(.topRight)
    /// Where it was before the box brought it home, to go back to after.
    private var spotBeforeHome: AgentSpot?
    /// The drag under way and where in the window it was grabbed. A grab anywhere else is
    /// a new drag: the last one's release never came (the window was put away mid-drag).
    private var drag: (grabbed: CGPoint, drag: AgentDrag)?
    /// Where the pointer is, in screen points (a test stands in for it).
    private let pointerLocation: @MainActor () -> CGPoint
    private var resizeObserver: NSObjectProtocol?
    private let presses = AgentPressLog()
    private let commandTaps = CommandTapWatcher()
    private var watchers: [AnyCancellable] = []
    private var followUpHint = ""
    /// The box, while the user writes in the window.
    private var input: ComposerModel?
    private var keys: ComposerKeys?
    private var isTucked = false
    /// Shrunk to a bar with the status; a box, an OK or a new task opens it back up.
    private var isCollapsed = false
    /// Tucked when the box opened: Esc puts it back.
    private var wasTucked = false

    var isVisible: Bool { panel.isVisible }
    var frame: NSRect { panel.frame }
    var isTakingInput: Bool { input != nil }
    var hasConversation: Bool { panel.isVisible || isTucked }

    init(pointerLocation: @escaping @MainActor () -> CGPoint = { NSEvent.mouseLocation }) {
        self.pointerLocation = pointerLocation
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
                MainActor.assumeIsolated {
                    guard !approvals.isEmpty else { return }
                    self?.untuck()
                    self?.setCollapsed(false)
                }
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
            collapsed: isCollapsed,
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
            onUndo: { [weak self] in self?.onUndo?() },
            onCollapse: { [weak self] in self?.setCollapsed(true) },
            onExpand: { [weak self] in self?.setCollapsed(false) },
            onDragMoved: { [weak self] translation, grabbed in self?.dragMoved(translation, grabbed: grabbed) },
            onDragEnded: { [weak self] in self?.dragEnded() }
        )
    }

    func setFollowUpHint(_ hint: String) {
        followUpHint = hint
        refreshView()
    }

    /// A new task: in the top-right corner of the screen it works on.
    func show(on screen: NSScreen?) {
        self.screen = screen ?? NSScreen.main
        spot = .corner(.topRight)
        spotBeforeHome = nil
        drag = nil
        isTucked = false
        isCollapsed = false
        refreshView()
        present()
    }

    /// Everything put away (✕, or a new task replacing this one). A box open in it closes too.
    func hide() {
        let hadInput = input != nil
        endInput()
        isTucked = false
        isCollapsed = false
        drag = nil
        commandTaps.stop()
        if panel.isVisible { panel.orderOut(nil) }
        if hadInput { onInputCancel?() }
    }

    // MARK: - The box

    func showInput(_ model: ComposerModel, on screen: NSScreen?, inPlace: Bool) {
        self.screen = AgentPlacement.screen(forBoxInPlace: inPlace, current: self.screen, asked: screen) ?? NSScreen.main
        drag = nil
        wasTucked = isTucked
        isTucked = false
        isCollapsed = false
        input = model
        if !inPlace, spot != .home {
            spotBeforeHome = spot
            spot = .home
        }
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

    func hideInput(after outcome: ComposerOutcome) {
        guard input != nil else { return }
        let exit = AgentInputExit.after(outcome, wasTucked: wasTucked, isWorking: model.status.isWorking,
                                        isWaiting: !model.approvals.isEmpty)
        endInput()
        drag = nil
        // Out first, so the app being worked in gets the keyboard back.
        panel.orderOut(nil)
        spot = AgentPlacement.spot(after: outcome, current: spot, beforeHome: spotBeforeHome)
        spotBeforeHome = nil
        refreshView()
        if exit == .stays {
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

    /// Moves to a spot clear of every point a click, drag or scroll acts on (global,
    /// top-left origin, as CGEvent uses). Returns whether it moved. Never while the user
    /// writes in it (such a click is looked up as landing on LocalFlow, and asks) or drags it.
    @discardableResult
    func moveAside(avoiding points: [CGPoint]) -> Bool {
        guard input == nil, drag == nil, panel.isVisible, !points.isEmpty, let screen,
              let primary = NSScreen.screens.first else {
            return false
        }
        let best = AgentPlacement.spot(keeping: spot, size: panel.frame.size, in: screen.visibleFrame,
                                       primaryHeight: primary.frame.height, avoiding: points)
        guard best != spot else { return false }
        spot = best
        place()
        return true
    }

    /// Glides into its spot when `animated` (a snap after a drag), unless Reduce Motion is on.
    private func place(animated: Bool = false) {
        guard let screen else { return }
        let target = AgentPlacement.frame(size: panel.frame.size, in: screen.visibleFrame, spot: spot)
        guard target != panel.frame else { return }
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            return panel.setFrame(target, display: true)
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
        }
    }

    private func setCollapsed(_ collapsed: Bool) {
        guard collapsed != isCollapsed else { return }
        isCollapsed = collapsed
        refreshView()
        if panel.isVisible { fitAndPlace() }
    }

    // MARK: - Dragged by its background

    /// Follows the pointer, onto any screen, kept wholly on it.
    private func dragMoved(_ translation: CGSize, grabbed: CGPoint) {
        let pointer = pointerLocation()
        let drag = self.drag.flatMap { $0.grabbed == grabbed ? $0.drag : nil }
            ?? AgentDrag(pointer: pointer, translation: translation, frame: panel.frame)
        self.drag = (grabbed, drag)
        if let under = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) { screen = under }
        let target = drag.frame(at: pointer)
        spot = .free(CGPoint(x: target.midX, y: target.maxY))
        spotBeforeHome = nil
        place()
    }

    /// Let go: it snaps to the top right or home when it's close to one, else stays put.
    private func dragEnded() {
        guard drag != nil, let screen else { return }
        drag = nil
        spot = AgentPlacement.spot(droppedAt: panel.frame, in: screen.visibleFrame)
        place(animated: true)
    }

    // MARK: - ⌘ on the window

    /// Listening for ⌘ only while the window is up with no box.
    private func updateCommandTaps() {
        if panel.isVisible, input == nil {
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
