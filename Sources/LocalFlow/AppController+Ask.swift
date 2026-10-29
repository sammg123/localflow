import AppKit
import Foundation

// MARK: - Ask and the agent: one box between them

extension AppController {
    /// Ask's windows and the agent. Ask writes in one box: its own window, or the agent's
    /// window while there's an agent conversation, so the two are never up side by side.
    func setUpAsk() {
        // Both modes read LocalFlow's own memory files every time and add to them.
        let memory = FlowMemory()
        memory.ensureFiles()
        ask = AskController(memory: memory, chats: AskChatStore(fileURL: AskChatStore.defaultURL),
                            closeHint: askCloseHint)
        askChats = AskHistoryWindowController(store: ask.chats) { [weak self] id in self?.continueAskChat(id) }
        let composer = AskComposerPanel()
        let panel = AgentPanel()
        agentPanel = panel
        agent = AgentController(surface: panel)
        askSession = AskSession(
            mic: self,
            composer: AskWindows(ask: composer, agent: panel),
            answers: ask,
            transcribe: rawTranscribe,
            canOpen: { [weak self] in self?.askCanOpen() ?? false },
            swallowPress: { [weak self] in self?.askHotkeyMonitor?.swallowCurrentPress() }
        )
        askSession.onTask = { [weak self] task, screen, instant in self?.agent.run(task, on: screen, instant: instant) }
        // Esc closes the Ask window or the answer, from any app, while one is up.
        askSession.onPhaseChange = { [weak self] _ in self?.updateAskEscape() }
        ask.onChange = { [weak self] in self?.updateAskEscape() }
        ask.onOpenChats = { [weak self] in self?.showAskChats() }
        let openChats: () -> Void = { [weak self] in
            self?.askSession.closeKeepingDraft()
            self?.showAskChats()
        }
        let openConnectors: () -> Void = { [weak self] in
            self?.askSession.closeKeepingDraft()
            self?.openSettings(tab: .connectors)
        }
        composer.onOpenChats = openChats
        composer.onOpenConnectors = openConnectors
        panel.onOpenChats = openChats
        panel.onOpenConnectors = openConnectors
        // ⌘ on its own while the agent's window waits in its corner: its box opens there, green.
        panel.onCommandTap = { [weak self] in self?.askSession.openForTyping(agentMode: true) }
        refreshConnectors()
        connectorWatch = ConnectorStore.shared.$connectors.dropFirst().sink { [weak self] _ in
            self?.refreshConnectors()
        }
    }

    /// Readies the connected servers (and their sign-ins) ahead of the next task. A slow
    /// earlier refresh never overwrites a later one.
    private func refreshConnectors() {
        connectorRefreshes += 1
        let refresh = connectorRefreshes
        Task { @MainActor [weak self] in
            let servers = await ConnectorStore.shared.servers()
            guard let self, refresh == self.connectorRefreshes else { return }
            self.agent.connectorServers = servers
        }
    }

    var askKeyName: String {
        AskKeyChoice.effectiveHotkey(ask: settings.askKey, dictation: settings.hotkey)?.shortName ?? "Ask key"
    }

    var askCloseHint: String {
        "Esc to minimize   ·   ⇧Esc to close   ·   \(askKeyName) to ask again"
    }

    func updateAskEscape() {
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

    func configureAskHotkey() {
        // The old monitor's release would never arrive: close an Ask in progress first.
        askSession.cancel()
        askHotkeyMonitor?.stopMonitoring()
        askHotkeyMonitor = nil
        ask.updateCloseHint(askCloseHint)
        askSession.keyName = askKeyName
        let askKey = AskKeyChoice.effectiveHotkey(ask: settings.askKey, dictation: settings.hotkey)
        let modeKeys = CommandTap.keys(askKey: askKey, dictationKey: settings.hotkey)
        askSession.modeKeys = modeKeys
        agentPanel.modeKeys = modeKeys
        agent.setFollowUpHint("⌘ to give it more  ·  \(askKeyName) to ask")
        guard let askKey else { return }
        let monitor = HotkeyMonitor(choice: askKey)
        let now = { ProcessInfo.processInfo.systemUptime }
        monitor.onPressBegan = { [weak self] _ in self?.askKeyDown(at: now()) }
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

    /// The Ask key while the agent's box is open in its corner brings the box home, in
    /// Ask's blue; otherwise it's Ask's as usual.
    private func askKeyDown(at time: TimeInterval) {
        if agentPanel.isTakingInput, agentPanel.isInCorner {
            askHotkeyMonitor?.swallowCurrentPress()
            agentPanel.moveInputHome()
            return
        }
        askSession.keyDown(at: time)
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
}
