import Foundation

enum TranscriberState: Equatable {
    case notReady
    case downloadingModel
    case loading
    case ready
    case failed(String)
}

/// A local speech-to-text engine. Input is always 16 kHz mono Float32 samples.
protocol Transcriber: AnyObject {
    var state: TranscriberState { get }
    var displayName: String { get }

    /// Download (first run) and load the model into memory. Safe to call repeatedly.
    func prepare() async throws

    /// Transcribe a complete utterance. Returns plain text (may be empty for silence).
    func transcribe(samples: [Float]) async throws -> String
}

enum TranscriberError: LocalizedError {
    case notReady
    case engineFailure(String)

    var errorDescription: String? {
        switch self {
        case .notReady: return "The speech model is not loaded yet"
        case .engineFailure(let message): return message
        }
    }
}
