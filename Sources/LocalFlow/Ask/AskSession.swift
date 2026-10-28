import AppKit
import Foundation

/// The one microphone, lent to Ask by AppController, which owns it and the dictation state.
@MainActor
protocol AskMicrophone: AnyObject {
    /// False when the mic is busy (a dictation is recording) or can't start; the owner says why.
    func startAsk() -> Bool
    func stopAsk() -> [Float]
    func discardAsk()
    var capturedSampleCount: Int { get }
    func samples(in range: Range<Int>) -> [Float]
}

/// Runs the Ask window: turns Right Option presses into AskFlow events and carries out
/// the effects (mic, live words, the window, sending to AskController).
@MainActor
final class AskSession {
    typealias Transcribe = @MainActor ([Float]) async throws -> String

    private(set) var phase: AskPhase = .closed {
        didSet { if phase != oldValue { onPhaseChange?(phase) } }
    }
    var onPhaseChange: ((AskPhase) -> Void)?
    var keyName = "Right ⌥" {
        didSet { composer.model.keyName = keyName }
    }

    private weak var mic: AskMicrophone?
    private let composer: ComposerSurface
    private let answers: AskController
    private let transcribe: Transcribe
    private let canOpen: @MainActor () -> Bool
    private let chime: @MainActor () -> Void
    private let swallowPress: @MainActor () -> Void
    private let holdDelay: Duration?
    private let liveInterval: Duration?
    private let rules = RulesPolisher()
    private let settings = Settings.shared

    private var screen: NSScreen?
    /// Words written before going to Chats, put back when the window opens for typing.
    private var draft: String?
    /// Typed text the current voice turn adds to.
    private var typedBase = ""
    /// Bumped per mic start, so a late chime, live words or transcript can tell it's stale.
    private var voiceID = 0
    /// Bumped per key-down, so a late hold timer can tell it belongs to an older press.
    private var pressID = 0
    private var liveTranscriber: LiveTranscriber?

    /// Shorter clips than this are thrown away rather than transcribed into a guess.
    private static let minSpeechSamples = Int(0.3 * AudioRecorder.targetSampleRate)

    /// - Parameters:
    ///   - canOpen: checked before the window first appears (Screen Recording); explains a no.
    ///   - holdDelay: when a press becomes a hold; nil = never automatically (tests).
    ///   - liveInterval: how often words appear while talking; nil = off (tests).
    init(mic: AskMicrophone,
         composer: ComposerSurface,
         answers: AskController,
         transcribe: @escaping Transcribe,
         canOpen: @escaping @MainActor () -> Bool,
         chime: @escaping @MainActor () -> Void = { SoundPlayer.playStart() },
         swallowPress: @escaping @MainActor () -> Void,
         holdDelay: Duration? = .seconds(HotkeyMonitor.tapThreshold),
         liveInterval: Duration? = .milliseconds(600)) {
        self.mic = mic
        self.composer = composer
        self.answers = answers
        self.transcribe = transcribe
        self.canOpen = canOpen
        self.chime = chime
        self.swallowPress = swallowPress
        self.holdDelay = holdDelay
        self.liveInterval = liveInterval
        composer.onSend = { [weak self] in self?.send() }
        composer.onCancel = { [weak self] in self?.cancel() }
    }

    // MARK: - Events

    func keyDown(at time: TimeInterval) {
        // The screen being worked on. (The last answer closes only when the window opens,
        // so an Option shortcut leaves it alone.)
        if phase == .closed { screen = ScreenCapturer.screenUnderMouse() }
        pressID += 1
        handle(.keyDown(at: time))
        scheduleHoldCheck()
    }

    func keyUp(held: TimeInterval, at time: TimeInterval) { handle(.keyUp(held: held, at: time)) }
    func holdReached() { handle(.holdReached) }
    func otherKey() { handle(.otherKey) }
    func micStopped() { handle(.micStopped) }
    func micLost() { handle(.micLost) }
    func cancel() { handle(.cancel) }

    /// Closes the window, keeping what was written for the next `openForTyping` (going
    /// to Chats and back).
    func closeKeepingDraft() {
        let text = composer.model.text
        handle(.cancel)
        draft = text.isEmpty ? nil : text
    }

    /// Opens the window for typing, as a tap does; nothing happens if it's open.
    func openForTyping() {
        if phase == .closed { screen = ScreenCapturer.screenUnderMouse() }
        handle(.openTyping)
    }

    /// Return or the send button. An empty box sends nothing.
    func send() {
        if phase == .typing, composer.model.question.isEmpty {
            NSSound.beep()
            return
        }
        handle(.send)
    }

