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

    var question: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// While talking, send means "finish the words and send them".
    var canSend: Bool { mode != .typing || !question.isEmpty }

    var title: String {
        switch mode {
        case .voice: return "Listening"
        case .finishing: return "Writing it down…"
        case .typing: return "Ask about your screen"
        }
    }

    var hint: String {
        switch mode {
        case .voice: return "\(keyName) to stop   ·   Return to send   ·   Esc to cancel"
        case .finishing: return "Return to send   ·   Esc to cancel"
        case .typing: return "\(keyName) to talk   ·   Return to send   ·   Esc to cancel"
        }
    }

    func reset(mode: ComposerMode) {
        text = ""
        level = 0
        notice = nil
        self.mode = mode
    }
}

/// Where the question is written. The floating window in the app; a fake in tests.
@MainActor
protocol ComposerSurface: AnyObject {
    var model: ComposerModel { get }
    var onSend: (() -> Void)? { get set }
    var onCancel: (() -> Void)? { get set }
    func show(on screen: NSScreen?)
    func hide()
    func updateLevel(_ level: Float)
    /// Takes the keyboard back if it went to another app while the window stayed up.
    func takeKeyboard()
}

extension ComposerSurface {
    func takeKeyboard() {}
}

/// The Ask window, where the pill appears: talk or type, then Return or the send button.
@MainActor
final class AskComposerPanel: ComposerPanel {
    var onOpenChats: (() -> Void)?

    init() {
        super.init(size: AskComposerView.size)
        setContent(AskComposerView(model: model, onSend: { [weak self] in self?.onSend?() },
                                   onOpenChats: { [weak self] in self?.onOpenChats?() }))
    }
}
