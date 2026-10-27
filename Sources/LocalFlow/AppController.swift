import AppKit
import Foundation

/// The optional on-device LLM cleanup stage (Apple FoundationModels).
@MainActor
protocol LLMPolisher: AnyObject {
    var isAvailable: Bool { get }
    var unavailableReason: String? { get }
    /// Hide model cold-start behind the time the user spends speaking.
    func prewarm()
    /// Returns polished text, or nil if unavailable / the output failed validation.
    func polish(transcript: String, category: AppCategory, appName: String, dictionary: [String]) async -> String?
    /// Command mode: apply a spoken instruction to selected text.
    func transform(selection: String, instruction: String) async -> String?
}

/// Resume-once guard for awaitWithDeadline (both racers run on the main actor).
private final class Once {
    var resumed = false
}

@MainActor
final class AppController {
    enum RecordingMode: Equatable {
        case dictation(handsFree: Bool)
        /// Fn+Ctrl: the utterance is an instruction applied to the selected text.
        case command
        /// Ask key: talking into the Ask window (AskSession drives it).
        case ask
    }

    enum FlowState: Equatable {
        case idle
        case recording(RecordingMode)
        case processing
    }

    private(set) var state: FlowState = .idle

    private let settings = Settings.shared
    private let recorder = AudioRecorder()
    private let rules = RulesPolisher()
    let inserter = TextInserter()
    let history = HistoryStore()

    private var hotkeyMonitor: HotkeyMonitor!
    /// Nil when Ask is off or its key collides with the dictation key.
    private var askHotkeyMonitor: HotkeyMonitor?
    private var ask: AskController!
    private var askSession: AskSession!
    private var menuBar: MenuBarController!
    private var hud: HUDPanel!
    private var livePanel: LivePanel!
    /// Runs only while the hands-free live window is up.
    private var liveTranscriber: LiveTranscriber?
    private var settingsWindow: SettingsWindowController!
    private var llmPolisher: LLMPolisher!
    private var recorderPrepared = false
    /// Distinguishes overlapping process() tasks (utterance 2 can start recording,
    /// even processing, while utterance 1 is still being polished).
    private var processingGeneration = 0
    /// Serializes whole pipelines IN GENERATION ORDER (the slot is claimed synchronously
    /// in finishRecording), so back-to-back utterances always paste in spoken order.
    private var processChain: Task<Void, Never> = Task {}
    /// Set by the 5-minute recording limit; consumed by the next finishRecording.
    private var pendingLimitNotice = false
    /// A Control + hotkey press that started no recording (command mode unavailable).
    /// Its release decides: a tap pastes the last transcript, a hold explains why not.
    private var controlPressWithoutRecording = false
    /// Bumped per recording, so a delayed "now it's a hold" step can tell whether it
    /// still belongs to the recording that scheduled it.
    private var recordingID = 0

    /// Always derived from settings — an engine switch can never desync this.
    /// (The factory caches instances, so this is cheap; in-flight dictations
    /// capture their own reference and are unaffected by switches.)
    private var transcriber: Transcriber {
        TranscriberFactory.make(settings.engine)
    }

    var isHandsFree: Bool {
        if case .recording(.dictation(handsFree: true)) = state { return true }
        return false
    }

    var statusLine: String {
        if !Permissions.allGranted { return "LocalFlow — permissions needed" }
        switch transcriber.state {
        case .notReady: return "LocalFlow — engine idle"
        case .downloadingModel: return "LocalFlow — downloading model…"
        case .loading: return "LocalFlow — loading model…"
        case .ready: return "LocalFlow — \(transcriber.displayName) ready"
        case .failed(let message): return "LocalFlow — engine error: \(message)"
        }
    }

    // MARK: - Lifecycle

