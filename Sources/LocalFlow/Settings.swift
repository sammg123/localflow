import Foundation
import Combine

enum HotkeyChoice: String, CaseIterable, Identifiable {
    case rightOption
    case fnKey
    case rightCommand
    case controlOption

    var id: String { rawValue }

    var label: String {
        switch self {
        case .rightOption: return "Right Option (⌥)"
        case .fnKey: return "Fn / Globe (🌐)"
        case .rightCommand: return "Right Command (⌘)"
        case .controlOption: return "Control + Option (⌃⌥)"
        }
    }

    /// For "Control + <key>" hints. Nil when the hotkey already includes Control.
    var shortName: String? {
        switch self {
        case .rightOption: return "Right ⌥"
        case .fnKey: return "Fn"
        case .rightCommand: return "Right ⌘"
        case .controlOption: return nil
        }
    }
}

/// Which model answers Ask.
enum AskEngine: String, CaseIterable, Identifiable {
    /// A vision model in Ollama on this Mac. Nothing leaves it.
    case local
    /// ChatGPT on the user's own plan, through the Codex tool in the ChatGPT app.
    case chatGPT
    /// Claude on the user's own plan, through Claude Code signed in just for LocalFlow.
    case claude

    var id: String { rawValue }

    var label: String {
        switch self {
        case .local: return "Local model (Ollama)"
        case .chatGPT: return "ChatGPT (your subscription)"
        case .claude: return "Claude (your Claude plan)"
        }
    }

    var defaultModel: String {
        switch self {
        case .local: return "qwen3.5:9b"
        case .chatGPT: return "gpt-6-sol"
        case .claude: return "claude-sonnet-5-5"
        }
    }
}

/// The key held to ask a question about the screen. Separate from the dictation key.
enum AskKeyChoice: String, CaseIterable, Identifiable {
    case rightOption
    case rightCommand
    case off

    var id: String { rawValue }

    var label: String {
        switch self {
        case .rightOption: return "Right Option (⌥)"
        case .rightCommand: return "Right Command (⌘)"
        case .off: return "Off"
        }
    }

    var hotkey: HotkeyChoice? {
        switch self {
        case .rightOption: return .rightOption
        case .rightCommand: return .rightCommand
        case .off: return nil
        }
    }

    /// The key to listen on, or nil when Ask is off or would collide with dictation.
    static func effectiveHotkey(ask: AskKeyChoice, dictation: HotkeyChoice) -> HotkeyChoice? {
        guard let key = ask.hotkey, key != dictation else { return nil }
        return key
    }
}

enum PolishMode: String, CaseIterable, Identifiable {
    case appleIntelligence // FoundationModels on-device LLM + rules
    case rulesOnly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .appleIntelligence: return "Apple on-device AI + rules"
        case .rulesOnly: return "Rules only (fastest)"
        }
    }
}

enum EngineChoice: String, CaseIterable, Identifiable {
    case parakeet    // NVIDIA Parakeet TDT 0.6B v3 via FluidAudio (CoreML/ANE)
    case appleSpeech // Apple SpeechAnalyzer (macOS 26, on-device)

    var id: String { rawValue }

    var label: String {
        switch self {
        case .parakeet: return "Parakeet v3 (recommended)"
        case .appleSpeech: return "Apple Speech (no download)"
        }
    }
}

