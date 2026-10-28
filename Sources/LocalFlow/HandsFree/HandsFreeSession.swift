import AppKit
import Foundation

/// The one microphone, lent to the hands-free window by AppController, which owns it
/// and the dictation state.
@MainActor
protocol HandsFreeMicrophone: AnyObject {
    /// False when the mic is busy or can't start; the owner says why.
    func startHandsFree() -> Bool
    func stopHandsFree() -> [Float]
    func discardHandsFree()
    var capturedSampleCount: Int { get }
    func samples(in range: Range<Int>) -> [Float]
}

/// Runs the hands-free window: turns hotkey presses into HandsFreeFlow events and
/// carries out the effects (mic, live words, the window, pasting).
@MainActor
final class HandsFreeSession {
    typealias Transcribe = @MainActor ([Float]) async throws -> String

    private(set) var phase: HandsFreePhase = .closed {
        didSet { if phase != oldValue { onPhaseChange?(phase) } }
    }
    var onPhaseChange: ((HandsFreePhase) -> Void)?
    var keyName = "Fn" {
        didSet { composer.model.keyName = keyName }
    }

    var isOpen: Bool { phase.isOpen }

    private weak var mic: HandsFreeMicrophone?
    private let composer: ComposerSurface
    private let transcribe: Transcribe
    private let finish: Transcribe
    private let deliver: @MainActor (String) -> Void
    private let swallowPress: @MainActor () -> Void
    private let chime: @MainActor () -> Void
    private let holdDelay: Duration?
    private let liveInterval: Duration?

    /// Text in the box that the current voice turn adds to.
    private var typedBase = ""
    /// Bumped per mic start, so late live words or a late transcript can tell it's stale.
    private var voiceID = 0
    /// Bumped per key-down, so a late hold timer can tell it belongs to an older press.
    private var pressID = 0
    private var liveTranscriber: LiveTranscriber?

    /// Shorter clips than this are thrown away rather than transcribed into a guess.
    private static let minSpeechSamples = Int(0.3 * AudioRecorder.targetSampleRate)

    /// - Parameters:
    ///   - transcribe: a quick raw pass, for the words shown while talking.
    ///   - finish: the full pass (cleanup and polish) whose words land in the box.
    ///   - paste: puts the box's text into the app in front.
    ///   - holdDelay: when a press becomes a hold; nil = never automatically (tests).
    ///   - liveInterval: how often words appear while talking; nil = off (tests).
    init(mic: HandsFreeMicrophone,
         composer: ComposerSurface,
         transcribe: @escaping Transcribe,
         finish: @escaping Transcribe,
         paste: @escaping @MainActor (String) -> Void,
         swallowPress: @escaping @MainActor () -> Void,
         chime: @escaping @MainActor () -> Void = { SoundPlayer.playStart() },
         holdDelay: Duration? = .seconds(HotkeyMonitor.tapThreshold),
         liveInterval: Duration? = .milliseconds(600)) {
        self.mic = mic
        self.composer = composer
        self.transcribe = transcribe
        self.finish = finish
        self.deliver = paste
        self.swallowPress = swallowPress
        self.chime = chime
        self.holdDelay = holdDelay
        self.liveInterval = liveInterval
        composer.onSend = { [weak self] in self?.paste() }
        composer.onCancel = { [weak self] in self?.cancel() }
    }

    // MARK: - Events

    /// Opens the window listening. The mic is already recording (the double-tap's
    /// second press started it).
    func open() { handle(.open) }

    func keyDown() {
        pressID += 1
        handle(.keyDown)
        scheduleHoldCheck()
    }

    func keyUp(held: TimeInterval) { handle(.keyUp(held: held)) }
    func holdReached() { handle(.holdReached) }
    func otherKey() { handle(.otherKey) }
    func cancel() { handle(.cancel) }

