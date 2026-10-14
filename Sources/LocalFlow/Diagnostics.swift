import Foundation

/// Cheap checks on captured audio, used to tell "the mic heard nothing" apart from
/// "the model heard nothing worth typing".
enum AudioStats {
    /// Below this peak (about -54 dBFS) a recording is room noise at most: a dead or
    /// muted input, or the wrong device. Speech into a working mic peaks far above it.
    static let silencePeak: Float = 0.002

    static func peak(_ samples: [Float]) -> Float {
        samples.reduce(0) { max($0, abs($1)) }
    }

    static func isSilent(_ samples: [Float]) -> Bool {
        peak(samples) < silencePeak
    }
}

/// Plain-text event log at ~/Library/Logs/LocalFlow.log, so a dictation that "just
/// didn't work" leaves a trail. Never write transcript text here: lengths, timings,
/// device names and states only.
final class FlowLog: @unchecked Sendable {
    static let shared = FlowLog(
        url: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/LocalFlow.log"),
        maxBytes: 1_000_000
    )

    private let url: URL
    private let maxBytes: Int
    private let lock = NSLock()
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        return f
    }()

    init(url: URL, maxBytes: Int) {
        self.url = url
        self.maxBytes = maxBytes
    }

    func write(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        // Start over rather than rotate: the log only needs to cover recent failures.
        if size == 0 || size + data.count > maxBytes {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
