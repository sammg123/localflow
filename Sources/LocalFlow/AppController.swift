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

    // Internal (not private) where AppController+Sessions.swift needs it.
    var state: FlowState = .idle

    let settings = Settings.shared
    let recorder = AudioRecorder()
    let rules = RulesPolisher()
    let inserter = TextInserter()
    let history = HistoryStore()

    var hotkeyMonitor: HotkeyMonitor!
    /// Nil when Ask is off or its key collides with the dictation key.
    private var askHotkeyMonitor: HotkeyMonitor?
    private var ask: AskController!
    private var askSession: AskSession!
    private var askChats: AskHistoryWindowController!
    var menuBar: MenuBarController!
    var hud: HUDPanel!
    /// The double-tap window: talk, pause to edit, Return to paste.
    var handsFree: HandsFreeSession!
    var settingsWindow: SettingsWindowController!
    var llmPolisher: LLMPolisher!
    private var recorderPrepared = false
    /// Distinguishes overlapping process() tasks (utterance 2 can start recording,
    /// even processing, while utterance 1 is still being polished).
    private var processingGeneration = 0
    /// Serializes whole pipelines IN GENERATION ORDER (the slot is claimed synchronously
    /// in finishRecording), so back-to-back utterances always paste in spoken order.
    var processChain: Task<Void, Never> = Task {}
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
    var transcriber: Transcriber {
        TranscriberFactory.make(settings.engine)
    }

    var isHandsFreeWindowOpen: Bool { handsFree?.isOpen == true }

    var isHandsFree: Bool {
        if handsFree?.isOpen == true { return true }
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
        menuBar = MenuBarController(controller: self)
        settingsWindow = SettingsWindowController(controller: self)
        llmPolisher = TranscriberFactory.makeLLMPolisher()
        ask = AskController(chats: AskChatStore(fileURL: AskChatStore.defaultURL), closeHint: askCloseHint)
        askChats = AskHistoryWindowController(store: ask.chats) { [weak self] id in self?.continueAskChat(id) }
        let composer = AskComposerPanel()
        askSession = AskSession(
            mic: self,
            composer: composer,
            answers: ask,
            transcribe: rawTranscribe,
            canOpen: { [weak self] in self?.askCanOpen() ?? false },
            swallowPress: { [weak self] in self?.askHotkeyMonitor?.swallowCurrentPress() }
        )
        // Esc closes the Ask window or the answer, from any app, while one is up.
        askSession.onPhaseChange = { [weak self] _ in self?.updateAskEscape() }
        ask.onChange = { [weak self] in self?.updateAskEscape() }
        ask.onOpenChats = { [weak self] in self?.showAskChats() }
        composer.onOpenChats = { [weak self] in
            self?.askSession.closeKeepingDraft()
            self?.showAskChats()
        }

        handsFree = makeHandsFreeSession()

        recorder.levelHandler = { [weak self] level in
            DispatchQueue.main.async {
                self?.hud.updateLevel(level)
                self?.handsFree.updateLevel(level)
                self?.askSession.updateLevel(level)
            }
        }
        recorder.limitHandler = { [weak self] in
            guard let self, case .recording(let mode) = self.state else { return }
            if mode == .ask {
                self.askSession.micStopped()
                return
            }
            if self.handsFree.isOpen {
                self.handsFree.micStopped()
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
            } else if self.handsFree.isOpen {
                self.handsFree.micLost() // says so in its own window, where the pill would be
                return
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
        // Fn + Delete or Fn + arrow while editing in the hands-free window.
        hotkeyMonitor.onKeyDownWhileHeld = { [weak self] in self?.handsFree.otherKey() }
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
        handsFree?.cancel()
        askSession?.cancel()
        ask?.dismiss()
        ask?.chats.flush()
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
            // A press held in the hands-free window counts as let go.
            if handsFree.isOpen { handsFree.keyUp(held: HotkeyMonitor.tapThreshold) }
        }
        hotkeyMonitor.updateHotkey(choice)
        handsFree.keyName = dictationKeyName
        // The ask key turns off if it now matches the dictation key (and back on).
        configureAskHotkey()
    }

    func askKeyChanged() {
        configureAskHotkey()
    }

    /// A chat is going: the next question joins it.
    var askHasCurrentChat: Bool { ask?.chats.currentChat != nil }

    func forgetAskConversation() {
        ask.forgetConversation()
    }

    func showAskChats() {
        askChats.show()
    }

    /// From the Chats window: the next question joins that chat, and the Ask window opens
    /// over the app that was in front, ready for typing.
    private func continueAskChat(_ id: AskChat.ID) {
        ask.chats.continueChat(id)
        askChats.close()
        NSApp.deactivate()
        Task { @MainActor [weak self] in
            // Open once the app that was in front has taken over again, so it can't take
            // the keyboard back from the Ask window (at most 0.6 s).
            let me = ProcessInfo.processInfo.processIdentifier
            for _ in 0..<12 where NSWorkspace.shared.frontmostApplication?.processIdentifier == me {
                try? await Task.sleep(for: .milliseconds(50))
            }
            self?.askSession.openForTyping()
        }
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
        if handsFree.isOpen {
            handsFree.keyDown()
            return
        }
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
        if handsFree.isOpen {
            handsFree.keyUp(held: held)
            return
        }
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
            await waitForHandsFreeWindow()
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
        if handsFree.isOpen {
            // The monitor reports a second quick tap as a double-tap; the window times its own.
            handsFree.keyUp(held: 0)
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
        if handsFree.isOpen {
            handsFree.paste()
            return
        }
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
        // The monitor reports a second quick tap as a double-tap; to Ask it's a plain release.
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
        // Both windows sit where the pill does; the dictation one is in use.
        guard !handsFree.isOpen else {
            NSSound.beep()
            return false
        }
        guard Permissions.screenRecordingGranted else {
            Permissions.requestScreenRecording()
            SoundPlayer.playError()
            hud.flash("Ask needs Screen Recording. Turn on LocalFlow in System Settings, then ask again", seconds: 4)
            return false
        }
        return true
    }

    private func cancelDictation() {
        if handsFree.isOpen {
            handsFree.cancel()
            return
        }
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
        handsFree.open()
    }

    /// Awaits an abandonable task with a hard deadline. On timeout the task keeps
    /// running in the background (FoundationModels ignores cancellation) but its
    /// result is discarded — the caller moves on with nil.
    func awaitWithDeadline<T: Sendable>(_ task: Task<T?, Never>, seconds: Double) async -> T? {
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

        await waitForHandsFreeWindow()
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

        await waitForHandsFreeWindow()
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

        let preCleaned = preClean(raw, category: category)
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

        let text = await polish(preCleaned, category: category, appName: appName) {
            if hudActive() { hud.showProcessing("Polishing…") }
        }

        await waitForHandsFreeWindow()
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
