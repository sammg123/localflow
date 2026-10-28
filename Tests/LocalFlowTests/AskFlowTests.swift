import Foundation
import Testing
@testable import LocalFlow

/// Every Right Option gesture, as pure state transitions: tap = type, tap again = talk,
/// hold = talk while held, and nothing is ever sent without Return or the send button.
@Suite("Ask: Right Option gestures")
struct AskFlowTests {
    private let t0: TimeInterval = 100

    private func run(_ events: [AskEvent], from phase: AskPhase = .closed) -> (phase: AskPhase, effects: [AskEffect]) {
        events.reduce((phase, [AskEffect]())) { result, event in
            let (next, effects) = AskFlow.reduce(result.0, event)
            return (next, result.1 + effects)
        }
    }

    private func tap(at time: TimeInterval) -> [AskEvent] { [.keyDown(at: time), .keyUp(held: 0.1, at: time + 0.1)] }
    private var tap: [AskEvent] { tap(at: t0) }

    @Test("a tap opens the window for typing: mic off, nothing sent")
    func tapTypes() {
        let result = run(tap)

        #expect(result.phase == .typing)
        #expect(result.effects == [.openTyping])
    }

    @Test("the key going down from closed starts nothing: it may be an Option shortcut")
    func pressStartsNothing() {
        let result = run([.keyDown(at: t0)])

        #expect(result.phase == .pressed(composerOpen: false))
        #expect(result.effects.isEmpty)
    }

    @Test("tapping again turns the voice on, however soon after the first tap", arguments: [0.25, 2.0])
    func secondTapTalks(gap: TimeInterval) {
        let result = run(tap + tap(at: t0 + gap))

        #expect(result.phase == .listening)
        #expect(result.effects.suffix(3) == [.startMic, .showVoice, .chime])
    }

    @Test("picking a chat back up opens the window for typing, mic off; ignored while it's open")
    func openTyping() {
        let result = run([.openTyping])

        #expect(result.phase == .typing)
        #expect(result.effects == [.openTyping])
        #expect(run([.openTyping], from: .typing).effects.isEmpty)
        #expect(run([.openTyping], from: .listening).effects.isEmpty)
    }

    @Test("while typing, the mic waits until the press is clearly a tap or a hold")
    func typingPressStartsNoMic() {
        let pressed = run([.keyDown(at: t0)], from: .typing)
        let held = run([.holdReached], from: pressed.phase)

        #expect(pressed.phase == .pressed(composerOpen: true))
        #expect(pressed.effects.isEmpty)
        #expect(held.phase == .holding(composerWasOpen: true))
        #expect(held.effects == [.startMic, .showVoice, .chime])
    }

    @Test("a tap while talking stops, however soon, and the question waits for send", arguments: [0.1, 3.0])
    func tapStops(after: TimeInterval) {
        let stopped = run([.keyDown(at: t0 + after)], from: .listening)
        let ready = run([.transcribed(hasText: true)], from: stopped.phase)

        #expect(stopped.phase == .finishing(thenSend: false))
        #expect(stopped.effects.suffix(2) == [.swallowPress, .finishMic])
        #expect(ready.phase == .typing)
        #expect(ready.effects == [.showTyping])
    }

    @Test("holding talks only while held, then the question waits for send")
    func holdTalks() {
        let released = run([.keyDown(at: t0), .holdReached, .keyUp(held: 1.5, at: t0 + 1.5)])
        let ready = run([.transcribed(hasText: true)], from: released.phase)

        #expect(released.phase == .finishing(thenSend: false))
        #expect(released.effects == [.startMic, .open, .chime, .finishMic])
        #expect(ready.phase == .typing)
        #expect(!ready.effects.contains(.submit))
    }

    @Test("a slow tap that beats the hold timer counts as a tap: the mic never ran")
    func slowTap() {
        let closed = run([.keyDown(at: t0), .keyUp(held: 0.5, at: t0 + 0.5)])
        let typing = run([.keyDown(at: t0), .keyUp(held: 0.5, at: t0 + 0.5)], from: .typing)

        #expect(closed.phase == .typing)
        #expect(closed.effects == [.openTyping])
        #expect(typing.phase == .listening)
        #expect(typing.effects == [.startMic, .showVoice, .chime])
    }

    @Test("Return sends what's typed")
    func returnSendsTyping() {
        let result = run([.send], from: .typing)

        #expect(result.phase == .closed)
        #expect(result.effects == [.submit])
    }

    @Test("Return while talking finishes the words, then sends them")
    func returnWhileTalking() {
        let finishing = run(tap + tap(at: t0 + 2) + [.send])
        let sent = run([.transcribed(hasText: true)], from: finishing.phase)

        #expect(finishing.phase == .finishing(thenSend: true))
        #expect(finishing.effects.last == .finishMic)
        #expect(sent.phase == .closed)
        #expect(sent.effects == [.submit])
    }

