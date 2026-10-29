import AppKit

/// Whether a click came from the person at the Mac or from a program posting clicks.
/// macOS stamps every posted event with the poster's process id, and the poster can't
/// change it; clicks from a mouse or trackpad carry none, or the window server's.
enum PointerSource {
    static func isPerson(_ event: NSEvent?) -> Bool {
        guard let event, event.type == .leftMouseUp || event.type == .leftMouseDown,
              let cg = event.cgEvent else { return false }
        let source = cg.getIntegerValueField(.eventSourceUnixProcessID)
        return source == 0 || windowServer.map { source == Int64($0) } == true
    }

    /// The window server's process id, looked up once (it lives as long as the login).
    static let windowServer: pid_t? = ProcessTree.snapshot().first { entry in
        guard let path = ProcessTree.executablePath(entry.pid) else { return false }
        return path.hasPrefix("/System/Library/PrivateFrameworks/SkyLight.framework/") && path.hasSuffix("/WindowServer")
    }?.pid
}

/// Which answers on an approval card count. The agent can post clicks, press buttons
/// through accessibility and time when its cards appear, so Allow takes the person's own
/// click on that very button: a mouse-up from the mouse or trackpad, under a second old,
/// on a button that saw the mouse go down on it, once the card has been up long enough to
/// read. Deny takes anything.
enum AgentAnswerGate {
    enum Verdict: Equatable {
        case accepted
        /// Posted by a program, stale, or not a click at all.
        case notAClick
        /// A real click, but it didn't press this button (an accessibility press, say).
        case notPressed
        /// Pressed before the card had been up long enough to read.
        case tooSoon

        /// For the event log.
        var reason: String {
            switch self {
            case .accepted: return "accepted"
            case .notAClick: return "not a real click"
            case .notPressed: return "button not pressed"
            case .tooSoon: return "card too new"
            }
        }
    }

    /// When the card first showed and when the mouse went down on the button (system uptime).
    struct Press: Equatable {
        let shownAt: TimeInterval?
        let pressedAt: TimeInterval?
    }

    static let freshness: TimeInterval = 1
    static let pressWindow: TimeInterval = 5
    static let settle: TimeInterval = 0.4

    static func check(_ answer: AgentAnswer, event: NSEvent?, in window: NSWindow?, press: Press,
                      now: TimeInterval) -> Verdict {
        if answer == .deny { return .accepted }
        // All must hold; the order only decides which reason the log gives.
        guard let pressedAt = press.pressedAt, pressedAt <= now, now - pressedAt < pressWindow else {
            return .notPressed
        }
        guard let shownAt = press.shownAt, pressedAt - shownAt >= settle else { return .tooSoon }
        guard let event, PointerSource.isPerson(event), event.type == .leftMouseUp, event.window === window,
              now - event.timestamp < freshness else { return .notAClick }
        return .accepted
    }
}

/// When each card first showed, and when the pointer went down on its Allow buttons.
@MainActor
final class AgentPressLog {
    private var shown: [String: TimeInterval] = [:]
    private var pressed: [String: TimeInterval] = [:]

    func cardShown(_ id: String, at time: TimeInterval) {
        guard shown[id] == nil else { return }
        shown = shown.merging([id: time]) { first, _ in first }
    }

    func buttonPressed(_ id: String, _ answer: AgentAnswer, at time: TimeInterval) {
        pressed = pressed.merging([key(id, answer): time]) { _, new in new }
    }

    func press(for id: String, _ answer: AgentAnswer) -> AgentAnswerGate.Press {
        AgentAnswerGate.Press(shownAt: shown[id], pressedAt: pressed[key(id, answer)])
    }

    /// The press ended. Let go on the button (a mouse-up), the action reads it next; dragged
    /// off first, it no longer counts, so a later accessibility press can't borrow it.
    func buttonReleased(_ id: String, _ answer: AgentAnswer, during event: NSEvent.EventType?) {
        guard event != .leftMouseUp else { return }
        consume(id, answer)
    }

    /// A press counts once, whether or not it was accepted.
    func consume(_ id: String, _ answer: AgentAnswer) {
        pressed = pressed.filter { $0.key != key(id, answer) }
    }

    func forget(_ id: String) {
        shown = shown.filter { $0.key != id }
        pressed = pressed.filter { !$0.key.hasPrefix(id + "/") }
    }

    private func key(_ id: String, _ answer: AgentAnswer) -> String { "\(id)/\(answer)" }
}