    func start() {
        hud = HUDPanel()
        livePanel = LivePanel()
        menuBar = MenuBarController(controller: self)
        settingsWindow = SettingsWindowController(controller: self)
        llmPolisher = TranscriberFactory.makeLLMPolisher()
        ask = AskController(closeHint: askCloseHint)
        askSession = AskSession(
            mic: self,
            composer: AskComposerPanel(),
            answers: ask,
            transcribe: { [weak self] samples in
                guard let engine = self?.transcriber else { throw CancellationError() }
                return try await engine.transcribe(samples: samples)
            },
            canOpen: { [weak self] in self?.askCanOpen() ?? false },
            swallowPress: { [weak self] in self?.askHotkeyMonitor?.swallowCurrentPress() }
        )
        // Esc closes the Ask window or the answer, from any app, while one is up.
        askSession.onPhaseChange = { [weak self] _ in self?.updateAskEscape() }
        ask.onChange = { [weak self] in self?.updateAskEscape() }

        recorder.levelHandler = { [weak self] level in
            DispatchQueue.main.async {
                self?.hud.updateLevel(level)
                self?.livePanel.updateLevel(level)
                self?.askSession.updateLevel(level)
            }
        }
        recorder.limitHandler = { [weak self] in
            guard let self, case .recording(let mode) = self.state else { return }
            if mode == .ask {
                self.askSession.micStopped()
                return
            }
            // The notice itself is shown by process() at the end — flashing here would be
            // synchronously overwritten by "Transcribing…" before a single frame renders.
            self.pendingLimitNotice = true
            self.finishRecording()
        }
        recorder.captureLostHandler = { [weak self] in
            guard let self, case .recording = self.state else { return }
            FlowLog.shared.write("capture lost mid-recording, input: \(AudioRecorder.currentInputName)")
            SoundPlayer.playError()
            if case .recording(.ask) = self.state {
                self.askSession.micLost()
            } else {
                self.abortRecording(silent: false)
            }
            self.hud.flash("Lost the microphone, recording stopped. Try again", seconds: 3)
        }

        hotkeyMonitor = HotkeyMonitor(choice: settings.hotkey)
        hotkeyMonitor.onPressBegan = { [weak self] command in self?.hotkeyPressed(command: command) }
        hotkeyMonitor.onPressEnded = { [weak self] held in self?.hotkeyReleased(held: held) }
        hotkeyMonitor.onDoubleTap = { [weak self] in self?.hotkeyDoubleTapped() }
        hotkeyMonitor.onEscape = { [weak self] in self?.cancelDictation() }
        hotkeyMonitor.startMonitoring()
        configureAskHotkey()

        Task { await bootstrap() }
    }

    private func bootstrap() async {
        if !Permissions.microphoneGranted {
            _ = await Permissions.requestMicrophone()
        }
        if Permissions.microphoneGranted {
            recorder.prepare()
            recorderPrepared = true
        }
        if !Permissions.allGranted {
            settingsWindow.show(tab: .setup)
        }
        await prepare(engine: transcriber)
    }

    private func prepare(engine: Transcriber) async {
        do {
            try await engine.prepare()
        } catch {
            hud.flash("Speech model failed to load: \(error.localizedDescription)", seconds: 4)
        }
    }

    func shutdown() {
        stopLiveWindow()
        askSession?.cancel()
        ask?.dismiss()
        askHotkeyMonitor?.stopMonitoring()
        hotkeyMonitor?.stopMonitoring()
        if case .recording = state {
            recorder.cancel()
        }
    }

    // MARK: - Settings callbacks

    func hotkeyChanged(to choice: HotkeyChoice) {
        // If the OLD key is mid-hold, its release event won't match the new choice and
        // recording would stay stuck on. Wrap up the utterance first.
        switch state {
        case .recording(.dictation(handsFree: false)), .recording(.command):
            finishRecording()
        default:
            break
        }
        hotkeyMonitor.updateHotkey(choice)
        // The ask key turns off if it now matches the dictation key (and back on).
        configureAskHotkey()
    }

    func askKeyChanged() {
        configureAskHotkey()
    }

    var askRememberedTurns: Int { ask?.rememberedTurns ?? 0 }

    func forgetAskConversation() {
        ask.forgetConversation()
    }

