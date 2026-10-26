import AppKit
import Foundation

/// What releasing the Ask key means: a quick tap only closes the last answer.
enum AskRelease: Equatable {
    case ask
    case dismissOnly

    static func forHeld(_ held: TimeInterval) -> AskRelease {
        held >= HotkeyMonitor.tapThreshold ? .ask : .dismissOnly
    }
}

/// Where the answer shows. The floating bubble in the app; a fake in tests.
@MainActor
protocol AnswerSurface: AnyObject {
    var model: AnswerModel { get }
    var isVisible: Bool { get }
    var onClose: (() -> Void)? { get set }
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

/// Ask mode: hold the Ask key, speak a question about the screen, get a typed answer
/// from a local vision model in a bubble where the pill appears.
///
/// The recording itself belongs to AppController (one mic, one state machine). This
/// owns everything Ask adds: the screenshot, the outline, the model call, the bubble.
@MainActor
final class AskController {
    typealias ScreenCapture = @MainActor (NSScreen?) async throws -> Data

    private let client: AskModelClient
    private let answerPanel: AnswerSurface
    private let glow: ListeningIndicator
    private let captureScreen: ScreenCapture
    private let rules = RulesPolisher()
    private let settings = Settings.shared

    private var screen: NSScreen?
    /// Started on key-down, so the screenshot is what the user saw when they pressed.
    private var capture: Task<Result<Data, Error>, Never>?
    private var run: Task<Void, Never>?
    /// Bumped by every dismiss/answer so a cancelled run can never touch a newer bubble.
    private var generation = 0

    /// How long "didn't catch a question" stays up before the bubble closes itself.
    private static let emptyQuestionDismissDelay: Duration = .seconds(3)

    init(client: AskModelClient = OllamaClient(),
         surface: AnswerSurface? = nil,
         indicator: ListeningIndicator? = nil,
         capture: @escaping ScreenCapture = AskController.captureDisplay,
         closeHint: String) {
        self.client = client
        answerPanel = surface ?? AnswerPanel(closeHint: closeHint)
        glow = indicator ?? ScreenGlow()
        captureScreen = capture
        answerPanel.updateCloseHint(closeHint)
        answerPanel.onClose = { [weak self] in self?.dismiss() }
    }

    static func captureDisplay(_ screen: NSScreen?) async throws -> Data {
        guard let screen else { throw AskError.screenCaptureFailed("no display found") }
        return try await ScreenCapturer.capturePNG(of: screen)
    }

    /// A bubble is up or an answer is on its way.
    var isActive: Bool { answerPanel.isVisible || run != nil }

    /// An answer is being worked on (transcribing, capturing, or streaming).
    var isRunning: Bool { run != nil }

    func updateCloseHint(_ hint: String) {
        answerPanel.updateCloseHint(hint)
    }

    /// Key down: note which display the user is on. Nothing heavier yet: the press may
    /// turn out to be a tap (close) or part of a shortcut like Option+arrow.
    func beginListening() {
        dismiss()
        screen = ScreenCapturer.screenUnderMouse()
    }

    /// The press is clearly a hold: take the screenshot, start loading the model while
    /// the user talks, then put the outline up (it is left out of the screenshot).
    func startLooking() {
        if capture == nil { capture = makeCapture() }
        let client = self.client
        let model = settings.effectiveAskModel
        Task.detached(priority: .utility) { await client.preload(model: model) }
        glow.show(on: screen)
    }

    private func makeCapture() -> Task<Result<Data, Error>, Never> {
        let screen = self.screen
        let captureScreen = self.captureScreen
        return Task { @MainActor in
            do {
                return .success(try await captureScreen(screen))
            } catch {
                return .failure(error)
            }
        }
    }

    func cancelListening() {
        capture?.cancel()
        capture = nil
        glow.hide()
    }

    /// Key up: transcribe the question, then answer it from the screenshot.
    func answer(samples: [Float], engine: Transcriber) {
        // A release right at the hold threshold can beat startLooking(); capture now.
        let capture = self.capture ?? makeCapture()
        self.capture = nil
        generation += 1
        let current = generation
        answerPanel.show(on: screen)
        run = Task { [weak self] in
            await self?.respond(samples: samples, engine: engine, capture: capture, generation: current)
            if self?.generation == current { self?.run = nil }
        }
    }

    func dismiss() {
        generation += 1
        run?.cancel()
        run = nil
        cancelListening()
        answerPanel.hide()
    }

    private func respond(samples: [Float], engine: Transcriber,
                         capture: Task<Result<Data, Error>, Never>, generation: Int) async {
        let model = answerPanel.model
        let isCurrent = { [weak self] in self?.generation == generation && !Task.isCancelled }
        let started = ContinuousClock.now
        func fail(_ message: String) {
            guard isCurrent() else { return }
            glow.hide()
            model.phase = .failed(message)
            SoundPlayer.playError()
        }

        let question: String
        do {
            let raw = try await engine.transcribe(samples: samples)
            question = rules.apply(raw, category: .other, replacements: settings.replacements,
                                   spokenCommands: false, toneMatching: false)
        } catch {
            FlowLog.shared.write("ask transcription failed: \(error.localizedDescription)")
            fail("Couldn't transcribe the question: \(error.localizedDescription)")
            return
        }
        guard isCurrent() else { return }
        guard !question.isEmpty else {
            fail("Didn't catch a question. Hold the Ask key and ask again.")
            try? await Task.sleep(for: Self.emptyQuestionDismissDelay)
            if isCurrent() { dismiss() }
            return
        }
        model.question = question

        let png: Data
        switch await capture.value {
        case .success(let data):
            png = data
        case .failure(let error):
            FlowLog.shared.write("ask screen capture failed: \(error.localizedDescription)")
            fail((error as? AskError)?.message ?? AskError.screenCaptureFailed(error.localizedDescription).message)
            return
        }
        guard isCurrent() else { return }

        let body = OllamaChatBody.ask(model: settings.effectiveAskModel, question: question,
                                      imageBase64: png.base64EncodedString())
        var firstToken: Duration?
        do {
            for try await token in client.stream(body) {
                guard isCurrent() else { return }
                if firstToken == nil {
                    firstToken = started.duration(to: .now)
                    glow.hide()
                    model.phase = .answering
                }
                model.answer += token
            }
            guard isCurrent() else { return }
            guard !model.answer.isEmpty else {
                fail("The model sent back an empty answer. Ask again.")
                return
            }
            model.phase = .done
            FlowLog.shared.write("ask answered: question \(question.count) chars, image \(png.count / 1024) KB, "
                + "first token \(firstToken.map { "\($0)" } ?? "-"), \(model.answer.count) chars in \(started.duration(to: .now))")
        } catch {
            FlowLog.shared.write("ask failed: \(error)")
            fail((error as? AskError)?.message ?? error.localizedDescription)
        }
    }
}
