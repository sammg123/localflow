import AVFoundation
import Foundation

/// Captures microphone audio and converts it to 16 kHz mono Float32 (what ASR models expect).
/// The engine is prepared at launch so start() is fast; the mic (and its orange indicator)
/// is only live while recording — audio never touches disk.
///
/// Threading: all public methods are main-thread. The tap callback runs on an audio thread
/// and only touches `samples` (lock-guarded) and its own captured converter.
final class AudioRecorder {
    static let targetSampleRate: Double = 16_000
    /// Hands-free safety cap: auto-stop after 5 minutes (~19 MB of samples).
    static let maxDuration: TimeInterval = 300

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var tapInstalled = false
    private var isCapturing = false
    private var limitFired = false
    /// Kept only so start() can reset resampler state left over from the previous recording.
    private var activeConverter: AVAudioConverter?
    private var configChangeObserver: NSObjectProtocol?

    /// Called on an audio thread with a 0...1 mic level, ~10x per second.
    var levelHandler: (@Sendable (Float) -> Void)?
    /// Called on the main thread once if the recording hits maxDuration.
    var limitHandler: (() -> Void)?
    /// Called on the main thread if the input device changed mid-recording and
    /// capture could not be restarted.
    var captureLostHandler: (() -> Void)?

    var isRunning: Bool { engine.isRunning }

    /// Install the tap and pre-allocate. Call after mic permission is granted.
    func prepare() {
        installTapIfNeeded()
        engine.prepare()
        guard configChangeObserver == nil else { return }
        // Fires when the input device changes (AirPods connect, etc.): the tap's format
        // is stale. The notification arrives on an arbitrary thread — hop to main.
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    private func handleConfigurationChange() {
        let wasCapturing = isCapturing
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
            activeConverter = nil
        }
        installTapIfNeeded()
        engine.prepare()
        if wasCapturing {
            // If the tap couldn't reinstall (input format still in flux, device gone),
            // restarting would produce a headless recording that captures nothing.
            guard tapInstalled else {
                isCapturing = false
                captureLostHandler?()
                return
            }
            // Try to keep the in-flight recording alive on the new device.
            do {
                try engine.start()
            } catch {
                isCapturing = false
                captureLostHandler?()
            }
        }
    }

    private func installTapIfNeeded() {
        guard !tapInstalled else { return }
        let input = engine.inputNode
        let hwFormat = input.inputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else { return }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: hwFormat, to: targetFormat) else { return }
        activeConverter = converter

        let maxSamples = Int(Self.targetSampleRate * Self.maxDuration)
        // Tap at the hardware format (mandatory: mismatched formats crash AVAudioEngine).
        // The converter is captured by the closure — the tap thread never reads properties
        // that the main thread mutates.
        input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            self?.process(buffer: buffer, converter: converter, targetFormat: targetFormat, maxSamples: maxSamples)
        }
        tapInstalled = true
    }

    private func process(buffer: AVAudioPCMBuffer, converter: AVAudioConverter, targetFormat: AVAudioFormat, maxSamples: Int) {
        let ratio = Self.targetSampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var fed = false
        var error: NSError?
        converter.convert(to: outBuffer, error: &error) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard error == nil, outBuffer.frameLength > 0, let channel = outBuffer.floatChannelData?[0] else { return }

        let chunk = Array(UnsafeBufferPointer(start: channel, count: Int(outBuffer.frameLength)))
        var hitLimit = false
        lock.lock()
        if samples.count < maxSamples {
            samples.append(contentsOf: chunk)
            if samples.count >= maxSamples { hitLimit = true }
        }
        lock.unlock()

        if hitLimit {
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.limitFired else { return }
                self.limitFired = true
                self.limitHandler?()
            }
        }

        if let levelHandler {
            var sum: Float = 0
            for s in chunk { sum += s * s }
            let rms = sqrt(sum / Float(max(chunk.count, 1)))
            // Map typical speech RMS (~0.005-0.15) onto 0...1 for the HUD meter.
            let level = min(1, max(0, (log10(max(rms, 0.0001)) + 4) / 3.2))
            levelHandler(level)
        }
    }

    func start() throws {
        // prepare(), not bare installTapIfNeeded(): if mic permission arrived after launch
        // via a path that skipped prepare(), the config-change observer must still exist.
        prepare()
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        lock.unlock()
        limitFired = false
        // Engine is stopped here (tap silent), so resetting resampler state is race-free.
        activeConverter?.reset()
        try engine.start()
        isCapturing = true
    }

    /// Stops the mic and returns everything captured, as 16 kHz mono Float32.
    func stop() -> [Float] {
        isCapturing = false
        engine.stop()
        lock.lock()
        let result = samples
        samples = []
        lock.unlock()
        return result
    }

    func cancel() {
        isCapturing = false
        engine.stop()
        lock.lock()
        samples = []
        lock.unlock()
    }

    var capturedDuration: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return Double(samples.count) / Self.targetSampleRate
    }
}
