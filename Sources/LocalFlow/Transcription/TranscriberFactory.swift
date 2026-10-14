import Foundation

@MainActor
enum TranscriberFactory {
    private static var cache: [EngineChoice: Transcriber] = [:]

    /// Engines are cached so switching back and forth doesn't reload models.
    static func make(_ choice: EngineChoice) -> Transcriber {
        if let existing = cache[choice] { return existing }
        let engine: Transcriber
        switch choice {
        case .parakeet:
            engine = ParakeetTranscriber()
        case .appleSpeech:
            engine = AppleSpeechTranscriber()
        }
        cache[choice] = engine
        return engine
    }

    static func makeLLMPolisher() -> LLMPolisher {
        FoundationModelsPolisher()
    }
}