    func askMemoryLimitChanged() {
        ask.applyMemoryLimit()
    }

    func engineChanged() {
        // The `transcriber` property already tracks settings; just warm the new engine.
        Task { await prepare(engine: transcriber) }
    }

    func permissionsMayHaveChanged() {
        if Permissions.microphoneGranted, !recorderPrepared {
            recorder.prepare()
            recorderPrepared = true
        }
    }

    func openSettings(tab: SettingsTab = .general) {
        settingsWindow.show(tab: tab)
    }

    // MARK: - Hotkey handling

    private func hotkeyPressed(command: Bool) {
        controlPressWithoutRecording = false
        // The Ask window has the keyboard and sits where the dictation pill would.
        guard !askSession.phase.isOpen else { return }
        // The voice key also closes an open answer (and cancels one on its way). A
        // minimized one is being kept on purpose.
        if ask.isExpanded { ask.dismiss() }
        switch state {
        case .idle, .processing:
            if command, !llmPolisher.isAvailable {
                // Might be a quick Control tap (paste last transcript): decide on release.
                controlPressWithoutRecording = true
                return
            }
            // Pressing while the PREVIOUS utterance is still processing starts the next
            // recording immediately — back-to-back dictation must not lose speech.
            beginRecording(mode: command ? .command : .dictation(handsFree: false))
        case .recording(.dictation(handsFree: true)):
            // Tap while hands-free: stop and process. The matching release is swallowed
            // so it can't count toward a double-tap that would flip hands-free back on.
            hotkeyMonitor.swallowCurrentPress()
            finishRecording()
        case .recording:
            break
        }
    }

    private func hotkeyReleased(held: TimeInterval) {
        switch state {
        case .recording(.dictation(handsFree: false)):
            if held >= HotkeyMonitor.tapThreshold {
                finishRecording()
            } else {
                // A stray tap — discard quietly. (A second tap may still arrive and
                // upgrade to hands-free via onDoubleTap.)
                abortRecording(silent: true)
            }
        case .recording(.command):
            if ControlHotkeyAction.forRelease(held: held, commandAvailable: true) == .finishCommand {
                finishRecording()
            } else {
                abortRecording(silent: true)
                pasteLastTranscript()
            }
        default:
            guard controlPressWithoutRecording else { break }
            controlPressWithoutRecording = false
            switch ControlHotkeyAction.forRelease(held: held, commandAvailable: false) {
            case .pasteLastTranscript:
                pasteLastTranscript()
            case .commandUnavailable:
                SoundPlayer.playError()
                hud.flash("Command mode needs Apple Intelligence — \(llmPolisher.unavailableReason ?? "unavailable")", seconds: 4)
            case .finishCommand:
                break
            }
        }
    }

    /// Control + hotkey tap (or the menu): paste the last dictation again, without
    /// touching what the user has on the clipboard.
    func pasteLastTranscript() {
        // After a restart the in-memory transcript is gone; saved history may still have it.
        let fallback = inserter.lastTranscript == nil ? history.entries.first?.text : nil
        Task {
            // Control is usually still held when the hotkey comes up; a Cmd+V posted
            // under it reaches the app as Control-Cmd-V.
            await waitForModifiersReleased()
            let result: InsertionResult?
            if let fallback {
                result = await inserter.insert(fallback)
            } else {
                result = await inserter.pasteLastTranscript()
            }
            guard let result else {
                hud.flash("Nothing to paste yet")
                return
            }
            FlowLog.shared.write("paste last transcript: \(result)")
            if case .leftOnClipboard(let reason) = result {
                SoundPlayer.playError()
                hud.flash("Copied to clipboard — \(reason)", seconds: 3.5)
            }
        }
    }

