import AppKit
import SwiftUI

enum SettingsTab: String {
    case general, dictionary, connectors, setup
}

/// Shared between the controller and the SwiftUI view so show(tab:) can switch tabs
/// even when the window already exists.
@MainActor
final class SettingsTabState: ObservableObject {
    @Published var tab: SettingsTab = .general
}

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let tabState = SettingsTabState()
    private weak var controller: AppController?

    init(controller: AppController) {
        self.controller = controller
    }

    func show(tab: SettingsTab = .general) {
        tabState.tab = tab
        if window == nil {
            let view = SettingsView(tabState: tabState, controller: controller)
            let hosting = NSHostingController(rootView: view)
            let win = NSWindow(contentViewController: hosting)
            win.title = "LocalFlow Settings"
            win.styleMask = [.titled, .closable, .miniaturizable]
            win.isReleasedWhenClosed = false
            win.setContentSize(NSSize(width: 480, height: 560))
            win.center()
            window = win
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    /// Opens one of the memory files in the user's editor, making it first if it's missing.
    private static func openMemory(_ file: KeyPath<FlowMemory, URL>) {
        let memory = FlowMemory()
        memory.ensureFiles()
        NSWorkspace.shared.open(memory[keyPath: file])
    }

    @ObservedObject var tabState: SettingsTabState
    weak var controller: AppController?
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        TabView(selection: $tabState.tab) {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            dictionaryTab
                .tabItem { Label("Dictionary", systemImage: "character.book.closed") }
                .tag(SettingsTab.dictionary)
            ConnectorsSettingsView()
                .tabItem { Label("Connectors", systemImage: "puzzlepiece.extension") }
                .tag(SettingsTab.connectors)
            setupTab
                .tabItem { Label("Setup", systemImage: "checkmark.shield") }
                .tag(SettingsTab.setup)
        }
        .padding(20)
        .frame(width: 480)
    }

    private var generalTab: some View {
        Form {
            Picker("Push-to-talk key:", selection: $settings.hotkey) {
                ForEach(HotkeyChoice.allCases) { choice in
                    Text(choice.label).tag(choice)
                }
            }
            if settings.hotkey == .fnKey {
                Text("Set System Settings → Keyboard → “Press 🌐 key to” = “Do Nothing”, or macOS will trigger emoji/dictation on top of LocalFlow.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Hold to talk. Double-tap for hands-free: tap to pause and edit, tap again to keep talking, Return pastes. Esc cancels. Tap Control + the key to paste your last dictation again; hold Control + the key to edit selected text by voice.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Double-tap opens the hands-free window (off: the pill, and a tap pastes)", isOn: $settings.liveWindowOnDoubleTap)

            Divider()

            Picker("Ask key:", selection: $settings.askKey) {
                ForEach(AskKeyChoice.allCases) { choice in
                    Text(choice.label).tag(choice)
                }
            }
            if settings.askKey != .off,
               AskKeyChoice.effectiveHotkey(ask: settings.askKey, dictation: settings.hotkey) == nil {
                Text("That's also the push-to-talk key, so Ask is off. Pick a different key.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Picker("Ask answers with:", selection: $settings.askEngine) {
                ForEach(AskEngine.allCases) { engine in
                    Text(engine.label).tag(engine)
                }
            }
            switch settings.askEngine {
            case .local:
                TextField("Ask model:", text: $settings.askModel, prompt: Text(Settings.defaultAskModel))
            case .chatGPT:
                TextField("ChatGPT model:", text: $settings.askCloudModel, prompt: Text(AskEngine.chatGPT.defaultModel))
                Text("Sends the screenshot and your question to OpenAI on your ChatGPT plan, through the Codex tool in the ChatGPT app (signed in with your ChatGPT account). Dictation still stays on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .claude:
                TextField("Claude model:", text: $settings.askClaudeModel, prompt: Text(AskEngine.claude.defaultModel))
                ClaudeAccountRow()
                Text("Sends the screenshot and your question to Anthropic on your Claude plan, through Claude Code with a sign-in that's only for LocalFlow, so it can be a different account from your own Claude Code. Dictation still stays on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Stepper(value: $settings.askMemoryTurns, in: 0...20) {
                Text(settings.askMemoryTurns == 0
                     ? "Follow-ups carry nothing from earlier in the chat"
                     : "Follow-ups carry the chat's last \(settings.askMemoryTurns) questions")
            }
            Text("Tap to type, tap again to talk (and again to stop), or hold to talk while held. Your question shows in the Ask window and nothing is sent until you press Return or the send button. The model picked above reads a screenshot and answers in a bubble; the voice key or ✕ closes it. Every chat is saved on this Mac only, so you can look back through and search them. A chat ends after 30 minutes quiet or when you start a new one.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Agent model:", text: $settings.agentModel, prompt: Text(Settings.defaultAgentModel))
            if settings.askEngine != .claude { ClaudeAccountRow() }
            Text("Tap ⌘ in the Ask window to switch to the agent (green), then Return hands it the task. It uses your Mac like Claude Code: it runs Terminal commands, reads and edits your files, and clicks and types in apps. Looking, reading and safe commands just run; anything that deletes, sends, buys, pushes, installs or uses sudo waits for your OK. ⌘I turns on Instant Edits for small UI changes. It works on your Claude plan through LocalFlow's own Claude sign-in, so screenshots and what it reads go to Anthropic.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Text("Memory:")
                Button("localflow.md") { Self.openMemory(\.instructionsURL) }
                Button("flow-memory.md") { Self.openMemory(\.memoryURL) }
            }
            Text("What Ask and the agent remember. localflow.md holds your standing instructions, like a CLAUDE.md of LocalFlow's own; flow-memory.md holds what they learn, like your projects and where they live. Both are read with every question and task, and added to when you say how you like things or when they work out which project you're in. They stay on this Mac, and go with each question to the model you picked.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Always allow", isOn: $settings.agentAlwaysAllow)
            Text(settings.agentAlwaysAllow
                 ? "Everything the agent does runs without asking, including deleting, sending, buying, pushing and sudo. Turn this off to approve risky steps again."
                 : "Risky steps wait for your OK. Turn this on to let the agent do everything without asking.")
                .font(.caption)
                .foregroundStyle(settings.agentAlwaysAllow ? Color.orange : .secondary)
            InstantProjectsSettingsView()

            Divider()

            Picker("Speech engine:", selection: $settings.engine) {
                ForEach(EngineChoice.allCases) { engine in
                    Text(engine.label).tag(engine)
                }
            }
            Text("Engine changes apply to the next dictation. Parakeet downloads ~500 MB once, then runs on the Neural Engine.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Picker("AI cleanup:", selection: $settings.polishMode) {
                ForEach(PolishMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            Stepper(value: $settings.polishMinWords, in: 0...30) {
                Text("Skip AI cleanup under \(settings.polishMinWords) words")
            }
            Toggle("Match tone to the target app", isOn: $settings.toneMatching)
            Toggle("Spoken “new line” / “new paragraph” commands", isOn: $settings.spokenCommands)

            Divider()

            Toggle("Sounds", isOn: $settings.soundsEnabled)
            Toggle("Save history to disk", isOn: $settings.saveHistoryToDisk)
            Text("Off = history lives only in memory and vanishes on quit.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
        .onChange(of: settings.hotkey) { _, newValue in
            controller?.hotkeyChanged(to: newValue)
        }
        .onChange(of: settings.askKey) { _, _ in
            controller?.askKeyChanged()
        }
        .onChange(of: settings.engine) { _, _ in
            controller?.engineChanged()
        }
        .onChange(of: settings.saveHistoryToDisk) { _, _ in
            controller?.history.persistIfEnabled()
        }
    }

    @State private var dictionaryText = Settings.shared.dictionaryWords.joined(separator: "\n")
    @State private var replacementsText = Settings.shared.replacements
        .map { "\($0.key) -> \($0.value)" }.sorted().joined(separator: "\n")

    private var dictionaryTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Personal dictionary — one name/term per line. The AI pass will spell these exactly.")
                .font(.caption)
            TextEditor(text: $dictionaryText)
                .font(.system(.body, design: .monospaced))
                .frame(height: 110)
                .onChange(of: dictionaryText) { _, newValue in
                    Settings.shared.dictionaryWords = newValue
                        .split(separator: "\n")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                }

            Text("Replacements — “wrong -> right”, one per line, applied to every dictation.")
                .font(.caption)
            TextEditor(text: $replacementsText)
                .font(.system(.body, design: .monospaced))
                .frame(height: 110)
                .onChange(of: replacementsText) { _, newValue in
                    var map: [String: String] = [:]
                    for line in newValue.split(separator: "\n") {
                        let parts = line.components(separatedBy: "->")
                        guard parts.count == 2 else { continue }
                        let wrong = parts[0].trimmingCharacters(in: .whitespaces)
                        let right = parts[1].trimmingCharacters(in: .whitespaces)
                        if !wrong.isEmpty { map[wrong] = right }
                    }
                    Settings.shared.replacements = map
                }
        }
        .padding(.vertical, 8)
    }

    private var setupTab: some View {
        SetupView(controller: controller)
    }
}

/// Live permission checklist. Polls only while the view is actually on screen.
struct SetupView: View {
    weak var controller: AppController?
    @State private var micOK = Permissions.microphoneGranted
    @State private var axOK = Permissions.accessibilityGranted
    @State private var screenOK = Permissions.screenRecordingGranted
    @State private var pollTimer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("LocalFlow needs two permissions — the same two Wispr Flow uses. Nothing ever leaves this Mac.")
                .font(.callout)

            permissionRow(
                granted: micOK,
                title: "Microphone",
                detail: "To hear you while the hotkey is held.",
                action: {
                    Task {
                        _ = await Permissions.requestMicrophone()
                        micOK = Permissions.microphoneGranted
                        if !micOK { Permissions.openMicrophoneSettings() }
                    }
                }
            )
            permissionRow(
                granted: axOK,
                title: "Accessibility",
                detail: "To detect the hotkey and paste text into the focused app.",
                action: {
                    Permissions.promptAccessibility()
                    Permissions.openAccessibilitySettings()
                }
            )

            permissionRow(
                granted: screenOK,
                title: "Screen Recording (for Ask)",
                detail: "Lets Ask see your screen when you send it a question. Optional.",
                action: { Permissions.requestScreenRecording() }
            )

            if micOK && axOK {
                Label("All set. Hold your hotkey and speak.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            Spacer()
        }
        .padding(.vertical, 8)
        .onAppear { startPolling() }
        .onDisappear { stopPolling() }
    }

    private func startPolling() {
        refresh()
        stopPolling()
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            Task { @MainActor in refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func refresh() {
        micOK = Permissions.microphoneGranted
        axOK = Permissions.accessibilityGranted
        screenOK = Permissions.screenRecordingGranted
        controller?.permissionsMayHaveChanged()
    }

    private func permissionRow(granted: Bool, title: String, detail: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? .green : .secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("Grant…", action: action)
            }
        }
    }
}