    @Test("Return while the words are still being written down sends once they land")
    func returnWhileFinishing() {
        let result = run([.send, .transcribed(hasText: true)], from: .finishing(thenSend: false))

        #expect(result.phase == .closed)
        #expect(result.effects == [.submit])
    }

    @Test("Return with nothing heard keeps the window open for typing")
    func returnWithNothing() {
        let result = run([.transcribed(hasText: false)], from: .finishing(thenSend: true))

        #expect(result.phase == .typing)
        #expect(result.effects == [.showTyping])
    }

    @Test("Option shortcuts never open the window")
    func optionShortcut() {
        let result = run([.keyDown(at: t0), .otherKey])

        #expect(result.phase == .closed)
        #expect(result.effects == [.swallowPress])
    }

    @Test("Option+letter while typing stays in the box and never touches the mic")
    func optionLetterWhileTyping() {
        let result = run([.keyDown(at: t0), .otherKey], from: .typing)

        #expect(result.phase == .typing)
        #expect(result.effects == [.swallowPress])
    }

    @Test("an Option shortcut held past the hold time still closes what it opened")
    func lateOptionShortcut() {
        let result = run([.keyDown(at: t0), .holdReached, .otherKey])

        #expect(result.phase == .closed)
        #expect(result.effects.suffix(3) == [.discardMic, .swallowPress, .close])
    }

    @Test("a late Option+letter while typing goes back to typing")
    func lateOptionLetterWhileTyping() {
        let result = run([.keyDown(at: t0), .holdReached, .otherKey], from: .typing)

        #expect(result.phase == .typing)
        #expect(result.effects.suffix(3) == [.discardMic, .swallowPress, .showTyping])
    }

    @Test("Esc closes from anywhere, dropping the mic if it was on", arguments: [
        (AskPhase.pressed(composerOpen: false), false),
        (.pressed(composerOpen: true), false),
        (.holding(composerWasOpen: false), true),
        (.listening, true),
        (.finishing(thenSend: false), false),
        (.typing, false),
    ])
    func escCloses(phase: AskPhase, micOn: Bool) {
        let result = run([.cancel], from: phase)

        #expect(result.phase == .closed)
        #expect(result.effects == (micOn ? [.discardMic, .close] : [.close]))
    }

    @Test("stray events change nothing", arguments: [
        (AskPhase.closed, AskEvent.send),
        (.closed, .cancel),
        (.closed, .keyUp(held: 0.1, at: 100)),
        (.closed, .holdReached),
        (.closed, .transcribed(hasText: true)),
        (.typing, .keyUp(held: 0.1, at: 100)),
        (.typing, .holdReached),
        (.finishing(thenSend: false), .keyDown(at: 100)),
        (.finishing(thenSend: false), .keyUp(held: 0.1, at: 100)),
    ])
    func strayEvents(phase: AskPhase, event: AskEvent) {
        let result = run([event], from: phase)

        #expect(result.phase == phase)
        #expect(result.effects.isEmpty)
    }

    @Test("the 5-minute limit finishes the words like a release", arguments: [
        AskPhase.holding(composerWasOpen: false), .listening,
    ])
    func limitFinishes(phase: AskPhase) {
        let result = run([.micStopped], from: phase)

        #expect(result.phase == .finishing(thenSend: false))
        #expect(result.effects == [.finishMic])
    }

    @Test("Esc tucks the answer away and brings it back; Shift+Esc closes it", arguments: [
        (false, true, AnswerPresence.none, AskEscape.cancelWindow),
        (true, true, .none, .cancelWindow),
        (false, false, .open, .minimize),
        (false, false, .tucked, .expand),
        (true, false, .open, .close),
        (true, false, .tucked, .close),
        (false, false, .none, nil),
        (true, false, .none, nil),
    ] as [(Bool, Bool, AnswerPresence, AskEscape?)])
    func escape(shift: Bool, windowOpen: Bool, answer: AnswerPresence, expected: AskEscape?) {
        #expect(AskEscape.action(shift: shift, windowOpen: windowOpen, answer: answer) == expected)
    }

    @Test("plain Esc never throws an answer away, so Esc meant for another app costs nothing")
    func plainEscapeKeepsTheAnswer() {
        let actions = [AnswerPresence.open, .tucked].map { AskEscape.action(shift: false, windowOpen: false, answer: $0) }

        #expect(!actions.contains(.close))
    }

    @Test("losing the mic keeps what was typed")
    func micLost() {
        let result = run([.micLost], from: .listening)

        #expect(result.phase == .typing)
        #expect(result.effects == [.discardMic, .showTyping])
    }
}
