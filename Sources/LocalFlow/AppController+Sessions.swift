import AppKit
import Foundation

// MARK: - Cleanup shared by every dictation

extension AppController {
    func preClean(_ raw: String, category: AppCategory) -> String {
        rules.apply(raw, category: category, replacements: settings.replacements,
                    spokenCommands: settings.spokenCommands, toneMatching: false)
    }

    /// The on-device polish when it's worth running, then tone matching.
    func polish(_ preCleaned: String, category: AppCategory, appName: String,
                        onPolishing: () -> Void = {}) async -> String {
        var text = preCleaned
        let wordCount = preCleaned.split { $0.isWhitespace }.count
        // Short utterances normally skip the LLM (ASR is already punctuated), but a short
        // one that still contains spelled-out numbers or punctuation-symbols ("room twenty
        // four", "question mark") needs the context-aware pass to normalize it.
        let needsNormalization = ITN.needsContextualNormalization(preCleaned)
        if settings.polishMode == .appleIntelligence,
           llmPolisher.isAvailable,
           wordCount >= settings.polishMinWords || needsNormalization {
            onPolishing()
            // Race the LLM against a real deadline. FoundationModels ignores task
            // cancellation mid-generation (verified empirically), and a task group would
            // await the losing child — so the polish runs as an ABANDONABLE unstructured
            // task and the first finisher wins.
            let polisher = llmPolisher!
            let dictionary = settings.dictionaryWords
            let polishTask = Task {
                await polisher.polish(transcript: preCleaned, category: category,
                                      appName: appName, dictionary: dictionary)
            }
            if let polished = await awaitWithDeadline(polishTask, seconds: 10) {
                text = polished
            }
        }
        return RulesPolisher.applyTone(to: text, category: category, enabled: settings.toneMatching)
    }

    /// A quick pass with no cleanup, for words shown while talking.
    var rawTranscribe: HandsFreeSession.Transcribe {
        { [weak self] samples in
            guard let engine = self?.transcriber else { throw CancellationError() }
            return try await engine.transcribe(samples: samples)
        }
    }
}

// MARK: - The hands-free window

extension AppController {
    private static let keyboardReturnDelay: Duration = .milliseconds(120)

    var dictationKeyName: String { settings.hotkey.shortName ?? "⌃⌥" }

    func makeHandsFreeSession() -> HandsFreeSession {
        let session = HandsFreeSession(
            mic: self,
            composer: DictationComposerPanel(),
            transcribe: rawTranscribe,
            finish: { [weak self] samples in
                guard let self else { throw CancellationError() }
                return try await self.writeDown(samples)
            },
            paste: { [weak self] text in self?.pasteHandsFree(text) },
            swallowPress: { [weak self] in self?.hotkeyMonitor.swallowCurrentPress() }
        )
        session.keyName = dictationKeyName
        // Esc cancels the window from any app while it's up.
        session.onPhaseChange = { [weak self] phase in self?.hotkeyMonitor.escapeEnabled = phase.isOpen }
        return session
    }

    /// What lands in the box when the hands-free window pauses: the same cleanup and
    /// polish a dictation gets. Empty when nothing usable was said.
    private func writeDown(_ samples: [Float]) async throws -> String {
        let engine = transcriber
        let (category, appName) = AppCategory.forFrontmostApp()
        let raw = try await engine.transcribe(samples: samples)
        FlowLog.shared.write("hands-free: transcribed \(raw.count) chars")
        let preCleaned = preClean(raw, category: category)
        guard !preCleaned.isEmpty else { return "" }
        return await polish(preCleaned, category: category, appName: appName)
    }

    /// A dictation from before the hands-free window opened waits to paste until it
    /// closes: while it's open it has the keyboard, so Cmd+V would land in its box.
    func waitForHandsFreeWindow() async {
        guard handsFree.isOpen else { return }
        while handsFree.isOpen {
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? await Task.sleep(for: Self.keyboardReturnDelay)
    }

    /// Return in the hands-free window: the box goes into the app in front, after any
    /// dictation still being polished, so everything lands in the order spoken.
    private func pasteHandsFree(_ text: String) {
        let (_, appName) = AppCategory.forFrontmostApp()
        let previous = processChain
        processChain = Task {
            await previous.value
            // The window just gave the keyboard back; let the app's text field take it.
            try? await Task.sleep(for: Self.keyboardReturnDelay)
            let result = await self.inserter.insert(text)
            self.history.add(text: text, appName: appName)
            FlowLog.shared.write("hands-free insert into \(appName): \(result)")
            switch result {
            case .pasted:
                SoundPlayer.playStop()
            case .leftOnClipboard(let reason):
                SoundPlayer.playError()
                self.hud.flash("Copied to clipboard — \(reason)", seconds: 3.5)
            }
        }
    }
}

// MARK: - The microphone, lent to Ask and the hands-free window

extension AppController: AskMicrophone, HandsFreeMicrophone {
    func startAsk() -> Bool { startLentMic(.ask) }
    func stopAsk() -> [Float] { stopLentMic(.ask, label: "ask") }
    func discardAsk() { discardLentMic(.ask) }

    func startHandsFree() -> Bool { startLentMic(.dictation(handsFree: true)) }
    func stopHandsFree() -> [Float] { stopLentMic(.dictation(handsFree: true), label: "hands-free") }
    func discardHandsFree() { discardLentMic(.dictation(handsFree: true)) }

    var capturedSampleCount: Int { recorder.capturedSampleCount }

    func samples(in range: Range<Int>) -> [Float] { recorder.samples(in: range) }

    /// For a window that runs its own gestures. Outside processChain: a slow answer or
    /// a paused edit never holds up a dictation's paste.
    private func startLentMic(_ mode: RecordingMode) -> Bool {
        switch state {
        case .idle, .processing: break
        case .recording: return false // a dictation has the mic
        }
        guard Permissions.allGranted else {
            settingsWindow.show(tab: .setup)
            return false
        }
        let engine = transcriber
        guard engine.state == .ready else {
            hud.flash(engine.state == .downloadingModel ? "Still downloading the speech model…" : "Speech model not ready yet")
            return false
        }
        do {
            try recorder.start()
        } catch {
            FlowLog.shared.write("mic start failed: \(error.localizedDescription), input: \(AudioRecorder.currentInputName)")
            SoundPlayer.playError()
            hud.flash("Couldn't start the microphone: \(error.localizedDescription)")
            return false
        }
        FlowLog.shared.write("recording started (\(mode)), input: \(AudioRecorder.currentInputName)")
        state = .recording(mode)
        menuBar.setIcon(recording: true)
        return true
    }

    private func stopLentMic(_ mode: RecordingMode, label: String) -> [Float] {
        guard state == .recording(mode) else { return [] }
        let samples = recorder.stop()
        state = .idle
        menuBar.setIcon(recording: false)
        let duration = Double(samples.count) / AudioRecorder.targetSampleRate
        FlowLog.shared.write(String(format: "\(label) recording stopped: %.1fs, peak %.4f", duration, AudioStats.peak(samples)))
        if recorder.lastStopWasStalled {
            recorder.rebuild(reason: "\(label) recording came back empty")
        }
        return samples
    }

    private func discardLentMic(_ mode: RecordingMode) {
        guard state == .recording(mode) else { return }
        recorder.cancel()
        state = .idle
        menuBar.setIcon(recording: false)
    }
}