    private func waitForModifiersReleased(timeout: Duration = .milliseconds(1500)) async {
        let held: NSEvent.ModifierFlags = [.control, .option, .shift, .command, .function]
        let deadline = ContinuousClock.now + timeout
        while !NSEvent.modifierFlags.intersection(held).isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func hotkeyDoubleTapped() {
        if controlPressWithoutRecording {
            controlPressWithoutRecording = false
            pasteLastTranscript()
            return
        }
        switch state {
        case .recording(.dictation(handsFree: false)):
            // Second tap-down already restarted recording; just flip it to hands-free.
            state = .recording(.dictation(handsFree: true))
            presentHandsFree()
        case .recording(.command):
            // Two quick Control taps: each one is a paste, never a stuck command recording.
            abortRecording(silent: true)
            pasteLastTranscript()
        case .idle:
            beginRecording(mode: .dictation(handsFree: true))
        default:
            break
        }
    }

    func toggleHandsFree() {
        switch state {
        case .idle:
            beginRecording(mode: .dictation(handsFree: true))
        case .recording:
            finishRecording()
        case .processing:
            break
        }
    }

    // MARK: - Ask key

    private var askKeyName: String {
        AskKeyChoice.effectiveHotkey(ask: settings.askKey, dictation: settings.hotkey)?.shortName ?? "Ask key"
    }

    private var askCloseHint: String {
        "Esc to minimize   ·   ⇧Esc to close   ·   \(askKeyName) to ask again"
    }

    private func updateAskEscape() {
        // Live while the chip is up too: Esc brings it back, Shift+Esc closes it.
        askHotkeyMonitor?.escapeEnabled = askSession.phase.isOpen || ask.presence != .none
    }

    /// Esc cancels the Ask window, or tucks the answer away and back; Shift+Esc closes it.
    private func askEscape(shift: Bool) {
        switch AskEscape.action(shift: shift, windowOpen: askSession.phase.isOpen, answer: ask.presence) {
        case .cancelWindow: askSession.cancel()
        case .close: ask.dismiss()
        case .minimize: ask.minimize()
        case .expand: ask.expand()
        case nil: break
        }
    }

    private func configureAskHotkey() {
        // The old monitor's release would never arrive: close an Ask in progress first.
        askSession.cancel()
        askHotkeyMonitor?.stopMonitoring()
        askHotkeyMonitor = nil
        ask.updateCloseHint(askCloseHint)
        askSession.keyName = askKeyName
        guard let key = AskKeyChoice.effectiveHotkey(ask: settings.askKey, dictation: settings.hotkey) else { return }
        let monitor = HotkeyMonitor(choice: key)
        let now = { ProcessInfo.processInfo.systemUptime }
        monitor.onPressBegan = { [weak self] _ in self?.askSession.keyDown(at: now()) }
        monitor.onPressEnded = { [weak self] held in self?.askSession.keyUp(held: held, at: now()) }
        // The monitor reports a second quick tap as a double-tap; Ask times its own.
        monitor.onDoubleTap = { [weak self] in self?.askSession.keyUp(held: 0, at: now()) }
        monitor.onKeyDownWhileHeld = { [weak self] in self?.askSession.otherKey() }
        monitor.onEscape = { [weak self] in self?.askEscape(shift: false) }
        monitor.onShiftEscape = { [weak self] in self?.askEscape(shift: true) }
        monitor.startMonitoring()
        askHotkeyMonitor = monitor
        updateAskEscape()
    }

    /// Checked before the Ask window first appears: it can't see the screen without this.
    private func askCanOpen() -> Bool {
        guard Permissions.screenRecordingGranted else {
            Permissions.requestScreenRecording()
            SoundPlayer.playError()
            hud.flash("Ask needs Screen Recording. Turn on LocalFlow in System Settings, then ask again", seconds: 4)
            return false
        }
        return true
    }

    private func cancelDictation() {
        guard case .recording = state else { return }
        abortRecording(silent: false)
    }

    // MARK: - Recording pipeline

    private func beginRecording(mode: RecordingMode) {
        guard Permissions.allGranted else {
            settingsWindow.show(tab: .setup)
            return
        }
        if case .command = mode, !llmPolisher.isAvailable {
            SoundPlayer.playError()
            hud.flash("Command mode needs Apple Intelligence — \(llmPolisher.unavailableReason ?? "unavailable")", seconds: 4)
            return
        }
        let engine = transcriber
        guard engine.state == .ready else {
            hud.flash(engine.state == .downloadingModel
                      ? "Still downloading the speech model…"
                      : "Speech model not ready yet")
            return
        }
        do {
            try recorder.start()
        } catch {
            FlowLog.shared.write("mic start failed: \(error.localizedDescription), input: \(AudioRecorder.currentInputName)")
            SoundPlayer.playError()
            hud.flash("Couldn't start the microphone: \(error.localizedDescription)")
            return
        }
        FlowLog.shared.write("recording started (\(mode)), input: \(AudioRecorder.currentInputName)")
        state = .recording(mode)
        recordingID += 1
        let id = recordingID
        hotkeyMonitor.escapeEnabled = true
        menuBar.setIcon(recording: true)
        switch mode {
        case .dictation(let handsFree):
            if handsFree {
                presentHandsFree()
            } else {
                hud.showRecording(caption: "Listening")
            }
            if settings.polishMode == .appleIntelligence {
                llmPolisher.prewarm()
            }
            SoundPlayer.playStart()
        case .command:
            llmPolisher.prewarm() // command mode always needs the model
            // Recording starts now so no speech is lost, but the pill and chime wait
            // until this is clearly a hold: a quick Control tap means "paste last
            // transcript" and shouldn't flash command mode first.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(HotkeyMonitor.tapThreshold))
                guard let self, self.recordingID == id, case .recording(.command) = self.state else { return }
                self.hud.showRecording(caption: "Command — speak an edit", accent: .command)
                SoundPlayer.playStart()
            }
        case .ask:
            break // Ask's mic starts through startAsk()
        }
    }

