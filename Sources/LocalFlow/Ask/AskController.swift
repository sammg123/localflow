import AppKit
import Foundation

/// Where the answer shows. The floating bubble in the app; a fake in tests.
@MainActor
protocol AnswerSurface: AnyObject {
    var model: AnswerModel { get }
    /// Up in any form: the full bubble or the minimized chip.
    var isVisible: Bool { get }
    var isMinimized: Bool { get }
    var onClose: (() -> Void)? { get set }
    /// The user minimized or expanded it (the – button, the chip, or covering it).
    var onMinimizeChange: (() -> Void)? { get set }
    func show(on screen: NSScreen?)
    func hide()
    func updateCloseHint(_ hint: String)
}

/// The "I'm looking at your screen" signal. The blue outline in the app.
@MainActor
protocol ListeningIndicator: AnyObject {
    func show(on screen: NSScreen?)
    func hide()
}

extension AnswerPanel: AnswerSurface {}
extension ScreenGlow: ListeningIndicator {}

/// Ask's answering half: takes a finished question, screenshots the display, streams
/// the local vision model's answer into a bubble where the pill appears, and remembers
/// the last few turns for follow-ups. The Ask window (AskSession) writes the question.
@MainActor
final class AskController {
    typealias ScreenCapture = @MainActor (NSScreen?) async throws -> Data

    private let client: AskModelClient
    private let answerPanel: AnswerSurface
    private let glow: ListeningIndicator
    private let captureScreen: ScreenCapture
    /// How many finished questions to remember for follow-ups (read per ask).
    private let memoryLimit: @MainActor () -> Int
    private let settings = Settings.shared
    /// In memory only: gone on quit, never written to disk or the log.
    private var turns: [AskTurn] = []
    /// Bumped by Forget, so an answer still arriving when it's pressed isn't remembered.
    private var memoryEpoch = 0

    /// An answer went up, came down, minimized or expanded.
    var onChange: (() -> Void)?

    private var screen: NSScreen?
    /// The Ask window is open: the user is asking about this screen.
    private var isComposing = false
    private var run: Task<Void, Never>?
    /// Bumped by every dismiss/submit so a cancelled run can never touch a newer bubble.
    private var generation = 0

    init(client: AskModelClient = OllamaClient(),
         surface: AnswerSurface? = nil,
         indicator: ListeningIndicator? = nil,
         capture: @escaping ScreenCapture = AskController.captureDisplay,
         memoryLimit: @escaping @MainActor () -> Int = { Settings.shared.askMemoryTurns },
         closeHint: String) {
        self.client = client
        self.memoryLimit = memoryLimit
        answerPanel = surface ?? AnswerPanel(closeHint: closeHint)
        glow = indicator ?? ScreenGlow()
        captureScreen = capture
        answerPanel.updateCloseHint(closeHint)
        answerPanel.onClose = { [weak self] in self?.dismiss() }
        answerPanel.onMinimizeChange = { [weak self] in
            self?.updateOutline()
            self?.onChange?()
        }
    }

    static func captureDisplay(_ screen: NSScreen?) async throws -> Data {
        guard let screen else { throw AskError.screenCaptureFailed("no display found") }
        return try await ScreenCapturer.capturePNG(of: screen)
    }

    /// A bubble or chip is up, or an answer is on its way.
    var isActive: Bool { answerPanel.isVisible || run != nil }

    /// The full bubble is up (not minimized): what Esc and Fn close.
    var isExpanded: Bool { answerPanel.isVisible && !answerPanel.isMinimized }

    /// An answer is being worked on (capturing or streaming).
    var isRunning: Bool { run != nil }

    var rememberedTurns: Int { turns.count }

    func forgetConversation() {
        turns = []
        memoryEpoch += 1
    }

    /// The memory setting changed: a lower limit forgets the extra turns now, not later.
    func applyMemoryLimit() {
        turns = Array(turns.suffix(max(0, memoryLimit())))
    }

