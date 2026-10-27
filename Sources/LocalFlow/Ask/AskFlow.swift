import Foundation

/// Where an Ask is. The window is open in every phase except `closed` and
/// `pressed(composerOpen: false)`.
enum AskPhase: Equatable {
    case closed
    /// Key down; the mic is on but nothing new is shown yet, because the press may still
    /// turn out to be an Option shortcut (Option+arrow, Option+letter).
    case pressed(composerOpen: Bool)
    /// Talking while the key is held.
    case holding(composerWasOpen: Bool)
    /// Talking hands-free after a tap; `since` is when that tap ended.
    case listening(since: TimeInterval)
    /// Mic off, the last words are being written down. Sends once they land if asked to.
    case finishing(thenSend: Bool)
    /// Mic off; the text box is the user's.
    case typing

    var isMicOn: Bool {
        switch self {
        case .pressed(let open): return !open
        case .holding, .listening: return true
        case .closed, .finishing, .typing: return false
        }
    }

    var isOpen: Bool {
        switch self {
        case .closed, .pressed(composerOpen: false): return false
        default: return true
        }
    }
}

enum AskEvent: Equatable {
    case keyDown(at: TimeInterval)
    case keyUp(held: TimeInterval, at: TimeInterval)
    /// The key has been down long enough to be a hold.
    case holdReached
    /// Another key went down while ours was held: it was a shortcut.
    case otherKey
    /// The 5-minute recording limit stopped the mic.
    case micStopped
    case micLost
    case transcribed(hasText: Bool)
    /// Return or the send button.
    case send
    /// Esc.
    case cancel
}

enum AskEffect: Equatable {
    case startMic
    case discardMic
    /// Mic off; write the words down, then report `.transcribed`.
    case finishMic
    /// The window appears listening (with the outline and the model loading).
    case open
    case showVoice
    case showTyping
    case chime
    /// Chime once the double-tap window passes, unless a second tap switched to typing.
    case chimeUnlessDoubleTap
    /// The press was used up on key-down; its release must not count as a tap.
    case swallowPress
    case submit
    case close
}

/// The Ask key's gestures: tap = talk, double-tap = type, hold = talk while held.
/// Nothing is sent until Return or the send button. Pure, so every sequence is testable.
enum AskFlow {
    static func reduce(_ phase: AskPhase, _ event: AskEvent) -> (AskPhase, [AskEffect]) {
        if event == .cancel {
            guard phase != .closed else { return (phase, []) }
            return (.closed, phase.isMicOn ? [.discardMic, .close] : [.close])
        }
        switch phase {
        case .closed:
            if case .keyDown = event { return (.pressed(composerOpen: false), [.startMic]) }
        case .pressed(let open):
            return pressed(open: open, event) ?? (phase, [])
        case .holding(let wasOpen):
            switch event {
            case .keyUp, .micStopped: return (.finishing(thenSend: false), [.finishMic])
            case .send: return (.finishing(thenSend: true), [.finishMic])
            case .micLost: return (.typing, [.discardMic, .showTyping])
            case .otherKey:
                // A shortcut held a little long (Option, pause, arrow): undo what it opened.
                return wasOpen ? (.typing, [.discardMic, .swallowPress, .showTyping])
                               : (.closed, [.discardMic, .swallowPress, .close])
            default: break
            }
        case .listening(let since):
            return listening(since: since, event) ?? (phase, [])
        case .finishing(let thenSend):
            switch event {
            case .send: return (.finishing(thenSend: true), [])
            case .transcribed(let hasText):
                return thenSend && hasText ? (.closed, [.submit]) : (.typing, [.showTyping])
            default: break
            }
        case .typing:
            switch event {
            // No mic yet: Right Option+E for é must not flicker it on.
            case .keyDown: return (.pressed(composerOpen: true), [])
            case .send: return (.closed, [.submit])
            default: break
            }
        }
        return (phase, [])
    }

    /// From the closed window the mic started on key-down, so no speech is lost; from
    /// the typing box it starts once the press is clearly a tap or a hold.
    private static func pressed(open: Bool, _ event: AskEvent) -> (AskPhase, [AskEffect])? {
        let voiceOn: [AskEffect] = open ? [.startMic, .showVoice] : [.open]
        switch event {
        case .holdReached:
            return (.holding(composerWasOpen: open), voiceOn + [.chime])
        case .keyUp(let held, let at):
            // A release past the threshold is a hold whose timer lost the race.
            if held >= HotkeyMonitor.tapThreshold { return (.finishing(thenSend: false), voiceOn + [.finishMic]) }
            return (.listening(since: at), voiceOn + [.chimeUnlessDoubleTap])
        case .otherKey, .micLost:
            return open ? (.typing, [.swallowPress]) : (.closed, [.discardMic, .swallowPress])
        default:
            return nil
        }
    }

    private static func listening(since: TimeInterval, _ event: AskEvent) -> (AskPhase, [AskEffect])? {
        switch event {
        case .keyDown(let at):
            // A second tap right after the first: the user wants to type, not talk.
            if at - since < HotkeyMonitor.doubleTapWindow { return (.typing, [.discardMic, .swallowPress, .showTyping]) }
            return (.finishing(thenSend: false), [.swallowPress, .finishMic])
        case .micStopped:
            return (.finishing(thenSend: false), [.finishMic])
        case .send:
            return (.finishing(thenSend: true), [.finishMic])
        case .micLost:
            return (.typing, [.discardMic, .showTyping])
        default:
            return nil
        }
    }
}

/// Whether an answer is up, and in which form.
enum AnswerPresence: Equatable {
    case none
    /// The full bubble.
    case open
    /// Minimized to the corner chip.
    case tucked
}

/// What Esc does to Ask: plain Esc tucks the answer away and brings it back, Shift+Esc
/// closes it. Esc also reaches whatever app is in front (Claude Code's interrupt, for
/// one), so plain Esc never throws an answer away; an Esc meant for that app does
/// toggle the answer, though, bringing a tucked one back.
enum AskEscape: Equatable {
    case cancelWindow
    case close
    case minimize
    case expand

    static func action(shift: Bool, windowOpen: Bool, answer: AnswerPresence) -> AskEscape? {
        if windowOpen { return .cancelWindow }
        switch answer {
        case .open: return shift ? .close : .minimize
        case .tucked: return shift ? .close : .expand
        case .none: return nil
        }
    }
}

enum AskLimits {
    /// Longest question sent to the model; a bigger paste is cut here.
    static let maxQuestionLength = 4_000
    /// Total characters of earlier questions and answers sent along (about 3,000 tokens),
    /// so the history plus the screenshot always fit the model's 8K context.
    static let historyBudget = 12_000
}

enum AskText {
    /// Spoken words go after whatever was typed, separated by one space.
    static func join(_ typed: String, _ spoken: String) -> String {
        let typed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let spoken = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        if typed.isEmpty { return spoken }
        if spoken.isEmpty { return typed }
        return typed + " " + spoken
    }
}
