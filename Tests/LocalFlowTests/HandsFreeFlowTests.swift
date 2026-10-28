import Testing
@testable import LocalFlow

@Suite("Hands-free window gestures")
struct HandsFreeFlowTests {
    private func run(_ events: [HandsFreeEvent], from phase: HandsFreePhase = .closed) -> (phase: HandsFreePhase, effects: [HandsFreeEffect]) {
        var phase = phase
        var effects: [HandsFreeEffect] = []
        for event in events {
            let (next, more) = HandsFreeFlow.reduce(phase, event)
            phase = next
            effects += more
        }
        return (phase, effects)
    }

    @Test("double-tap opens the window already listening")
    func openListens() {
        let result = run([.open])
        #expect(result.phase == .listening(held: false))
        #expect(result.effects == [.show])
    }

    @Test("a tap while listening pauses: the words are written down and the box opens for editing")
    func tapPauses() {
        let paused = run([.keyDown], from: .listening(held: false))
        #expect(paused.phase == .finishing(then: .edit))
        #expect(paused.effects == [.swallowPress, .finishMic])

        let editing = run([.transcribed(hasText: true)], from: paused.phase)
        #expect(editing.phase == .editing)
        #expect(editing.effects == [.showEditing])
    }

    @Test("a tap in the edit box starts talking again, hands-free")
    func tapResumes() {
        let pressed = run([.keyDown], from: .editing)
        #expect(pressed.phase == .pressed)
        #expect(pressed.effects.isEmpty) // no mic until it's clearly not Fn+Delete

        let resumed = run([.keyUp(held: 0.1)], from: .pressed)
        #expect(resumed.phase == .listening(held: false))
        #expect(resumed.effects == [.startMic, .showVoice, .chime])
    }

    @Test("holding the key in the edit box talks while held, then goes back to editing")
    func holdTalks() {
        let holding = run([.keyDown, .holdReached], from: .editing)
        #expect(holding.phase == .listening(held: true))
        #expect(holding.effects == [.startMic, .showVoice, .chime])

        let released = run([.keyUp(held: 1.2)], from: holding.phase)
        #expect(released.phase == .finishing(then: .edit))
        #expect(released.effects == [.finishMic])
    }

    @Test("a quick tap after the hold timer fired keeps listening hands-free")
    func tapAfterHoldTimer() {
        let result = run([.keyUp(held: 0.2)], from: .listening(held: true))
        #expect(result.phase == .listening(held: false))
        #expect(result.effects.isEmpty)
    }

    @Test("Fn + Delete or Fn + arrow in the edit box is editing, not talking")
    func fnShortcutStaysEditing() {
        let result = run([.keyDown, .otherKey], from: .editing)
        #expect(result.phase == .editing)
        #expect(result.effects == [.swallowPress])
    }

    @Test("a long Fn + arrow after the hold timer fired drops the mic and stays editing")
    func longFnShortcut() {
        let result = run([.otherKey], from: .listening(held: true))
        #expect(result.phase == .editing)
        #expect(result.effects == [.discardMic, .swallowPress, .showEditing])
    }

    @Test("Return while listening writes the last words down, then pastes")
    func returnWhileListening() {
        let finishing = run([.paste], from: .listening(held: false))
        #expect(finishing.phase == .finishing(then: .paste))
        #expect(finishing.effects == [.finishMic])

        let pasted = run([.transcribed(hasText: true)], from: finishing.phase)
        #expect(pasted.phase == .closed)
        #expect(pasted.effects == [.paste])
    }

    @Test("Return while the words are still being written down pastes once they land")
    func returnWhileFinishing() {
        let result = run([.paste, .transcribed(hasText: true)], from: .finishing(then: .edit))
        #expect(result.phase == .closed)
        #expect(result.effects == [.paste])
    }