    func updateCloseHint(_ hint: String) {
        answerPanel.updateCloseHint(hint)
    }

    /// The Ask window is opening: close the last answer, start loading the model while
    /// the user talks or types, and outline the screen (left out of the screenshot).
    func prepare(on screen: NSScreen?) {
        dismiss()
        self.screen = screen
        let client = self.client
        let model = settings.effectiveAskModel
        Task.detached(priority: .utility) { await client.preload(model: model) }
        isComposing = true
        updateOutline()
    }

    /// The Ask window closed without sending.
    func cancelPreparing() {
        isComposing = false
        updateOutline()
    }

    /// The blue outline means "Ask is looking at this screen": while the question is
    /// being written, then until the first word. Never over an answer, never minimized.
    private func updateOutline() {
        let phase = answerPanel.model.phase
        let looking = run != nil && isExpanded && (phase == .looking || phase == .thinking)
        if isComposing || looking {
            glow.show(on: screen)
        } else {
            glow.hide()
        }
    }

    /// Answer a question about the screen as it is right now.
    func submit(_ question: String) {
        let question = String(question.trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(AskLimits.maxQuestionLength))
        isComposing = false
        guard !question.isEmpty else {
            updateOutline()
            return
        }
        generation += 1
        let current = generation
        answerPanel.show(on: screen)
        answerPanel.model.question = question
        run = Task { [weak self] in
            await self?.respond(question: question, generation: current)
            if self?.generation == current {
                self?.run = nil
                self?.updateOutline()
            }
        }
        updateOutline()
        onChange?()
    }

    func dismiss() {
        let wasActive = isActive
        generation += 1
        run?.cancel()
        run = nil
        isComposing = false
        answerPanel.hide()
        updateOutline()
        if wasActive { onChange?() }
    }

    private func respond(question: String, generation: Int) async {
        let model = answerPanel.model
        let isCurrent = { [weak self] in self?.generation == generation && !Task.isCancelled }
        let started = ContinuousClock.now
        let epoch = memoryEpoch
        func fail(_ message: String) {
            guard isCurrent() else { return }
            model.phase = .failed(message)
            updateOutline()
            SoundPlayer.playError()
        }

        let png: Data
        do {
            png = try await captureScreen(screen)
        } catch {
            FlowLog.shared.write("ask screen capture failed: \(error.localizedDescription)")
            fail((error as? AskError)?.message ?? AskError.screenCaptureFailed(error.localizedDescription).message)
            return
        }
        guard isCurrent() else { return }
        model.phase = .thinking

        let limit = max(0, memoryLimit())
        let history = AskMemory.fitting(Array(turns.suffix(limit)), budget: AskLimits.historyBudget)
        let body = OllamaChatBody.ask(model: settings.effectiveAskModel, question: question,
                                      imageBase64: png.base64EncodedString(), history: history)
        var firstToken: Duration?
        do {
            for try await token in client.stream(body) {
                guard isCurrent() else { return }
                if firstToken == nil {
                    firstToken = started.duration(to: .now)
                    model.phase = .answering
                    updateOutline()
                }
                model.answer += token
            }
            guard isCurrent() else { return }
            guard !model.answer.isEmpty else {
                fail("The model sent back an empty answer. Ask again.")
                return
            }
            model.phase = .done
            if epoch == memoryEpoch {
                turns = AskMemory.remembering(turns, adding: AskTurn(question: question, answer: model.answer),
                                              limit: max(0, memoryLimit()))
            }
            FlowLog.shared.write("ask answered: question \(question.count) chars, image \(png.count / 1024) KB, "
                + "first token \(firstToken.map { "\($0)" } ?? "-"), \(model.answer.count) chars in \(started.duration(to: .now))")
        } catch {
            FlowLog.shared.write("ask failed: \((error as? AskError)?.logName ?? String(describing: type(of: error)))")
            fail((error as? AskError)?.message ?? error.localizedDescription)
        }
    }
}
