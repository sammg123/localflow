import AppKit
import Foundation
import Testing
@testable import LocalFlow

/// Stands in for AppController's microphone.
@MainActor
final class FakeMic: AskMicrophone {
    var canStart = true
    var audio: [Float] = Array(repeating: 0.1, count: 16_000)
    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var discards = 0
    private(set) var isOn = false

    func startAsk() -> Bool {
        guard canStart else { return false }
        starts += 1
        isOn = true
        return true
    }

    func stopAsk() -> [Float] {
        stops += 1
        isOn = false
        return audio
    }

    func discardAsk() {
        discards += 1
        isOn = false
    }

    var capturedSampleCount: Int { audio.count }
    func samples(in range: Range<Int>) -> [Float] { Array(audio[range]) }
}

@MainActor
final class FakeComposer: ComposerSurface {
    let model = ComposerModel()
    var onSend: (() -> Void)?
    var onCancel: (() -> Void)?
    private(set) var isVisible = false
    private(set) var shows = 0
    private(set) var outcomes: [ComposerOutcome] = []

    func finish(_ outcome: ComposerOutcome) {
        outcomes.append(outcome)
        isVisible = false
    }

    func show(on screen: NSScreen?) {
        shows += 1
        isVisible = true
    }

    func hide() { isVisible = false }
    func updateLevel(_ level: Float) { model.level = level }
}

final class CountingTranscriber: Transcriber, @unchecked Sendable {
    let state: TranscriberState = .ready
    let displayName = "Counting"
    let text: String
    private(set) var calls = 0

    init(text: String) { self.text = text }

    func prepare() async throws {}
    func transcribe(samples: [Float]) async throws -> String {
        calls += 1
        return text
    }
}

@MainActor
@Suite("Ask: the window, end to end with fakes")
struct AskSessionTests {
    let mic = FakeMic()
    let composer = FakeComposer()
    let client = FakeModelClient()
    let surface = FakeSurface()
    let indicator = FakeIndicator()

    private func makeSession(saying text: String = "what's my confidence interval",
                             canOpen: Bool = true) -> (AskSession, CountingTranscriber) {
        let transcriber = CountingTranscriber(text: text)
        let answers = AskController(client: client, surface: surface, indicator: indicator,
                                    capture: { _ in Data([7]) }, memoryLimit: { 5 }, closeHint: "")
        let session = AskSession(
            mic: mic, composer: composer, answers: answers,
            transcribe: { samples in try await transcriber.transcribe(samples: samples) },
            canOpen: { canOpen },
            chime: {},
            swallowPress: {},
            holdDelay: nil,
            liveInterval: nil
        )
        return (session, transcriber)
    }

