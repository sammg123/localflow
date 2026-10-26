import AppKit
import Foundation
import Testing
@testable import LocalFlow

/// Stands in for Ollama: streams scripted tokens (or fails) and counts preloads.
final class FakeModelClient: AskModelClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _preloads: [String] = []
    private var _bodies: [OllamaChatBody] = []
    var tokens: [String] = ["Your CI is ", "3.62 to 3.75."]
    var failure: Error?
    /// Pause between tokens, so a test can dismiss mid-answer.
    var tokenDelay: Duration = .zero

    var preloads: [String] { lock.withLock { _preloads } }
    var bodies: [OllamaChatBody] { lock.withLock { _bodies } }

    func preload(model: String) async {
        lock.withLock { _preloads.append(model) }
    }

    func stream(_ body: OllamaChatBody) -> AsyncThrowingStream<String, Error> {
        lock.withLock { _bodies.append(body) }
        let tokens = self.tokens, failure = self.failure, delay = self.tokenDelay
        return AsyncThrowingStream { continuation in
            let task = Task {
                for token in tokens {
                    if delay > .zero { try? await Task.sleep(for: delay) }
                    if Task.isCancelled { break }
                    continuation.yield(token)
                }
                if let failure { continuation.finish(throwing: failure) } else { continuation.finish() }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

final class FakeTranscriber: Transcriber {
    let state: TranscriberState = .ready
    let displayName = "Fake"
    var text: String

    init(text: String) { self.text = text }

    func prepare() async throws {}
    func transcribe(samples: [Float]) async throws -> String { text }
}

@MainActor
final class FakeSurface: AnswerSurface {
    let model = AnswerModel()
    var onClose: (() -> Void)?
    private(set) var isVisible = false
    private(set) var closeHint = ""

    func show(on screen: NSScreen?) {
        model.reset()
        isVisible = true
    }

    func hide() { isVisible = false }
    func updateCloseHint(_ hint: String) { closeHint = hint }
}

@MainActor
final class FakeIndicator: ListeningIndicator {
    private(set) var isShowing = false
    func show(on screen: NSScreen?) { isShowing = true }
    func hide() { isShowing = false }
}

@MainActor
@Suite("Ask: controller flow")
struct AskControllerTests {
    let client = FakeModelClient()
    let surface = FakeSurface()
    let indicator = FakeIndicator()

    private func makeController(capture: @escaping @MainActor (NSScreen?) async throws -> Data = { _ in Data([1, 2, 3]) })
        -> AskController {
        AskController(client: client, surface: surface, indicator: indicator, capture: capture, closeHint: "Tap to close")
    }

    /// Lets the controller's run task finish.
    private func settle(_ controller: AskController) async {
        for _ in 0..<200 where controller.isRunning {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("hold, ask, and the answer streams into the bubble")
    func happyPath() async {
        let controller = makeController()

        controller.beginListening()
        controller.startLooking()
        #expect(indicator.isShowing)
        controller.answer(samples: [0.1], engine: FakeTranscriber(text: "What's my CI?"))
        await settle(controller)

        #expect(surface.isVisible)
        #expect(surface.model.question == "What's my CI?")
        #expect(surface.model.answer == "Your CI is 3.62 to 3.75.")
        #expect(surface.model.phase == .done)
        #expect(!indicator.isShowing)
        let body = try? #require(client.bodies.first)
        #expect(body?.messages.last?.images == [Data([1, 2, 3]).base64EncodedString()])
        #expect(body?.model == Settings.shared.effectiveAskModel)
    }

    @Test("a tap does no heavy work: no screenshot, no model load")
    func tapIsCheap() async {
        var captured = false
        let controller = makeController(capture: { _ in captured = true; return Data() })

        controller.beginListening()
        controller.cancelListening()
        try? await Task.sleep(for: .milliseconds(30))

        #expect(!captured)
        #expect(client.preloads.isEmpty)
        #expect(!indicator.isShowing)
    }

    @Test("holding loads the model while the user is still talking")
    func holdPreloads() async {
        let controller = makeController()

        controller.beginListening()
        controller.startLooking()
        try? await Task.sleep(for: .milliseconds(30))

        #expect(client.preloads == [Settings.shared.effectiveAskModel])
    }

    @Test("a release that beats the hold step still takes the screenshot")
    func releaseBeforeLooking() async {
        var captured = false
        let controller = makeController(capture: { _ in captured = true; return Data([9]) })

        controller.beginListening()
        controller.answer(samples: [0.1], engine: FakeTranscriber(text: "What is this?"))
        await settle(controller)

        #expect(captured)
        #expect(surface.model.phase == .done)
    }

    @Test("silence says so instead of asking the model")
    func emptyQuestion() async {
        let controller = makeController()

        controller.beginListening()
        controller.answer(samples: [0], engine: FakeTranscriber(text: "  "))
        for _ in 0..<100 where surface.model.phase == .looking {
            try? await Task.sleep(for: .milliseconds(5))
        }

        #expect(surface.model.phase == .failed("Didn't catch a question. Hold the Ask key and ask again."))
        #expect(client.bodies.isEmpty)
        controller.dismiss()
    }

    @Test("an Ollama failure shows the fix in the bubble", arguments: [
        AskError.ollamaNotRunning, .modelMissing("qwen3.5:9b"), .timedOut,
    ])
    func modelFailure(error: AskError) async {
        client.failure = error
        client.tokens = []
        let controller = makeController()

        controller.beginListening()
        controller.answer(samples: [0.1], engine: FakeTranscriber(text: "What is this?"))
        await settle(controller)

        #expect(surface.model.phase == .failed(error.message))
        #expect(!indicator.isShowing)
    }

    @Test("a failed screenshot is reported, not sent")
    func captureFailure() async {
        let controller = makeController(capture: { _ in throw AskError.screenCaptureFailed("denied") })

        controller.beginListening()
        controller.startLooking()
        controller.answer(samples: [0.1], engine: FakeTranscriber(text: "What is this?"))
        await settle(controller)

        #expect(surface.model.phase == .failed(AskError.screenCaptureFailed("denied").message))
        #expect(client.bodies.isEmpty)
    }

    @Test("closing mid-answer stops it, and nothing writes into the closed bubble")
    func dismissMidAnswer() async {
        client.tokens = ["one ", "two ", "three ", "four "]
        client.tokenDelay = .milliseconds(40)
        let controller = makeController()

        controller.beginListening()
        controller.answer(samples: [0.1], engine: FakeTranscriber(text: "Count for me"))
        for _ in 0..<100 where surface.model.answer.isEmpty {
            try? await Task.sleep(for: .milliseconds(5))
        }
        controller.dismiss()
        let frozen = surface.model.answer
        try? await Task.sleep(for: .milliseconds(200))

        #expect(!surface.isVisible)
        #expect(!controller.isActive)
        #expect(surface.model.answer == frozen)
        #expect(surface.model.phase == .answering)
    }

    @Test("the ✕ button closes through the controller")
    func closeButton() async {
        let controller = makeController()
        controller.beginListening()
        controller.answer(samples: [0.1], engine: FakeTranscriber(text: "What is this?"))
        await settle(controller)

        surface.onClose?()

        #expect(!surface.isVisible)
        #expect(!controller.isActive)
    }

    @Test("the close hint reaches the bubble")
    func closeHint() {
        let controller = makeController()

        controller.updateCloseHint("Tap Right ⌥ or Fn to close")

        #expect(surface.closeHint == "Tap Right ⌥ or Fn to close")
    }
}