@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    @Published var hotkey: HotkeyChoice {
        didSet { defaults.set(hotkey.rawValue, forKey: "hotkey") }
    }
    @Published var engine: EngineChoice {
        didSet { defaults.set(engine.rawValue, forKey: "engine") }
    }
    @Published var polishMode: PolishMode {
        didSet { defaults.set(polishMode.rawValue, forKey: "polishMode") }
    }
    /// Utterances with fewer words than this skip the LLM pass (ASR output is already punctuated).
    @Published var polishMinWords: Int {
        didSet { defaults.set(polishMinWords, forKey: "polishMinWords") }
    }
    @Published var soundsEnabled: Bool {
        didSet { defaults.set(soundsEnabled, forKey: "soundsEnabled") }
    }
    /// Personal dictionary: names/jargon the AI pass should respect and prefer.
    @Published var dictionaryWords: [String] {
        didSet { defaults.set(dictionaryWords, forKey: "dictionaryWords") }
    }
    /// Deterministic post-ASR replacements, applied case-insensitively ("gonna" -> "going to").
    @Published var replacements: [String: String] {
        didSet { defaults.set(replacements, forKey: "replacements") }
    }
    /// Match per-app tone (drop trailing period in messaging apps, plain text in code editors).
    @Published var toneMatching: Bool {
        didSet { defaults.set(toneMatching, forKey: "toneMatching") }
    }
    /// Spoken "new line"/"new paragraph" commands. Off by default: they can misfire on
    /// dictation that legitimately contains those phrases.
    @Published var spokenCommands: Bool {
        didSet { defaults.set(spokenCommands, forKey: "spokenCommands") }
    }
    /// Double-tap opens the big live-transcript window instead of the small pill.
    @Published var liveWindowOnDoubleTap: Bool {
        didSet { defaults.set(liveWindowOnDoubleTap, forKey: "liveWindowOnDoubleTap") }
    }
    /// Persist dictation history to disk (off by default: privacy-first).
    @Published var saveHistoryToDisk: Bool {
        didSet { defaults.set(saveHistoryToDisk, forKey: "saveHistoryToDisk") }
    }
    /// Hold this key to ask the local vision model about the screen.
    @Published var askKey: AskKeyChoice {
        didSet { defaults.set(askKey.rawValue, forKey: "askKey") }
    }
    /// Ask remembers this many recent questions and answers for follow-ups; older ones
    /// are forgotten. 0 = every question starts fresh.
    @Published var askMemoryTurns: Int {
        didSet { defaults.set(askMemoryTurns, forKey: "askMemoryTurns") }
    }
    @Published var askEngine: AskEngine {
        didSet { defaults.set(askEngine.rawValue, forKey: "askEngine") }
    }
    /// Ollama model tag Ask uses. Must be a vision model.
    @Published var askModel: String {
        didSet { defaults.set(askModel, forKey: "askModel") }
    }
    /// ChatGPT model Ask uses when it answers through ChatGPT.
    @Published var askCloudModel: String {
        didSet { defaults.set(askCloudModel, forKey: "askCloudModel") }
    }

    /// Claude model Ask uses when it answers through Claude.
    @Published var askClaudeModel: String {
        didSet { defaults.set(askClaudeModel, forKey: "askClaudeModel") }
    }

    static let defaultAskModel = AskEngine.local.defaultModel

    /// The model to send for the chosen engine, falling back to its default if the field
    /// was cleared.
    var effectiveAskModel: String {
        let typed: String
        switch askEngine {
        case .local: typed = askModel
        case .chatGPT: typed = askCloudModel
        case .claude: typed = askClaudeModel
        }
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? askEngine.defaultModel : trimmed
    }

    private init() {
        hotkey = HotkeyChoice(rawValue: defaults.string(forKey: "hotkey") ?? "") ?? .fnKey
        engine = EngineChoice(rawValue: defaults.string(forKey: "engine") ?? "") ?? .parakeet
        polishMode = PolishMode(rawValue: defaults.string(forKey: "polishMode") ?? "") ?? .appleIntelligence
        // Default 12: on an 8GB M2 the on-device LLM adds ~2-4s, worth it only for longer dictations.
        polishMinWords = defaults.object(forKey: "polishMinWords") as? Int ?? 12
        soundsEnabled = defaults.object(forKey: "soundsEnabled") as? Bool ?? true
        dictionaryWords = defaults.stringArray(forKey: "dictionaryWords") ?? []
        replacements = defaults.dictionary(forKey: "replacements") as? [String: String] ?? [:]
        toneMatching = defaults.object(forKey: "toneMatching") as? Bool ?? true
        spokenCommands = defaults.object(forKey: "spokenCommands") as? Bool ?? false
        saveHistoryToDisk = defaults.object(forKey: "saveHistoryToDisk") as? Bool ?? false
        liveWindowOnDoubleTap = defaults.object(forKey: "liveWindowOnDoubleTap") as? Bool ?? true
        askKey = AskKeyChoice(rawValue: defaults.string(forKey: "askKey") ?? "") ?? .rightOption
        askEngine = AskEngine(rawValue: defaults.string(forKey: "askEngine") ?? "") ?? .local
        askModel = defaults.string(forKey: "askModel") ?? Self.defaultAskModel
        askCloudModel = defaults.string(forKey: "askCloudModel") ?? AskEngine.chatGPT.defaultModel
        askClaudeModel = defaults.string(forKey: "askClaudeModel") ?? AskEngine.claude.defaultModel
        askMemoryTurns = defaults.object(forKey: "askMemoryTurns") as? Int ?? 5
    }
}