    /// Hands-free UI: the big live window (words appear as you talk), or the pill if
    /// the live window is switched off in Settings.
    private func presentHandsFree() {
        guard settings.liveWindowOnDoubleTap else {
            hud.showRecording(caption: "Listening (hands-free)")
            return
        }
        hud.hide()
        livePanel.show()
        let engine = transcriber
        let live = LiveTranscriber(
            sampleCount: { [recorder] in recorder.capturedSampleCount },
            samples: { [recorder] range in recorder.samples(in: range) },
            transcribe: { samples in try await engine.transcribe(samples: samples) },
            onText: { [weak self] text in self?.livePanel.update(text: text) }
        )
        liveTranscriber = live
        live.start()
    }

    private func stopLiveWindow() {
        liveTranscriber?.stop()
        liveTranscriber = nil
        livePanel?.hide()
    }

    /// Awaits an abandonable task with a hard deadline. On timeout the task keeps
    /// running in the background (FoundationModels ignores cancellation) but its
    /// result is discarded — the caller moves on with nil.
    private func awaitWithDeadline<T: Sendable>(_ task: Task<T?, Never>, seconds: Double) async -> T? {
        await withCheckedContinuation { continuation in
            let once = Once()
            Task { @MainActor in
                let value = await task.value
                guard !once.resumed else { return }
                once.resumed = true
                continuation.resume(returning: value)
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                guard !once.resumed else { return }
                once.resumed = true
                continuation.resume(returning: nil)
            }
        }
    }

    private func abortRecording(silent: Bool) {
        if case .recording(.ask) = state {
            askSession.micLost()
            return
        }
        stopLiveWindow()
        recorder.cancel()
        state = .idle
        hotkeyMonitor.escapeEnabled = false
        menuBar.setIcon(recording: false)
        if silent {
            hud.hide()
        } else {
            hud.flash("Cancelled")
        }
    }

