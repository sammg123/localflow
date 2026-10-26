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

    @Test("tap, talk, tap: the question waits in the window until Return")
    func tapTalkTap() async {
        let (session, _) = makeSession()

        tap(session, at: 0)
        #expect(composer.isVisible)
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

    @Test("double-tap types first: the mic's split second is thrown away, not transcribed")
    func doubleTapTypes() async {
        let (session, transcriber) = makeSession()

        tap(session, at: 0)
        session.keyDown(at: 0.25)

        #expect(composer.model.mode == .typing)
        #expect(mic.discards == 1)
        #expect(!mic.isOn)
        composer.model.text = "explain this chart"
        session.send()
        await until { surface.model.phase == .done }

        #expect(transcriber.calls == 0)
        #expect(client.bodies.last?.messages.last?.content == "explain this chart")
    }

    @Test("double-tap, type, then tap to talk: speech lands after the typed words")
    func typeThenTalk() async {
        let (session, _) = makeSession(saying: "which strategy dominates")

        tap(session, at: 0)
        session.keyDown(at: 0.25)
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
        session.holdReached()
        #expect(composer.isVisible)
        session.keyUp(held: 1.5, at: 1.5)
        await until { composer.model.mode == .typing }

        #expect(!composer.model.text.isEmpty)
        #expect(client.bodies.isEmpty)
    }

    @Test("Return while talking writes the words down and sends them")
    func returnWhileTalking() async {
        let (session, _) = makeSession()

        tap(session, at: 0)
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
        #expect(mic.discards == 1)
        #expect(session.phase == .closed)
    }

    @Test("an Option shortcut leaves an answer on screen alone")
    func shortcutKeepsAnswer() async {
        let (session, _) = makeSession()
        tap(session, at: 0)
        session.keyDown(at: 0.25)
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
        session.keyDown(at: 0.25)
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

    @Test("while a dictation has the mic, the Ask key does nothing")
    func micBusy() {
        mic.canStart = false
        let (session, _) = makeSession()

        tap(session, at: 0)

        #expect(composer.shows == 0)
        #expect(session.phase == .closed)
    }

    @Test("Return with an empty box sends nothing and keeps it open")
    func emptySend() async {
        let (session, _) = makeSession()

        tap(session, at: 0)
        session.keyDown(at: 0.25)
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
        session.keyDown(at: 0.25)
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
        session.keyDown(at: 0.25)
        composer.model.text = "first"
        session.send()
        await until { surface.model.phase == .done }

        tap(session, at: 10)

        #expect(!surface.isVisible)
        #expect(composer.isVisible)
    }
}