    func micStopped() {
        guard phase.isMicOn else { return }
        composer.model.notice = "Paused at the 5-minute limit. Tap \(keyName) to keep talking."
        handle(.micStopped)
    }

    func micLost() {
        guard phase.isMicOn else { return }
        composer.model.notice = "Lost the microphone. Tap \(keyName) to try again."
        handle(.micLost)
    }

    /// Return or the paste button. An empty box pastes nothing.
    func paste() {
        let editable = phase == .editing || phase == .pressed
        if editable, Self.trimmed(composer.model.text).isEmpty {
            NSSound.beep()
            return
        }
        handle(.paste)
    }

    func updateLevel(_ level: Float) {
        guard phase.isMicOn else { return }
        composer.updateLevel(level)
    }

    // MARK: - Effects

    private func handle(_ event: HandsFreeEvent) {
        let (next, effects) = HandsFreeFlow.reduce(phase, event)
        phase = next
        for effect in effects {
            guard perform(effect) else { return }
        }
    }

    /// Returns false when the rest of the effects must not run.
    private func perform(_ effect: HandsFreeEffect) -> Bool {
        switch effect {
        case .show:
            voiceID += 1
            typedBase = ""
            composer.model.reset(mode: .voice)
            composer.model.keyName = keyName
            composer.show(on: ScreenCapturer.screenUnderMouse())
            startLiveWords()
        case .startMic:
            guard mic?.startHandsFree() == true else {
                // Busy or unavailable: the box stays for typing.
                phase = .editing
                composer.model.mode = .typing
                return false
            }
            voiceID += 1
        case .discardMic:
            stopLiveWords()
            mic?.discardHandsFree()
            // Drop live words that were showing; what was in the box stays.
            if composer.model.mode == .voice { composer.model.text = typedBase }
        case .finishMic:
            finishMic()
        case .showVoice:
            typedBase = composer.model.text
            composer.model.notice = nil
            composer.model.mode = .voice
            composer.takeKeyboard() // back from a click into another app
            startLiveWords()
        case .showEditing:
            composer.model.mode = .typing
            composer.takeKeyboard()
        case .chime:
            chime()
        case .swallowPress:
            swallowPress()
        case .paste:
            let text = Self.trimmed(composer.model.text)
            close()
            deliver(text)
        case .close:
            close()
        }
        return true
    }

    private func close() {
        stopLiveWords()
        composer.hide()
    }

    private func finishMic() {
        stopLiveWords()
        let samples = mic?.stopHandsFree() ?? []
        let id = voiceID
        composer.model.mode = .finishing
        guard samples.count >= Self.minSpeechSamples else {
            landTranscript("", id: id)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let spoken = try await self.finish(samples)
                self.landTranscript(spoken, id: id)
            } catch {
                FlowLog.shared.write("hands-free transcription failed: \(error.localizedDescription)")
                guard id == self.voiceID else { return }
                self.composer.model.notice = "Couldn't write that down. Type it or talk again."
                self.landTranscript("", id: id)
            }
        }
    }

    private func landTranscript(_ spoken: String, id: Int) {
        guard id == voiceID, case .finishing = phase else { return }
        let text = DictationText.join(typedBase, spoken)
        composer.model.text = text
        let hasText = !Self.trimmed(text).isEmpty
        if Self.trimmed(spoken).isEmpty, composer.model.notice == nil {
            composer.model.notice = hasText
                ? "Didn't catch that. Tap \(keyName) to talk again."
                : "Didn't catch that. Type it or tap \(keyName) to talk again."
        }
        handle(.transcribed(hasText: hasText))
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Timers and live words

    private func scheduleHoldCheck() {
        guard let holdDelay, phase == .pressed else { return }
        let id = pressID
        Task { [weak self] in
            try? await Task.sleep(for: holdDelay)
            guard let self, self.pressID == id, self.phase == .pressed else { return }
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
                self.composer.model.text = DictationText.join(self.typedBase, spoken)
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