    private func finishRecording() {
        guard case .recording(let mode) = state else { return }
        if mode == .ask {
            askSession.micStopped() // finishes through stopAsk()
            return
        }
        stopLiveWindow()
        let samples = recorder.stop()
        hotkeyMonitor.escapeEnabled = false
        menuBar.setIcon(recording: false)

        let duration = Double(samples.count) / AudioRecorder.targetSampleRate
        FlowLog.shared.write(String(format: "recording stopped: %.1fs, peak %.4f", duration, AudioStats.peak(samples)))
        guard duration >= 0.3 else {
            state = .idle
            if recorder.lastStopWasStalled {
                // Long enough to count, but not one buffer of audio arrived: the input
                // is wedged. Say so (this used to vanish silently) and start the next
                // dictation on a fresh engine.
                recorder.rebuild(reason: "recording came back empty")
                SoundPlayer.playError()
                hud.flash("The mic didn't record anything. Try again", seconds: 3)
            } else {
                hud.hide()
            }
            return
        }

        state = .processing
        processingGeneration += 1
        let generation = processingGeneration
        let limitNotice = pendingLimitNotice
        pendingLimitNotice = false
        hud.showProcessing("Transcribing…")
        // Snapshot the target app and engine now: an engine switch or app change during
        // processing must not affect this utterance.
        let engine = transcriber
        let (category, appName) = AppCategory.forFrontmostApp()

        let previous = processChain
        processChain = Task {
            await previous.value
            if case .command = mode {
                await self.processCommand(samples: samples, engine: engine,
                                          appName: appName, generation: generation)
            } else {
                await self.process(samples: samples, engine: engine, category: category,
                                   appName: appName, generation: generation, limitNotice: limitNotice)
            }
        }
    }

    /// Command mode: transcribe the spoken instruction, apply it to the selected text
    /// via the on-device LLM, paste the result over the selection.
    private func processCommand(samples: [Float], engine: Transcriber, appName: String, generation: Int) async {
        defer {
            if state == .processing, processingGeneration == generation { state = .idle }
        }
        let hudActive = {
            guard self.processingGeneration == generation else { return false }
            if case .recording = self.state { return false }
            return true
        }
        func fail(_ message: String) {
            SoundPlayer.playError()
            if hudActive() { hud.flash(message, seconds: 3.5) }
        }

        guard let selection = await inserter.captureSelection() else {
            fail("Command mode: select some text first")
            return
        }

        let raw: String
        do {
            raw = try await engine.transcribe(samples: samples)
        } catch {
            fail("Transcription failed: \(error.localizedDescription)")
            return
        }
        let instruction = rules.apply(raw, category: .other, replacements: settings.replacements,
                                      spokenCommands: false, toneMatching: false)
        guard !instruction.isEmpty else {
            fail("Didn't catch the instruction")
            return
        }

        if hudActive() { hud.showProcessing("Applying…") }
        let polisher = llmPolisher!
        let transformTask = Task { await polisher.transform(selection: selection, instruction: instruction) }
        let transformed = await awaitWithDeadline(transformTask, seconds: 15)

        guard let transformed else {
            fail("Couldn't apply that edit — selection left unchanged")
            return
        }
        guard transformed != selection else {
            if hudActive() { hud.flash("No change needed") }
            return
        }

        let result = await inserter.insert(transformed)
        history.add(text: transformed, appName: appName)
        switch result {
        case .pasted:
            SoundPlayer.playStop()
            if hudActive() { hud.hide() }
        case .leftOnClipboard(let reason):
            fail("Copied to clipboard — \(reason)")
        }
    }