    private func until(_ condition: () -> Bool) async {
        for _ in 0..<400 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func tap(_ session: AskSession, at time: TimeInterval) {
        session.keyDown(at: time)
        session.keyUp(held: 0.1, at: time + 0.1)
    }

    @Test("going to Chats from the Ask window keeps what was typed for when it opens again")
    func draftSurvivesChats() {
        let (session, _) = makeSession()
        tap(session, at: 0)
        composer.model.text = "which strategy wins"

        session.closeKeepingDraft()

        #expect(!composer.isVisible)
        #expect(session.phase == .closed)
        session.openForTyping()
        #expect(composer.isVisible)
        #expect(composer.model.mode == .typing)
        #expect(composer.model.text == "which strategy wins")
        // Kept once: the next time it opens empty.
        session.cancel()
        session.openForTyping()
        #expect(composer.model.text.isEmpty)
    }

    @Test("tap to type, tap to talk, tap to stop: the question waits in the window until Return")
    func tapTalkTap() async {
        let (session, _) = makeSession()

        tap(session, at: 0)
        #expect(composer.isVisible)
        #expect(composer.model.mode == .typing)
        #expect(!mic.isOn)
        tap(session, at: 1)
        #expect(composer.model.mode == .voice)
        #expect(mic.isOn)
        session.keyDown(at: 3)
        await until { composer.model.mode == .typing }

        #expect(composer.model.text.lowercased() == "what's my confidence interval")
        #expect(client.bodies.isEmpty)
        #expect(composer.isVisible)

        session.send()
        await until { surface.model.phase == .done }

        #expect(!composer.isVisible)
        #expect(client.bodies.last?.messages.last?.content.lowercased() == "what's my confidence interval")
    }

    @Test("a tap opens for typing without ever turning the mic on")
    func tapTypes() async {
        let (session, transcriber) = makeSession()

        tap(session, at: 0)

        #expect(composer.model.mode == .typing)
        #expect(mic.starts == 0)
        #expect(!mic.isOn)
        composer.model.text = "explain this chart"
        session.send()
        await until { surface.model.phase == .done }

        #expect(transcriber.calls == 0)
        #expect(client.bodies.last?.messages.last?.content == "explain this chart")
    }

    @Test("tap, type, then tap to talk: speech lands after the typed words")
    func typeThenTalk() async {
        let (session, _) = makeSession(saying: "which strategy dominates")

        tap(session, at: 0)
        composer.model.text = "In this table,"
        tap(session, at: 2)
        #expect(composer.model.mode == .voice)
        session.keyDown(at: 5)
        await until { composer.model.mode == .typing }

        #expect(composer.model.text.hasPrefix("In this table, "))
        #expect(composer.model.text.lowercased().hasSuffix("which strategy dominates"))
        #expect(client.bodies.isEmpty)
    }

    @Test("hold to talk: release writes it down and waits for Return")
    func holdToTalk() async {
        let (session, _) = makeSession()

        session.keyDown(at: 0)
        #expect(!composer.isVisible)
        #expect(!mic.isOn)
        session.holdReached()
        #expect(composer.isVisible)
        #expect(composer.model.mode == .voice)
        #expect(mic.isOn)
        session.keyUp(held: 1.5, at: 1.5)
        await until { composer.model.mode == .typing }

        #expect(!composer.model.text.isEmpty)
        #expect(client.bodies.isEmpty)
    }

    @Test("Return while talking writes the words down and sends them")
    func returnWhileTalking() async {
        let (session, _) = makeSession()

        tap(session, at: 0)
        tap(session, at: 1)
        session.send()
        await until { surface.model.phase == .done }

        #expect(mic.stops == 1)
        #expect(!composer.isVisible)
        #expect(client.bodies.count == 1)
    }

    @Test("Esc closes the window and the outline, and sends nothing")
    func escCloses() async {
        let (session, _) = makeSession()

        tap(session, at: 0)
        tap(session, at: 1)
        #expect(indicator.isShowing)
        session.cancel()
        try? await Task.sleep(for: .milliseconds(30))

        #expect(!composer.isVisible)
        #expect(!indicator.isShowing)
        #expect(mic.discards == 1)
        #expect(client.bodies.isEmpty)
        #expect(session.phase == .closed)
    }

    @Test("an Option shortcut never shows anything")
    func optionShortcut() {
        let (session, _) = makeSession()

        session.keyDown(at: 0)
        session.otherKey()
        session.keyUp(held: 0.1, at: 0.1)

        #expect(composer.shows == 0)
        #expect(mic.starts == 0)
        #expect(session.phase == .closed)
    }

    @Test("an Option shortcut leaves an answer on screen alone")
    func shortcutKeepsAnswer() async {
        let (session, _) = makeSession()
        tap(session, at: 0)
        composer.model.text = "first"
        session.send()
        await until { surface.model.phase == .done }

        session.keyDown(at: 10)
        session.otherKey()

        #expect(surface.isVisible)
        #expect(surface.model.phase == .done)
    }

    @Test("Option+letter in the box never starts the mic")
    func accentWhileTyping() {
        let (session, _) = makeSession()
        tap(session, at: 0)
        let starts = mic.starts

        session.keyDown(at: 3)
        session.otherKey()

        #expect(mic.starts == starts)
        #expect(session.phase == .typing)
    }

    @Test("without Screen Recording the window doesn't open and the mic is let go")
    func gateRefuses() {
        let (session, _) = makeSession(canOpen: false)

        tap(session, at: 0)

        #expect(composer.shows == 0)
        #expect(!mic.isOn)
        #expect(session.phase == .closed)
    }

    @Test("while a dictation has the mic, a tap still opens for typing and the voice stays off")
    func micBusyTyping() {
        mic.canStart = false
        let (session, _) = makeSession()

        tap(session, at: 0)
        tap(session, at: 1)

        #expect(composer.shows == 1)
        #expect(composer.model.mode == .typing)
        #expect(session.phase == .typing)
    }

    @Test("while a dictation has the mic, holding the key shows nothing")
    func micBusyHold() {
        mic.canStart = false
        let (session, _) = makeSession()

        session.keyDown(at: 0)
        session.holdReached()
        session.keyUp(held: 1.5, at: 1.5)

        #expect(composer.shows == 0)
        #expect(session.phase == .closed)
    }

    @Test("Return with an empty box sends nothing and keeps it open")
    func emptySend() async {
        let (session, _) = makeSession()

        tap(session, at: 0)
        session.send()
        try? await Task.sleep(for: .milliseconds(30))

        #expect(client.bodies.isEmpty)
        #expect(composer.isVisible)
        #expect(session.phase == .typing)
    }

    @Test("a huge paste is cut to the question limit before it's sent")
    func longQuestion() async {
        let (session, _) = makeSession()

        tap(session, at: 0)
        composer.model.text = String(repeating: "x", count: AskLimits.maxQuestionLength + 500)
        session.send()
        await until { !client.bodies.isEmpty }

        #expect(client.bodies.last?.messages.last?.content.count == AskLimits.maxQuestionLength)
    }

    @Test("opening the window loads the model and outlines the screen")
    func openPrepares() async {
        let (session, _) = makeSession()

        tap(session, at: 0)
        await until { !client.preloads.isEmpty }

        #expect(indicator.isShowing)
        #expect(client.preloads.count == 1)
    }

    @Test("a tap while an answer is up closes it and opens a new question")
    func tapReplacesAnswer() async {
        let (session, _) = makeSession()
        tap(session, at: 0)
        composer.model.text = "first"
        session.send()
        await until { surface.model.phase == .done }

        tap(session, at: 10)

        #expect(!surface.isVisible)
        #expect(composer.isVisible)
    }

    @Test("Return in agent mode hands the typed words to the agent, not to Ask, and closes the window")
    func agentModeSend() async {
        let (session, _) = makeSession()
        var tasks: [String] = []
        session.onTask = { task, _, _ in tasks.append(task) }
        tap(session, at: 0)
        composer.model.text = "  rename the screenshots on my desktop  "
        composer.model.toggleAgentMode()

        composer.onSend?()

        #expect(tasks == ["rename the screenshots on my desktop"])
        #expect(!composer.isVisible)
        #expect(composer.outcomes == [.handedToAgent])
        #expect(session.phase == .closed)
        #expect(!surface.isVisible)
        #expect(!indicator.isShowing)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(client.bodies.isEmpty)
    }

    @Test("Return in agent mode while talking finishes the words first, then hands them to the agent")
    func agentModeWhileTalking() async {
        let (session, _) = makeSession(saying: "clean up my downloads")
        var tasks: [String] = []
        session.onTask = { task, _, _ in tasks.append(task) }
        tap(session, at: 0)
        tap(session, at: 1)
        #expect(mic.isOn)
        composer.model.toggleAgentMode()

        session.send()
        await until { !tasks.isEmpty }

        #expect(tasks.count == 1)
        #expect(tasks.first?.lowercased().contains("clean up my downloads") == true)
        #expect(!composer.isVisible)
        #expect(client.bodies.isEmpty)
    }

    @Test("an empty box in agent mode hands nothing over and keeps the window open")
    func agentModeEmpty() {
        let (session, _) = makeSession()
        var tasks: [String] = []
        session.onTask = { task, _, _ in tasks.append(task) }
        tap(session, at: 0)
        composer.model.toggleAgentMode()

        session.send()

        #expect(tasks.isEmpty)
        #expect(composer.isVisible)
        #expect(session.phase == .typing)
    }

    @Test("the window opens in Ask mode again after an agent send; Return asks")
    func agentModeDoesNotStick() async {
        let (session, _) = makeSession()
        var tasks: [String] = []
        session.onTask = { task, _, _ in tasks.append(task) }
        tap(session, at: 0)
        composer.model.toggleAgentMode()
        composer.model.text = "open my calendar"
        session.send()

        tap(session, at: 10)
        #expect(!composer.model.agentMode)
        composer.model.text = "what's on screen"
        session.send()
        await until { !client.bodies.isEmpty }

        #expect(tasks == ["open my calendar"])
        #expect(client.bodies.count == 1)
        #expect(composer.outcomes == [.handedToAgent, .asked])
    }

    @Test("⌘ toggles back to Ask before sending: Return then asks")
    func toggledBack() async {
        let (session, _) = makeSession()
        var tasks: [String] = []
        session.onTask = { task, _, _ in tasks.append(task) }
        tap(session, at: 0)
        composer.model.toggleAgentMode()
        composer.model.toggleAgentMode()
        composer.model.text = "what's this chart"

        session.send()
        await until { !client.bodies.isEmpty }

        #expect(tasks.isEmpty)
        #expect(client.bodies.count == 1)
    }

    @Test("opened for the agent (⌘ on its window), the box starts in agent mode")
    func openForAgent() {
        let (session, _) = makeSession()

        session.openForTyping(agentMode: true)

        #expect(composer.isVisible)
        #expect(composer.model.agentMode)
        #expect(composer.model.mode == .typing)
    }

    @Test("Instant goes along with an agent send, and only in agent mode")
    func instantRidesAlong() async {
        let (session, _) = makeSession()
        var sent: [(String, Bool)] = []
        session.onTask = { task, _, instant in sent.append((task, instant)) }
        tap(session, at: 0)
        composer.model.toggleAgentMode()
        #expect(composer.model.toggleInstant())
        composer.model.text = "make the save button blue"
        session.send()

        tap(session, at: 10)
        composer.model.text = "what's on screen"
        session.send()
        await until { !client.bodies.isEmpty }

        #expect(sent.count == 1)
        #expect(sent.first?.0 == "make the save button blue")
        #expect(sent.first?.1 == true)
        #expect(client.bodies.count == 1)
    }

    @Test("Esc closes the window as cancelled")
    func cancelOutcome() {
        let (session, _) = makeSession()
        tap(session, at: 0)

        session.cancel()

        #expect(composer.outcomes == [.cancelled])
    }
}
