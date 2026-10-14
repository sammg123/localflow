import Foundation

/// Transcribes the recording-so-far on a short interval so words can appear while the
/// user is still talking. One pass at a time: a slow pass just means fewer updates,
/// never a queue of stale ones. The final paste does NOT use this text; it comes from
/// one clean pass over the full recording.
///
/// Passes are bounded. Once the untranscribed tail grows past `maxPassSamples`, its
/// first `commitSamples` are transcribed once and frozen, so a pass at minute four
/// costs the same as one at second four, and the final pass never queues behind a
/// long live pass on the shared speech model.
@MainActor
final class LiveTranscriber {
    private let interval: Duration
    private let minSamples: Int
    private let maxPassSamples: Int
    private let commitSamples: Int
    private let sampleCount: () -> Int
    private let samples: (Range<Int>) -> [Float]
    private let transcribe: ([Float]) async throws -> String
    private let onText: (String) -> Void
    private let log: (String) -> Void

    private var loop: Task<Void, Never>?

    var isRunning: Bool { loop != nil }

    /// - Parameters:
    ///   - minSamples: audio needed before a pass (8 000 = 0.5 s at 16 kHz).
    ///   - maxPassSamples: the most audio one pass may cover (default 25 s).
    ///   - commitSamples: how much audio gets frozen when that limit is hit (default 20 s).
    ///   - sampleCount: how much audio has been captured so far.
    ///   - samples: a copy of the requested range of the recording.
    ///   - onText: called on the main actor with each non-empty transcript.
    init(interval: Duration = .milliseconds(600),
         minSamples: Int = 8_000,
         maxPassSamples: Int = 25 * 16_000,
         commitSamples: Int = 20 * 16_000,
         sampleCount: @escaping () -> Int,
         samples: @escaping (Range<Int>) -> [Float],
         transcribe: @escaping ([Float]) async throws -> String,
         onText: @escaping (String) -> Void,
         log: @escaping (String) -> Void = { FlowLog.shared.write($0) }) {
        precondition(commitSamples > 0 && commitSamples <= maxPassSamples)
        self.interval = interval
        self.minSamples = minSamples
        self.maxPassSamples = maxPassSamples
        self.commitSamples = commitSamples
        self.sampleCount = sampleCount
        self.samples = samples
        self.transcribe = transcribe
        self.onText = onText
        self.log = log
    }

    func start() {
        stop()
        loop = Task { [weak self] in
            var committedText = ""
            var committedCount = 0
            var transcribedCount = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.interval ?? .milliseconds(600))
                guard let self, !Task.isCancelled else { return }
                let total = self.sampleCount()
                guard total >= self.minSamples, total != transcribedCount else { continue }
                transcribedCount = total
                do {
                    while total - committedCount > self.maxPassSamples {
                        let end = committedCount + self.commitSamples
                        let frozen = try await self.transcribe(self.samples(committedCount..<end))
                        guard !Task.isCancelled else { return }
                        committedText = Self.join(committedText, frozen)
                        committedCount = end
                    }
                    let tail = self.samples(committedCount..<total)
                    let tailText = tail.count >= self.minSamples ? try await self.transcribe(tail) : ""
                    guard !Task.isCancelled else { return }
                    let shown = Self.join(committedText, tailText)
                    if !shown.isEmpty { self.onText(shown) }
                } catch {
                    // A failed preview pass is not worth interrupting the user for: the
                    // final pass over the full recording is what gets pasted.
                    guard !Task.isCancelled else { return }
                    self.log("live pass failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    private static func join(_ a: String, _ b: String) -> String {
        let a = a.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = b.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + " " + b
    }
}
