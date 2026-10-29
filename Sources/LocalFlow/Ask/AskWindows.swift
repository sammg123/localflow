import AppKit

/// The agent's window as a place to write: while there's an agent conversation, Ask's box
/// opens in it instead of in a window of its own. The agent panel in the app; a fake in tests.
@MainActor
protocol AgentInputHost: AnyObject {
    /// An agent conversation is open: its window is up, or tucked away after a question.
    var hasConversation: Bool { get }
    /// Its window sits in its corner (where ⌘ opens the box in place).
    var isInCorner: Bool { get }
    /// Return and Esc in the box.
    var onInputSend: (() -> Void)? { get set }
    var onInputCancel: (() -> Void)? { get set }
    /// Opens the box under the conversation: in place, or at home where the Ask window sits.
    func showInput(_ model: ComposerModel, on screen: NSScreen?, inPlace: Bool)
    func hideInput(after outcome: ComposerOutcome)
}

/// The one window Ask writes in, so Ask and the agent are never two windows at once: the
/// Ask window, or the agent's own window while there's an agent conversation. Opened for
/// Ask it sits at home, centered at the bottom; opened for the agent (⌘ on the agent's
/// window) it opens where the agent's window is.
@MainActor
final class AskWindows: ComposerSurface {
    var onSend: (() -> Void)? {
        didSet { ask.onSend = onSend }
    }
    var onCancel: (() -> Void)? {
        didSet { ask.onCancel = onCancel }
    }

    private let ask: ComposerSurface
    private let agent: AgentInputHost
    /// The box is in the agent's window.
    private var inAgentWindow = false

    var model: ComposerModel { ask.model }

    init(ask: ComposerSurface, agent: AgentInputHost) {
        self.ask = ask
        self.agent = agent
        agent.onInputSend = { [weak self] in self?.onSend?() }
        agent.onInputCancel = { [weak self] in self?.onCancel?() }
    }

    func show(on screen: NSScreen?) {
        guard agent.hasConversation else {
            inAgentWindow = false
            return ask.show(on: screen)
        }
        ask.hide()
        inAgentWindow = true
        agent.showInput(model, on: screen, inPlace: model.agentMode && agent.isInCorner)
    }

    func hide() {
        finish(.cancelled)
    }

    func finish(_ outcome: ComposerOutcome) {
        if inAgentWindow {
            agent.hideInput(after: outcome)
        } else {
            ask.finish(outcome)
        }
        inAgentWindow = false
    }

    func updateLevel(_ level: Float) {
        guard inAgentWindow else { return ask.updateLevel(level) }
        model.level = model.level * 0.6 + level * 0.4
    }

    func takeKeyboard() {
        if !inAgentWindow { ask.takeKeyboard() }
    }
}
