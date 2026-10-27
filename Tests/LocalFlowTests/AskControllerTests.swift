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
    var onMinimizeChange: (() -> Void)?
    private(set) var isVisible = false
    private(set) var isMinimized = false
    private(set) var closeHint = ""

    func show(question: String, on screen: NSScreen?) {
        model.reset()
        model.question = question
        isVisible = true
        isMinimized = false
    }

    func hide() {
        isVisible = false
        isMinimized = false
    }

    /// What the – button and the chip do in the real bubble.
    func minimize() {
        isMinimized = true
        onMinimizeChange?()
    }

    func expand() {
        isMinimized = false
        onMinimizeChange?()
    }

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

    @Test("send a question and the answer streams into the bubble")
    func happyPath() async {
        let controller = makeController()

        controller.prepare(on: nil)
        #expect(indicator.isShowing)
        controller.submit("What's my CI?")
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

    @Test("opening the window loads the model while the user talks or types")
    func preparePreloads() async {
        let controller = makeController()

        controller.prepare(on: nil)
        try? await Task.sleep(for: .milliseconds(30))

        #expect(client.preloads == [Settings.shared.effectiveAskModel])
        #expect(!surface.isVisible)
    }

    @Test("the screenshot is taken when the question is sent, not before")
    func capturesAtSend() async {
        var captures = 0
        let controller = makeController(capture: { _ in captures += 1; return Data([9]) })

        controller.prepare(on: nil)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(captures == 0)
        controller.submit("What is this?")
        await settle(controller)

        #expect(captures == 1)
        #expect(surface.model.phase == .done)
    }

    @Test("a blank question never reaches the model")
    func blankQuestion() async {
        let controller = makeController()

        controller.prepare(on: nil)
        controller.submit("   \n ")
        await settle(controller)

        #expect(client.bodies.isEmpty)
        #expect(!surface.isVisible)
        #expect(!indicator.isShowing)
    }

    @Test("cancelling the window takes the outline down")
    func cancelPreparing() {
        let controller = makeController()

        controller.prepare(on: nil)
        controller.cancelPreparing()

        #expect(!indicator.isShowing)
    }

    @Test("an Ollama failure shows the fix in the bubble", arguments: [
        AskError.ollamaNotRunning, .modelMissing("qwen3.5:9b"), .timedOut,
    ])
    func modelFailure(error: AskError) async {
        client.failure = error
        client.tokens = []
        let controller = makeController()

        controller.prepare(on: nil)
        controller.submit("What is this?")
        await settle(controller)

        #expect(surface.model.phase == .failed(error.message))
        #expect(!indicator.isShowing)
    }

    @Test("a failed screenshot is reported, not sent")
    func captureFailure() async {
        let controller = makeController(capture: { _ in throw AskError.screenCaptureFailed("denied") })

        controller.prepare(on: nil)
        controller.submit("What is this?")
        await settle(controller)

        #expect(surface.model.phase == .failed(AskError.screenCaptureFailed("denied").message))
        #expect(client.bodies.isEmpty)
    }

    @Test("closing mid-answer stops it, and nothing writes into the closed bubble")
    func dismissMidAnswer() async {
        client.tokens = ["one ", "two ", "three ", "four "]
        client.tokenDelay = .milliseconds(40)
        let controller = makeController()

        controller.submit("Count for me")
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
        controller.submit("What is this?")
        await settle(controller)

        surface.onClose?()

        #expect(!surface.isVisible)
        #expect(!controller.isActive)
    }

    @Test("reports when an answer goes up, tucks away, and comes down, so Esc knows")
    func stateChanges() async {
        let controller = makeController()
        var expanded: [Bool] = []
        controller.onChange = { expanded.append(controller.isExpanded) }

        controller.submit("What is this?")
        await settle(controller)
        surface.minimize()
        surface.expand()
        controller.dismiss()

        #expect(expanded == [true, false, true, false])
    }

    @Test("a working animation shows from send until the first word")
    func thinkingUntilFirstWord() async {
        client.tokenDelay = .milliseconds(80)
        let controller = makeController()

        controller.submit("What is this?")
        for _ in 0..<100 where surface.model.phase == .looking {
            try? await Task.sleep(for: .milliseconds(2))
        }

        #expect(surface.model.phase == .thinking)
        #expect(surface.model.answer.isEmpty)
        await settle(controller)
        #expect(surface.model.phase == .done)
    }

    @Test("minimized, the answer keeps coming, and it comes back whole")
    func minimizeKeepsAnswering() async {
        client.tokens = ["one ", "two ", "three"]
        client.tokenDelay = .milliseconds(30)
        let controller = makeController()

        controller.submit("Count for me")
        surface.minimize()
        #expect(controller.isActive)
        #expect(!controller.isExpanded)
        await settle(controller)
        surface.expand()

        #expect(surface.model.answer == "one two three")
        #expect(surface.model.phase == .done)
        #expect(controller.isExpanded)
    }

    @Test("the blue outline is up only while Ask is looking: never minimized, never over the answer")
    func outlineOnlyWhileLooking() async {
        client.tokenDelay = .milliseconds(120)
        let controller = makeController()

        controller.prepare(on: nil)
        #expect(indicator.isShowing)
        controller.submit("What is this?")
        for _ in 0..<100 where surface.model.phase != .thinking {
            try? await Task.sleep(for: .milliseconds(2))
        }
        #expect(indicator.isShowing)
        surface.minimize()
        #expect(!indicator.isShowing)
        surface.expand()
        #expect(indicator.isShowing)
        for _ in 0..<200 where surface.model.answer.isEmpty {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(!indicator.isShowing)
        surface.minimize()
        surface.expand()
        #expect(!indicator.isShowing)
        await settle(controller)
        #expect(!indicator.isShowing)
    }

    @Test("Esc tucks the answer away and brings it back, and says where it is")
    func minimizeAndExpandByKey() async {
        let controller = makeController()
        #expect(controller.presence == .none)
        controller.submit("What is this?")
        await settle(controller)
        #expect(controller.presence == .open)

        controller.minimize()
        #expect(controller.presence == .tucked)
        #expect(surface.isVisible)

        controller.expand()
        #expect(controller.presence == .open)
        controller.dismiss()
        #expect(controller.presence == .none)
    }

    @Test("closing from the chip closes it all")
    func closeFromChip() async {
        let controller = makeController()
        controller.submit("What is this?")
        await settle(controller)
        surface.minimize()

        surface.onClose?()

        #expect(!surface.isVisible)
        #expect(!controller.isActive)
    }

    @Test("the close hint reaches the bubble")
    func closeHint() {
        let controller = makeController()

        controller.updateCloseHint("Fn to close")

        #expect(surface.closeHint == "Fn to close")
    }
}

@MainActor
@Suite("Ask: controller memory")
struct AskControllerMemoryTests {
    let client = FakeModelClient()
    let surface = FakeSurface()

    private func makeController(limit: @escaping @MainActor () -> Int = { 5 }) -> AskController {
        AskController(client: client, surface: surface, indicator: FakeIndicator(),
                      capture: { _ in Data([1]) }, memoryLimit: limit, closeHint: "")
    }

    private func ask(_ controller: AskController, _ question: String) async {
        controller.submit(question)
        for _ in 0..<200 where controller.isRunning {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("a follow-up sends the earlier question and answer along")
    func followUpHasContext() async {
        let controller = makeController()

        await ask(controller, "What's this slide?")
        await ask(controller, "Give me an example")

        let second = client.bodies[1].messages
        #expect(second.map(\.role) == ["system", "user", "assistant", "user"])
        #expect(second[1].content == "What's this slide?")
        #expect(second[2].content == "Your CI is 3.62 to 3.75.")
        #expect(controller.rememberedTurns == 2)
    }

    @Test("only the last N chats are kept")
    func limitApplies() async {
        let controller = makeController(limit: { 2 })

        for question in ["One?", "Two?", "Three?", "Four?"] {
            await ask(controller, question)
        }

        #expect(controller.rememberedTurns == 2)
        let last = client.bodies[3].messages
        #expect(last.filter { $0.role == "user" }.map(\.content) == ["Two?", "Three?", "Four?"])
    }

    @Test("a failed answer isn't remembered")
    func failuresNotRemembered() async {
        client.failure = AskError.timedOut
        client.tokens = ["partial"]
        let controller = makeController()

        await ask(controller, "What's this?")

        #expect(controller.rememberedTurns == 0)
    }

    @Test("forgetting clears the conversation")
    func forget() async {
        let controller = makeController()
        await ask(controller, "What's this slide?")

        controller.forgetConversation()

        #expect(controller.rememberedTurns == 0)
    }

    @Test("Forget pressed while an answer is still typing keeps that answer out too")
    func forgetMidAnswer() async {
        client.tokens = ["one ", "two ", "three"]
        client.tokenDelay = .milliseconds(30)
        let controller = makeController()

        controller.submit("Count for me")
        for _ in 0..<100 where surface.model.answer.isEmpty {
            try? await Task.sleep(for: .milliseconds(5))
        }
        controller.forgetConversation()
        for _ in 0..<200 where controller.isRunning {
            try? await Task.sleep(for: .milliseconds(5))
        }

        #expect(surface.model.phase == .done)
        #expect(controller.rememberedTurns == 0)
    }

    @Test("lowering the limit forgets the extra turns right away")
    func lowerLimitTrims() async {
        var limit = 5
        let controller = makeController(limit: { limit })
        for question in ["One?", "Two?", "Three?"] {
            await ask(controller, question)
        }

        limit = 1
        controller.applyMemoryLimit()
        #expect(controller.rememberedTurns == 1)
        limit = 0
        controller.applyMemoryLimit()
        #expect(controller.rememberedTurns == 0)
    }
}
