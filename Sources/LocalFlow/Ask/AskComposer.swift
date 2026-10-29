import AppKit
import SwiftUI

enum ComposerMode: Equatable {
    /// Talking: the words appear as they're heard.
    case voice
    /// Mic off, the last words are being written down.
    case finishing
    /// The box is editable.
    case typing
}

@MainActor
final class ComposerModel: ObservableObject {
    @Published var text = ""
    @Published var mode: ComposerMode = .voice
    @Published var level: Float = 0
    /// A one-line problem shown in the footer ("Didn't catch that…").
    @Published var notice: String?
    @Published var keyName = "Right ⌥"
    /// The ⌘ keys whose tap switches modes: not one that's the Ask or dictation key.
    var modeKeys: Set<UInt16> = CommandTap.keys(askKey: .rightOption, dictationKey: .fnKey)
    /// Agent mode (green): Return hands the words to the agent instead of asking. ⌘ toggles it.
    @Published var agentMode = false
    /// Instant Edits (⌘I in agent mode): a small UI change, made straight away. Stays on
    /// between sends until turned off.
    @Published var instant = false

    var question: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// While talking, send means "finish the words and send them".
    var canSend: Bool { mode != .typing || !question.isEmpty }

    /// The next send goes to the agent as an Instant Edit.
    var sendsInstant: Bool { agentMode && instant }

    var title: String {
        switch mode {
        case .voice: return "Listening"
        case .finishing: return "Writing it down…"
        case .typing: return agentMode ? "Tell the agent what to do" : "Ask about your screen"
        }
    }

    var hint: String {
        let other = agentMode ? "⌘ for Ask" : "⌘ for agent"
        switch mode {
        case .voice: return "\(keyName) to stop  ·  Return to send  ·  \(other)"
        case .finishing: return "Return to send  ·  \(other)"
        case .typing where agentMode: return "Return to send  ·  ⌘ for Ask  ·  ⌘I Instant"
        case .typing: return "\(keyName) to talk  ·  Return to send  ·  ⌘ for agent"
        }
    }

    func toggleAgentMode() {
        agentMode.toggle()
    }

    /// Only in agent mode; returns whether it changed.
    @discardableResult
    func toggleInstant() -> Bool {
        guard agentMode else { return false }
        instant.toggle()
        return true
    }

    /// A fresh box: in Ask mode unless it's opened for the agent. Instant stays as it was.
    func reset(mode: ComposerMode, agentMode: Bool = false) {
        text = ""
        level = 0
        notice = nil
        self.mode = mode
        self.agentMode = agentMode
    }
}

/// How the box was closed: what the window does next depends on it.
enum ComposerOutcome: Equatable {
    /// Sent as a question about the screen.
    case asked
    /// Sent to the agent.
    case handedToAgent
    /// Esc, ✕, or closed some other way.
    case cancelled
}

/// Where the question is written. The floating window in the app; a fake in tests.
@MainActor
protocol ComposerSurface: AnyObject {
    var model: ComposerModel { get }
    var onSend: (() -> Void)? { get set }
    var onCancel: (() -> Void)? { get set }
    func show(on screen: NSScreen?)
    func hide()
    /// Closes the box, saying how; most windows just hide.
    func finish(_ outcome: ComposerOutcome)
    func updateLevel(_ level: Float)
    /// Takes the keyboard back if it went to another app while the window stayed up.
    func takeKeyboard()
}

extension ComposerSurface {
    func finish(_ outcome: ComposerOutcome) { hide() }
    func takeKeyboard() {}
}

/// The Ask window, where the pill appears: talk or type, then Return or the send button
/// sends: a question about the screen, or in agent mode (⌘) a task for the agent. Dragged
/// by its background, it opens where it was left.
@MainActor
final class AskComposerPanel: ComposerPanel {
    var onOpenChats: (() -> Void)?
    var onOpenConnectors: (() -> Void)?

    init(pointerLocation: @escaping @MainActor () -> CGPoint = { NSEvent.mouseLocation }) {
        super.init(size: AskComposerView.size, pointerLocation: pointerLocation)
        takesModeKeys = true
        setContent(AskComposerView(model: model, onSend: { [weak self] in self?.onSend?() },
                                   onOpenChats: { [weak self] in self?.onOpenChats?() },
                                   onOpenConnectors: { [weak self] in self?.onOpenConnectors?() },
                                   onClose: { [weak self] in self?.onCancel?() },
                                   onDragMoved: { [weak self] in self?.dragMoved($0, grabbed: $1) },
                                   onDragEnded: { [weak self] in self?.dragEnded() }))
    }
}
