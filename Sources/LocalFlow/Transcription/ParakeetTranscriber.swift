import FluidAudio
import Foundation

/// NVIDIA Parakeet TDT 0.6B v3 via FluidAudio: CoreML on the Neural Engine.
/// ~483 MB one-time download to ~/Library/Application Support/FluidAudio/Models/,
/// then ~0.2-0.5s per utterance. Doesn't hallucinate on silence (it's a transducer).
final class ParakeetTranscriber: Transcriber {
    private(set) var state: TranscriberState = .notReady
    let displayName = "Parakeet v3"

    /// One manager for the app's lifetime (the loaded model lives here)…
    private var manager: AsrManager?
    private var prepareTask: Task<Void, Error>?

    /// Reentrant-safe: concurrent calls await the same in-flight download/load.
    func prepare() async throws {
        guard state != .ready else { return }
        if let prepareTask {
            try await prepareTask.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            let cacheDir = AsrModels.defaultCacheDirectory(for: .v3)
            let alreadyDownloaded = AsrModels.modelsExist(at: cacheDir, version: .v3, encoderPrecision: .int8)
            self.state = alreadyDownloaded ? .loading : .downloadingModel
            do {
                let models = try await AsrModels.downloadAndLoad(version: .v3)
                self.manager = AsrManager(config: .default, models: models)
                self.state = .ready
            } catch {
                self.state = .failed(error.localizedDescription)
                self.prepareTask = nil // allow a retry after e.g. a network failure
                throw error
            }
        }
        prepareTask = task
        try await task.value
    }

    func transcribe(samples: [Float]) async throws -> String {
        guard state == .ready, let manager else { throw TranscriberError.notReady }

        // Parakeet rejects audio under 300 ms (4800 samples @ 16 kHz); pad with silence.
        var padded = samples
        if padded.count < 4800 {
            padded.append(contentsOf: [Float](repeating: 0, count: 4800 - padded.count))
        }

        // …but a FRESH decoder state per utterance: it carries LSTM state across calls,
        // and reusing it across unrelated utterances biases decoding.
        // (Must be a local var: inout across an actor call.)
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(padded, decoderState: &decoderState)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