    func updateLevel(_ level: Float) {
        guard phase.isMicOn, phase.isOpen else { return }
        composer.updateLevel(level)
    }

    // MARK: - Effects

    private func handle(_ event: AskEvent) {
        let wasOpen = phase.isOpen
        let (next, effects) = AskFlow.reduce(phase, event)
        phase = next
        for effect in effects {
            guard perform(effect, windowWasOpen: wasOpen) else { return }
        }
    }

    /// Returns false when the rest of the effects must not run.
    private func perform(_ effect: AskEffect, windowWasOpen: Bool) -> Bool {
        switch effect {
        case .startMic:
            guard mic?.startAsk() == true else {
                // Busy (a dictation has it) or unavailable: an open window stays for typing,
                // and a hold from closed shows nothing.
                phase = windowWasOpen ? .typing : .closed
                return false
            }
            voiceID += 1
        case .discardMic:
            stopLiveWords()
            mic?.discardAsk()
            // Drop live words that were showing; typed text is never touched.
            if composer.model.mode == .voice { composer.model.text = typedBase }
        case .finishMic:
            finishMic()
        case .open:
            return open(mode: .voice)
        case .openTyping:
            return open(mode: .typing)
        case .showVoice:
            typedBase = composer.model.text
            composer.model.notice = nil
            composer.model.mode = .voice
            startLiveWords()
        case .showTyping:
            composer.model.mode = .typing
        case .chime:
            chime()
        case .swallowPress:
            swallowPress()
        case .submit:
            submit()
        case .close:
            stopLiveWords()
            composer.hide()
            answers.cancelPreparing()
        }
        return true
    }

    private func open(mode: ComposerMode) -> Bool {
        guard canOpen() else {
            stopLiveWords()
            mic?.discardAsk()
            phase = .closed
            return false
        }
        answers.prepare(on: screen) // closes the last answer
        typedBase = ""
        composer.model.reset(mode: mode)
        if mode == .typing, let draft { composer.model.text = draft }
        draft = nil
        composer.model.keyName = keyName
        composer.show(on: screen)
        if mode == .voice { startLiveWords() }
        return true
    }

    private func submit() {
        let question = String(composer.model.question.prefix(AskLimits.maxQuestionLength))
        composer.hide()
        answers.submit(question)
    }

    private func finishMic() {
        stopLiveWords()
        let samples = mic?.stopAsk() ?? []
        let id = voiceID
        composer.model.mode = .finishing
        guard samples.count >= Self.minSpeechSamples else {
            landTranscript("", id: id)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let raw = try await self.transcribe(samples)
                let cleaned = self.rules.apply(raw, category: .other, replacements: self.settings.replacements,
                                               spokenCommands: false, toneMatching: false)
                self.landTranscript(cleaned, id: id)
            } catch {
                FlowLog.shared.write("ask transcription failed: \(error.localizedDescription)")
                guard id == self.voiceID else { return }
                self.composer.model.notice = "Couldn't write that down. Type it or talk again."
                self.landTranscript("", id: id)
            }
        }
    }

    private func landTranscript(_ spoken: String, id: Int) {
        guard id == voiceID, case .finishing = phase else { return }
        let text = AskText.join(typedBase, spoken)
        composer.model.text = text
        if spoken.isEmpty, composer.model.notice == nil {
            composer.model.notice = "Didn't catch that. Type it or talk again."
        }
        handle(.transcribed(hasText: !text.isEmpty))
    }

    // MARK: - Timers and live words

    private func scheduleHoldCheck() {
        guard let holdDelay, case .pressed = phase else { return }
        let id = pressID
        Task { [weak self] in
            try? await Task.sleep(for: holdDelay)
            guard let self, self.pressID == id, case .pressed = self.phase else { return }
            self.holdReached()
        }
    }

    private func startLiveWords() {
        stopLiveWords()
        guard let liveInterval, let mic else { return }
        let id = voiceID
        let live = LiveTranscriber(
            interval: liveInterval,
            sampleCount: { [mic] in mic.capturedSampleCount },
            samples: { [mic] range in mic.samples(in: range) },
            transcribe: { [transcribe] samples in try await transcribe(samples) },
            onText: { [weak self] spoken in
                guard let self, self.voiceID == id, self.phase.isMicOn else { return }
                self.composer.model.text = AskText.join(self.typedBase, spoken)
            }
        )
        liveTranscriber = live
        live.start()
    }

    private func stopLiveWords() {
        liveTranscriber?.stop()
        liveTranscriber = nil
    }
}