    private func process(samples: [Float], engine: Transcriber, category: AppCategory,
                         appName: String, generation: Int, limitNotice: Bool) async {
        // A newer recording/processing session may begin while we run; if so, it owns
        // the state and HUD and we must not stomp on them.
        defer {
            if state == .processing, processingGeneration == generation { state = .idle }
        }
        // The HUD is ours to update unless a NEWER session took it over: a newer finished
        // recording bumps the generation; a newer LIVE recording shows "Listening". (A
        // newer aborted tap leaves state .idle with our generation — flashing is safe.)
        let hudActive = {
            guard self.processingGeneration == generation else { return false }
            if case .recording = self.state { return false }
            return true
        }

        let raw: String
        let started = ContinuousClock.now
        do {
            raw = try await engine.transcribe(samples: samples)
        } catch {
            FlowLog.shared.write("transcription failed: \(error.localizedDescription)")
            SoundPlayer.playError()
            if hudActive() { hud.flash("Transcription failed: \(error.localizedDescription)", seconds: 3) }
            return
        }
        FlowLog.shared.write("transcribed \(raw.count) chars in \(started.duration(to: .now))")

        let preCleaned = rules.apply(
            raw,
            category: category,
            replacements: settings.replacements,
            spokenCommands: settings.spokenCommands,
            toneMatching: false
        )
        guard !preCleaned.isEmpty else {
            if AudioStats.isSilent(samples) {
                let input = AudioRecorder.currentInputName
                FlowLog.shared.write("empty transcript from silent audio, input: \(input)")
                SoundPlayer.playError()
                if hudActive() { hud.flash("Your mic heard silence. Input is \(input)", seconds: 3.5) }
            } else if hudActive() {
                hud.flash("Didn't catch anything")
            }
            return
        }

        var text = preCleaned
        let wordCount = preCleaned.split { $0.isWhitespace }.count
        // Short utterances normally skip the LLM (ASR is already punctuated), but a short
        // one that still contains spelled-out numbers or punctuation-symbols ("room twenty
        // four", "question mark") needs the context-aware pass to normalize it.
        let needsNormalization = ITN.needsContextualNormalization(preCleaned)
        if settings.polishMode == .appleIntelligence,
           llmPolisher.isAvailable,
           wordCount >= settings.polishMinWords || needsNormalization {
            if hudActive() { hud.showProcessing("Polishing…") }
            // Race the LLM against a real deadline. FoundationModels ignores task
            // cancellation mid-generation (verified empirically), and a task group would
            // await the losing child — so the polish runs as an ABANDONABLE unstructured
            // task and the first finisher wins.
            let polisher = llmPolisher!
            let dictionary = settings.dictionaryWords
            let polishTask = Task {
                await polisher.polish(
                    transcript: preCleaned,
                    category: category,
                    appName: appName,
                    dictionary: dictionary
                )
            }
            if let polished = await awaitWithDeadline(polishTask, seconds: 10) {
                text = polished
            }
        }
        text = RulesPolisher.applyTone(to: text, category: category, enabled: settings.toneMatching)

        let result = await inserter.insert(text)
        history.add(text: text, appName: appName)
        FlowLog.shared.write("insert into \(appName): \(result)")

        switch result {
        case .pasted:
            SoundPlayer.playStop()
            if hudActive() {
                if limitNotice {
                    hud.flash("Stopped at the 5-minute recording limit", seconds: 3)
                } else {
                    hud.hide()
                }
            }
        case .leftOnClipboard(let reason):
            SoundPlayer.playError()
            if hudActive() { hud.flash("Copied to clipboard — \(reason)", seconds: 3.5) }
        }
    }
}

// MARK: - The microphone, lent to Ask

extension AppController: AskMicrophone {
    func startAsk() -> Bool {
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
        // Ask runs outside processChain: a slow answer never holds up a dictation's paste.
        state = .recording(.ask)
        menuBar.setIcon(recording: true)
        return true
    }

    func stopAsk() -> [Float] {
        guard case .recording(.ask) = state else { return [] }
        let samples = recorder.stop()
        state = .idle
        menuBar.setIcon(recording: false)
        let duration = Double(samples.count) / AudioRecorder.targetSampleRate
        FlowLog.shared.write(String(format: "ask recording stopped: %.1fs, peak %.4f", duration, AudioStats.peak(samples)))
        if recorder.lastStopWasStalled {
            recorder.rebuild(reason: "ask recording came back empty")
        }
        return samples
    }

    func discardAsk() {
        guard case .recording(.ask) = state else { return }
        recorder.cancel()
        state = .idle
        menuBar.setIcon(recording: false)
    }

    var capturedSampleCount: Int { recorder.capturedSampleCount }

    func samples(in range: Range<Int>) -> [Float] { recorder.samples(in: range) }
}
