import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Borderless panels refuse key status by default; this one takes typing.
private final class ComposerWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// A floating window where words are written: the Ask window and the hands-free
/// dictation window. Non-activating, so the app being worked in stays frontmost, but
/// it takes the keyboard while open so typing and Return land here. It opens at home,
/// the bottom middle, or where its view was last dragged (the Ask window's is).
@MainActor
class ComposerPanel: ComposerSurface {
    let model = ComposerModel()
    var onSend: (() -> Void)? {
        didSet { keys.onSend = onSend }
    }
    var onCancel: (() -> Void)? {
        didSet { keys.onCancel = onCancel }
    }
    /// ⌘ switches Ask and agent mode and ⌘I Instant (the Ask window).
    var takesModeKeys: Bool {
        get { keys.takesModeKeys }
        set { keys.takesModeKeys = newValue }
    }

    /// How long after showing the window it's checked for having reached the screen.
    static let landingCheckDelay: Duration = .milliseconds(300)

    private var panel: ComposerWindow
    private let size: NSSize
    private let isOnScreen: @MainActor (NSWindow) -> Bool
    /// Where the pointer is, in screen points (a test stands in for it).
    private let pointerLocation: @MainActor () -> CGPoint
    private var spot = ComposerSpot.home
    private var screen: NSScreen?
    /// The drag under way and where in the window it was grabbed. A grab anywhere else is
    /// a new drag, and so is any after a show or hide: a window put away mid-drag never
    /// hears the release.
    private var drag: (grabbed: CGPoint, drag: AgentDrag)?
    private lazy var keys = ComposerKeys(model: model) { [weak self] in self?.panel }
    /// Bumped per show and hide, so only the latest show's landing check runs.
    private var landingCheck = 0

    var isVisible: Bool { panel.isVisible }
    var isKey: Bool { panel.isKeyWindow }
    var frame: NSRect { panel.frame }
    // For the on-screen tests.
    var windowNumber: Int { panel.windowNumber }
    var isOnScreenNow: Bool { isOnScreen(panel) }

    init(size: NSSize, isOnScreen: @escaping @MainActor (NSWindow) -> Bool = ComposerPanel.windowIsOnScreen,
         pointerLocation: @escaping @MainActor () -> CGPoint = { NSEvent.mouseLocation }) {
        self.size = size
        self.isOnScreen = isOnScreen
        self.pointerLocation = pointerLocation
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
        drag = nil
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
        keys.install()
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
        keys.remove()
        landingCheck += 1
        drag = nil
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }

    func updateLevel(_ level: Float) {
        guard panel.isVisible else { return }
        model.level = model.level * 0.6 + level * 0.4
    }

    private func position(on screen: NSScreen?) {
        guard let screen else { return }
        self.screen = screen
        panel.setFrame(spot.frame(size: size, in: screen.visibleFrame), display: false)
    }

    // MARK: - Dragged by its background

    /// Follows the pointer, onto any screen, kept wholly on it. `translation` is how far the
    /// pointer has come (only the first move's counts) and `grabbed` where in the window it went down.
    func dragMoved(_ translation: CGSize, grabbed: CGPoint) {
        let pointer = pointerLocation()
        let drag = self.drag.flatMap { $0.grabbed == grabbed ? $0.drag : nil }
            ?? AgentDrag(pointer: pointer, translation: translation, frame: panel.frame)
        self.drag = (grabbed, drag)
        if let under = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) { screen = under }
        guard let screen else { return }
        panel.setFrame(AgentPlacement.clamped(drag.frame(at: pointer), in: screen.visibleFrame), display: true)
    }

    /// Let go: it snaps to the top right or home when it's close to one, else stays put,
    /// and opens there from now on.
    func dragEnded() {
        guard drag != nil, let screen else { return }
        drag = nil
        spot = ComposerSpot.dropped(panel.frame, in: screen.visibleFrame)
        let target = spot.frame(size: size, in: screen.visibleFrame)
        guard target != panel.frame else { return }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            return panel.setFrame(target, display: true)
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
        }
    }
}

/// Where a composer window opens: home until it's dragged, then the top right or home
/// when let go near one, else where it was let go. That last is kept as a share of the
/// screen's visible area, so on another display it opens in the same place there.
enum ComposerSpot: Equatable {
    case home
    case corner(AgentPlacement.Corner)
    /// The window's top middle, as a share of the visible area's width and height from its bottom left.
    case share(CGPoint)

    static func dropped(_ frame: NSRect, in visible: NSRect) -> ComposerSpot {
        switch AgentPlacement.spot(droppedAt: frame, in: visible) {
        case .home:
            return .home
        case .corner(let corner):
            return .corner(corner)
        case .free(let top):
            return .share(CGPoint(x: (top.x - visible.minX) / max(visible.width, 1),
                                  y: (top.y - visible.minY) / max(visible.height, 1)))
        }
    }

    func frame(size: NSSize, in visible: NSRect) -> NSRect {
        switch self {
        case .home:
            return AgentPlacement.home(size: size, in: visible)
        case .corner(let corner):
            return AgentPlacement.frame(size: size, in: visible, corner: corner)
        case .share(let share):
            let top = CGPoint(x: visible.minX + share.x * visible.width, y: visible.minY + share.y * visible.height)
            return AgentPlacement.frame(size: size, in: visible, spot: .free(top))
        }
    }
}
