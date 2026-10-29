import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import LocalFlow

/// Stands in for the agent's window as the place Ask writes when there's an agent conversation.
@MainActor
final class FakeAgentInputHost: AgentInputHost {
    var hasConversation = false
    var isInCorner = true
    var onInputSend: (() -> Void)?
    var onInputCancel: (() -> Void)?
    private(set) var shown: [(inPlace: Bool, agentMode: Bool)] = []
    private(set) var hidden: [ComposerOutcome] = []
    private(set) var isShowingInput = false

    func showInput(_ model: ComposerModel, on screen: NSScreen?, inPlace: Bool) {
        shown.append((inPlace, model.agentMode))
        isShowingInput = true
    }

    func hideInput(after outcome: ComposerOutcome) {
        guard isShowingInput else { return }
        hidden.append(outcome)
        isShowingInput = false
    }
}

/// `CommandTap.flagsChanged` is mutating, which `#expect` can't call directly.
private func ends(_ tap: inout CommandTap, _ keyCode: UInt16, _ flags: NSEvent.ModifierFlags,
                  at time: TimeInterval) -> Bool {
    tap.flagsChanged(keyCode: keyCode, flags: flags, at: time)
}

@MainActor
@Suite("Ask and agent: one window, ⌘ for agent mode, ⌘I for Instant")
struct AskModeTests {
    private let command = UInt16(kVK_Command)
    private let rightCommand = UInt16(kVK_RightCommand)

    // MARK: ⌘ on its own

    @Test("⌘ pressed and let go quickly, with nothing else, is a tap")
    func commandTap() {
        var tap = CommandTap(keys: [command])
        #expect(!ends(&tap, command, .command, at: 0))
        #expect(ends(&tap, command, [], at: 0.15))
    }

    @Test("⌘ held a while, or used for a shortcut, isn't a tap")
    func notATap() {
        var held = CommandTap(keys: [command])
        _ = held.flagsChanged(keyCode: command, flags: .command, at: 0)
        #expect(!ends(&held, command, [], at: 0.6))

        var shortcut = CommandTap(keys: [command])
        _ = shortcut.flagsChanged(keyCode: command, flags: .command, at: 0)
        shortcut.interrupted() // ⌘C
        #expect(!ends(&shortcut, command, [], at: 0.1))

        var shifted = CommandTap(keys: [command])
        _ = shifted.flagsChanged(keyCode: command, flags: .command, at: 0)
        _ = shifted.flagsChanged(keyCode: UInt16(kVK_Shift), flags: [.command, .shift], at: 0.05)
        #expect(!ends(&shifted, command, [], at: 0.1))
    }

    @Test("⌘ alone is ⌘ alone with Caps Lock on too")
    func capsLock() {
        #expect(CommandTap.isCommandOnly([.command]))
        #expect(CommandTap.isCommandOnly([.command, .capsLock]))
        #expect(!CommandTap.isCommandOnly([.command, .shift]))
        #expect(!CommandTap.isCommandOnly([]))
        var tap = CommandTap(keys: [command])
        _ = ends(&tap, command, [.command, .capsLock], at: 0)
        #expect(ends(&tap, command, [.capsLock], at: 0.1))
    }

    @Test("a ⌘ that's the Ask or dictation key never toggles agent mode")
    func keysLeaveTheAskKey() {
        #expect(CommandTap.keys(askKey: .rightOption, dictationKey: .fnKey) == [command, rightCommand])
        #expect(CommandTap.keys(askKey: .rightCommand, dictationKey: .fnKey) == [command])
        #expect(CommandTap.keys(askKey: nil, dictationKey: .rightCommand) == [command])
        var tap = CommandTap(keys: [command])
        _ = tap.flagsChanged(keyCode: rightCommand, flags: .command, at: 0)
        #expect(!ends(&tap, rightCommand, [], at: 0.1))
    }

    // MARK: The box's modes

    @Test("⌘ toggles agent mode; ⌘I toggles Instant only in agent mode")
    func toggles() {
        let model = ComposerModel()
        #expect(!model.toggleInstant())
        #expect(!model.instant)
        model.toggleAgentMode()
        #expect(model.agentMode)
        #expect(model.toggleInstant())
        #expect(model.sendsInstant)
        model.toggleAgentMode()
        #expect(!model.sendsInstant)
    }

