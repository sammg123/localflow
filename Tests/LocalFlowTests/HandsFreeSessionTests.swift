import AppKit
import Foundation
import Testing
@testable import LocalFlow

/// Stands in for AppController's microphone in the hands-free window.
@MainActor
final class FakeHandsFreeMic: HandsFreeMicrophone {
    var canStart = true
    var audio: [Float] = Array(repeating: 0.1, count: 16_000)
    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var discards = 0
    private(set) var isOn = true // the double-tap already started it

    func startHandsFree() -> Bool {
        guard canStart else { return false }
        starts += 1
        isOn = true
        return true
    }

    func stopHandsFree() -> [Float] {
        stops += 1
        isOn = false
        return audio
    }

    func discardHandsFree() {
        discards += 1
        isOn = false
    }

    var capturedSampleCount: Int { audio.count }
    func samples(in range: Range<Int>) -> [Float] { Array(audio[range]) }
}

@MainActor
@Suite("Hands-free window, end to end with fakes")
struct HandsFreeSessionTests {
    let mic = FakeHandsFreeMic()
    let composer = FakeComposer()

    /// Each pause writes down the next of `segments`.
    private final class Script {
        var segments: [String]
        var pasted: [String] = []
        var swallows = 0
        init(_ segments: [String]) { self.segments = segments }
    }

    private func makeSession(saying segments: [String] = ["Hello there."]) -> (HandsFreeSession, Script) {
        let script = Script(segments)
        let session = HandsFreeSession(
            mic: mic,
            composer: composer,
            transcribe: { _ in "" },
            finish: { _ in script.segments.isEmpty ? "" : script.segments.removeFirst() },
            paste: { script.pasted.append($0) },
            swallowPress: { script.swallows += 1 },
            chime: {},
            holdDelay: nil,
            liveInterval: nil
        )
        return (session, script)
    }

    private func until(_ condition: () -> Bool) async {
        for _ in 0..<400 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func tap(_ session: HandsFreeSession) {
        session.keyDown()
        session.keyUp(held: 0.1)
    }

    @Test("tap pauses with the words in an editable box; nothing is pasted")
    func tapPauses() async {
        let (session, script) = makeSession()
        session.open()
        #expect(composer.isVisible)
        #expect(composer.model.mode == .voice)

        session.keyDown()
        await until { composer.model.mode == .typing }

        #expect(composer.model.text == "Hello there.")
        #expect(composer.isVisible)
        #expect(!mic.isOn)
        #expect(mic.stops == 1)
        #expect(script.swallows == 1)
        #expect(script.pasted.isEmpty)
    }

    @Test("edit, talk again, Return: the edited words and the new words paste together")
    func editTalkPaste() async {
        let (session, script) = makeSession(saying: ["Hello there.", "And more."])
        session.open()
        session.keyDown()
        await until { composer.model.mode == .typing }

        composer.model.text = "Hello there, friend."
        tap(session)
        #expect(mic.isOn)
        #expect(mic.starts == 1)
        #expect(composer.model.mode == .voice)
        #expect(composer.model.text == "Hello there, friend.")

        session.keyDown()
        await until { composer.model.mode == .typing }
        #expect(composer.model.text == "Hello there, friend. And more.")

        session.paste()
        #expect(script.pasted == ["Hello there, friend. And more."])
        #expect(!composer.isVisible)
        #expect(session.phase == .closed)
    }

    @Test("Return while still talking writes the words down and pastes them")
    func returnWhileTalking() async {
        let (session, script) = makeSession()
        session.open()

        session.paste()
        await until { !script.pasted.isEmpty }

        #expect(script.pasted == ["Hello there."])
        #expect(!composer.isVisible)
        #expect(!mic.isOn)
    }

    @Test("Return with an empty box pastes nothing and keeps the window")
    func emptyReturn() async {
        let (session, script) = makeSession(saying: [])
        session.open()
        session.keyDown()
        await until { composer.model.mode == .typing }

        session.paste()

        #expect(script.pasted.isEmpty)
        #expect(composer.isVisible)
        #expect(session.phase == .editing)
        #expect(composer.model.notice != nil)
    }

    @Test("Esc throws it all away")
    func escape() async {
        let (session, script) = makeSession()
        session.open()
        session.keyDown()
        await until { composer.model.mode == .typing }

        session.cancel()

        #expect(!composer.isVisible)
        #expect(script.pasted.isEmpty)
        #expect(session.phase == .closed)
    }

    @Test("Esc while listening drops the mic")
    func escapeWhileListening() {
        let (session, _) = makeSession()
        session.open()
        session.cancel()
        #expect(mic.discards == 1)
        #expect(!mic.isOn)
    }

    @Test("words that land after Esc are thrown away")
    func lateWordsAfterEscape() async {
        let (session, script) = makeSession()
        session.open()
        session.paste() // finishing, paste once written down
        session.cancel()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(script.pasted.isEmpty)
        #expect(!composer.isVisible)
    }

    @Test("Fn + Delete in the box never turns the mic on")
    func fnDelete() async {
        let (session, script) = makeSession()
        session.open()
        session.keyDown()
        await until { composer.model.mode == .typing }

        session.keyDown()
        session.otherKey()
        session.keyUp(held: 0.1)

        #expect(mic.starts == 0)
        #expect(session.phase == .editing)
        #expect(script.swallows == 2)
    }

    @Test("a busy mic keeps the box open for typing")
    func micBusy() async {
        let (session, _) = makeSession()
        session.open()
        session.keyDown()
        await until { composer.model.mode == .typing }

        mic.canStart = false
        tap(session)

        #expect(session.phase == .editing)
        #expect(composer.model.mode == .typing)
    }

    @Test("losing the mic keeps what was written and writes down what it heard")
    func micLost() async {
        let (session, _) = makeSession(saying: ["Hello there.", "Before it dropped."])
        session.open()
        session.keyDown()
        await until { composer.model.mode == .typing }
        tap(session)

        session.micLost()
        await until { composer.model.mode == .typing }

        #expect(session.phase == .editing)
        #expect(composer.model.text == "Hello there. Before it dropped.")
        #expect(composer.model.notice != nil)
        #expect(mic.discards == 0)
    }

    @Test("the 5-minute limit pauses with a note, keeping the words")
    func limit() async {
        let (session, script) = makeSession()
        session.open()

        session.micStopped()
        await until { composer.model.mode == .typing }

        #expect(composer.model.text == "Hello there.")
        #expect(composer.model.notice?.contains("5-minute") == true)
        #expect(script.pasted.isEmpty)
    }

    @Test("a tap while the words are being written down keeps talking after them")
    func tapWhileWritingDown() async {
        let (session, _) = makeSession()
        session.open()
        session.keyDown() // pause
        session.keyDown() // and straight back to talking

        await until { composer.model.mode == .voice }

        #expect(mic.isOn)
        #expect(mic.starts == 1)
        #expect(composer.model.text == "Hello there.")
        #expect(session.phase == .listening(held: false))
    }
}