    @Test("Return with nothing heard and nothing typed leaves the box open")
    func returnWithNothing() {
        let result = run([.transcribed(hasText: false)], from: .finishing(then: .paste))
        #expect(result.phase == .editing)
        #expect(result.effects == [.showEditing])
    }

    @Test("Return in the edit box pastes")
    func returnWhileEditing() {
        let result = run([.paste], from: .editing)
        #expect(result.phase == .closed)
        #expect(result.effects == [.paste])
    }

    @Test("Esc throws everything away, and drops the mic only when it's on")
    func cancel() {
        #expect(run([.cancel], from: .listening(held: false)).effects == [.discardMic, .close])
        #expect(run([.cancel], from: .editing).effects == [.close])
        #expect(run([.cancel], from: .finishing(then: .paste)).effects == [.close])
        #expect(run([.cancel], from: .editing).phase == .closed)
        #expect(run([.cancel], from: .closed).effects.isEmpty)
    }

    @Test("the 5-minute limit pauses instead of pasting")
    func limitPauses() {
        let result = run([.micStopped], from: .listening(held: false))
        #expect(result.phase == .finishing(then: .edit))
        #expect(result.effects == [.finishMic])
    }

    @Test("losing the mic still writes down what it heard")
    func micLost() {
        let result = run([.micLost], from: .listening(held: false))
        #expect(result.phase == .finishing(then: .edit))
        #expect(result.effects == [.finishMic])
    }

    @Test("a tap while the words are being written down keeps talking once they land")
    func tapWhileFinishing() {
        let queued = run([.keyDown, .keyUp(held: 0.1)], from: .finishing(then: .edit))
        #expect(queued.phase == .finishing(then: .talk))
        #expect(queued.effects == [.swallowPress])

        let talking = run([.transcribed(hasText: true)], from: queued.phase)
        #expect(talking.phase == .listening(held: false))
        #expect(talking.effects == [.startMic, .showVoice, .chime])
    }

    @Test("a second tap while the words are written down takes the first one back")
    func doubleTapWhileFinishing() {
        let result = run([.keyDown, .keyDown, .transcribed(hasText: true)], from: .finishing(then: .edit))
        #expect(result.phase == .editing)
    }

    @Test("Return beats a queued tap; a tap after Return changes nothing")
    func returnBeatsQueuedTap() {
        #expect(run([.paste], from: .finishing(then: .talk)).phase == .finishing(then: .paste))
        #expect(run([.keyDown], from: .finishing(then: .paste)).phase == .finishing(then: .paste))
    }

    @Test("closing while the key is down uses up its release")
    func closeWhileKeyDown() {
        #expect(run([.paste], from: .pressed).effects == [.swallowPress, .paste])
        #expect(run([.cancel], from: .pressed).effects == [.swallowPress, .close])
        #expect(run([.cancel], from: .listening(held: true)).effects == [.discardMic, .swallowPress, .close])
        #expect(run([.paste], from: .listening(held: true)).effects == [.swallowPress, .finishMic])
    }

    @Test("the mic is on only while listening")
    func micOn() {
        #expect(HandsFreePhase.listening(held: false).isMicOn)
        #expect(HandsFreePhase.listening(held: true).isMicOn)
        #expect(!HandsFreePhase.editing.isMicOn)
        #expect(!HandsFreePhase.pressed.isMicOn)
        #expect(!HandsFreePhase.finishing(then: .edit).isMicOn)
        #expect(!HandsFreePhase.closed.isOpen)
        #expect(HandsFreePhase.pressed.isOpen)
    }

    @Test("new words go after the edited text", arguments: [
        ("Hello there.", "And more.", "Hello there. And more."),
        ("", "Just this.", "Just this."),
        ("Typed only", "", "Typed only"),
        ("First line\n", "second line", "First line\nsecond line"),
        ("Ends with a space ", "  next ", "Ends with a space next"),
    ])
    func join(typed: String, spoken: String, expected: String) {
        #expect(DictationText.join(typed, spoken) == expected)
    }
}