    @Test("a fresh box is in Ask mode unless opened for the agent; Instant stays as it was")
    func resets() {
        let model = ComposerModel()
        model.toggleAgentMode()
        _ = model.toggleInstant()
        model.reset(mode: .typing)
        #expect(!model.agentMode)
        #expect(model.instant)
        model.reset(mode: .typing, agentMode: true)
        #expect(model.agentMode)
        #expect(model.sendsInstant)
    }

    // MARK: One window

    private func windows() -> (AskWindows, FakeComposer, FakeAgentInputHost) {
        let ask = FakeComposer()
        let agent = FakeAgentInputHost()
        return (AskWindows(ask: ask, agent: agent), ask, agent)
    }

    @Test("with no agent conversation, Ask writes in its own window")
    func askWindow() {
        let (router, ask, agent) = windows()

        router.show(on: nil)
        router.finish(.asked)

        #expect(ask.shows == 1)
        #expect(ask.outcomes == [.asked])
        #expect(agent.shown.isEmpty)
    }

    @Test("with an agent conversation, the box goes in the agent's window at home, and the Ask window stays shut")
    func agentWindowAtHome() {
        let (router, ask, agent) = windows()
        agent.hasConversation = true

        router.show(on: nil)

        #expect(ask.shows == 0)
        #expect(agent.shown.count == 1)
        #expect(agent.shown.first?.inPlace == false)
        router.finish(.handedToAgent)
        #expect(agent.hidden == [.handedToAgent])
        #expect(ask.outcomes.isEmpty)
    }

    @Test("opened for the agent while its window is in the corner, the box opens right there")
    func agentWindowInPlace() {
        let (router, _, agent) = windows()
        agent.hasConversation = true
        router.model.reset(mode: .typing, agentMode: true)

        router.show(on: nil)

        #expect(agent.shown.first?.inPlace == true)
    }

    @Test("Return and Esc in the agent's window reach Ask")
    func keysReachAsk() {
        let (router, _, agent) = windows()
        var sends = 0
        var cancels = 0
        router.onSend = { sends += 1 }
        router.onCancel = { cancels += 1 }

        agent.onInputSend?()
        agent.onInputCancel?()

        #expect(sends == 1)
        #expect(cancels == 1)
    }

    @Test("hiding closes whichever window has the box, as cancelled")
    func hideCancels() {
        let (router, _, agent) = windows()
        agent.hasConversation = true
        router.show(on: nil)

        router.hide()

        #expect(agent.hidden == [.cancelled])
    }

    @Test("the voice level reaches the agent's window's box too")
    func level() {
        let (router, _, agent) = windows()
        agent.hasConversation = true
        router.show(on: nil)

        router.updateLevel(1)

        #expect(router.model.level > 0)
    }

    // MARK: Where the agent's window goes after the box

    @Test("after the box: to the agent, the corner; a question, tucked away unless it's busy; Esc, back as it was")
    func afterTheBox() {
        typealias Exit = AgentInputExit
        #expect(Exit.after(.handedToAgent, wasTucked: true, isWorking: false, isWaiting: false) == .corner)
        #expect(Exit.after(.asked, wasTucked: false, isWorking: false, isWaiting: false) == .tuck)
        #expect(Exit.after(.asked, wasTucked: false, isWorking: true, isWaiting: false) == .corner)
        #expect(Exit.after(.asked, wasTucked: false, isWorking: false, isWaiting: true) == .corner)
        #expect(Exit.after(.cancelled, wasTucked: false, isWorking: false, isWaiting: false) == .corner)
        #expect(Exit.after(.cancelled, wasTucked: true, isWorking: false, isWaiting: false) == .tuck)
        #expect(Exit.after(.cancelled, wasTucked: true, isWorking: true, isWaiting: false) == .corner)
    }

    @Test("home is where the Ask window sits: centered at the bottom of the screen")
    func home() {
        let visible = NSRect(x: 0, y: 25, width: 1440, height: 875)
        let frame = AgentPlacement.home(size: NSSize(width: 460, height: 300), in: visible)
        #expect(frame == NSRect(x: 490, y: 53, width: 460, height: 300))
    }
}
