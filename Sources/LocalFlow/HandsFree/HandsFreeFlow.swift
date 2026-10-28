import Foundation

/// Where the hands-free window is. Double-tap opens it listening; a tap pauses into an
/// editable box; a tap there talks again; Return pastes.
enum HandsFreePhase: Equatable {
    case closed
    /// Talking: the words appear as they're heard. `held`: the key that turned the mic
    /// back on from the edit box is still down, so letting go after a hold pauses again.
    case listening(held: Bool)
    /// Key down in the edit box. The mic waits until it's clearly a tap or a hold,
    /// because Fn + Delete and Fn + arrows are editing keys.
    case pressed
    /// Mic off, the last words are being written down. `then`: what happens once they land.
    case finishing(then: AfterWords)
    /// Mic off; the box is the user's to edit.
    case editing

    var isMicOn: Bool {
        if case .listening = self { return true }
        return false
    }

    var isOpen: Bool { self != .closed }
}

/// What a pause does once its words are written down.
enum AfterWords: Equatable {
    case edit
    /// The key was tapped again meanwhile: keep talking.
    case talk
    /// Return was pressed meanwhile.
    case paste
}

enum HandsFreeEvent: Equatable {
    /// Double-tap: the mic is already recording.
    case open
    case keyDown
    case keyUp(held: TimeInterval)
    /// The key has been down long enough to be a hold.
    case holdReached
    /// Another key went down while ours was held: it was a shortcut (Fn + Delete).
    case otherKey
    /// Return or the paste button.
    case paste
    /// The 5-minute recording limit stopped the mic.
    case micStopped
    case micLost
    /// The words are written down; `hasText`: the box isn't empty.
    case transcribed(hasText: Bool)
    /// Esc.
    case cancel
}

enum HandsFreeEffect: Equatable {
    /// The window appears listening.
    case show
    case startMic
    case discardMic
    /// Mic off; write the words down, then report `.transcribed`.
    case finishMic
    case showVoice
    case showEditing
    case chime
    /// The press was used up on key-down; its release must not count as a tap.
    case swallowPress
    case paste
    case close
}

/// The hands-free window's gestures. Nothing is pasted until Return or the paste
/// button. Pure, so every sequence is testable.
enum HandsFreeFlow {
    static func reduce(_ phase: HandsFreePhase, _ event: HandsFreeEvent) -> (HandsFreePhase, [HandsFreeEffect]) {
        if event == .cancel {
            guard phase.isOpen else { return (phase, []) }
            return (.closed, (phase.isMicOn ? [.discardMic] : []) + closing(phase, .close))
        }
        switch phase {
        case .closed:
            if event == .open { return (.listening(held: false), [.show]) }
        case .listening(let held):
            return listening(held: held, event) ?? (phase, [])
        case .pressed:
            return pressed(event) ?? (phase, [])
        case .finishing(let then):
            return finishing(then: then, event) ?? (phase, [])
        case .editing:
            switch event {
            case .keyDown: return (.pressed, [])
            case .paste: return (.closed, [.paste])
            default: break
            }
        }
        return (phase, [])
    }

    private static func listening(held: Bool, _ event: HandsFreeEvent) -> (HandsFreePhase, [HandsFreeEffect])? {
        switch event {
        case .keyDown where !held:
            return (.finishing(then: .edit), [.swallowPress, .finishMic])
        case .keyUp(let duration) where held:
            if duration >= HotkeyMonitor.tapThreshold { return (.finishing(then: .edit), [.finishMic]) }
            return (.listening(held: false), [])
        case .otherKey where held:
            // A shortcut held a little long (Fn, pause, arrow): undo the mic it started.
            return (.editing, [.discardMic, .swallowPress, .showEditing])
        case .paste:
            return (.finishing(then: .paste), (held ? [.swallowPress] : []) + [.finishMic])
        case .micStopped, .micLost:
            // Whatever was heard still gets written down.
            return (.finishing(then: .edit), [.finishMic])
        default:
            return nil
        }
    }

    private static func pressed(_ event: HandsFreeEvent) -> (HandsFreePhase, [HandsFreeEffect])? {
        let voiceOn: [HandsFreeEffect] = [.startMic, .showVoice, .chime]
        switch event {
        case .holdReached:
            return (.listening(held: true), voiceOn)
        case .keyUp(let duration):
            // A release past the threshold is a hold whose timer lost the race: nothing
            // was recorded, so it's back to editing.
            if duration >= HotkeyMonitor.tapThreshold { return (.editing, []) }
            return (.listening(held: false), voiceOn)
        case .otherKey:
            return (.editing, [.swallowPress])
        case .paste:
            return (.closed, closing(.pressed, .paste))
        default:
            return nil
        }
    }

    private static func finishing(then: AfterWords, _ event: HandsFreeEvent) -> (HandsFreePhase, [HandsFreeEffect])? {
        switch event {
        case .paste:
            return (.finishing(then: .paste), [])
        case .keyDown where then != .paste:
            // A tap while the words are written down: keep talking once they land (a
            // second tap takes that back). Used up now, so its release is no tap.
            return (.finishing(then: then == .talk ? .edit : .talk), [.swallowPress])
        case .transcribed(let hasText):
            switch then {
            case .paste where hasText: return (.closed, [.paste])
            case .talk: return (.listening(held: false), [.startMic, .showVoice, .chime])
            default: return (.editing, [.showEditing])
            }
        default:
            return nil
        }
    }

    /// The key is down as the window closes: its release must not count as a tap, or a
    /// quick tap after it would read as a double-tap and open the window again.
    private static func closing(_ phase: HandsFreePhase, _ effect: HandsFreeEffect) -> [HandsFreeEffect] {
        phase == .pressed || phase == .listening(held: true) ? [.swallowPress, effect] : [effect]
    }
}

enum DictationText {
    /// New words go after the edited text: one space between them, none after a line
    /// break or a space the user typed.
    static func join(_ typed: String, _ spoken: String) -> String {
        let spoken = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        if spoken.isEmpty { return typed }
        guard let last = typed.last else { return spoken }
        return last.isWhitespace ? typed + spoken : typed + " " + spoken
    }
}
