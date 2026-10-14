import AppKit
import AVFoundation
import CoreAudio
import Foundation

/// Captures microphone audio and converts it to 16 kHz mono Float32 (what ASR models expect).
/// The engine is prepared at launch so start() is fast; the mic (and its orange indicator)
/// is only live while recording — audio never touches disk.
///
/// Threading: all public methods are main-thread. The tap callback runs on an audio thread
/// and only touches `samples` (lock-guarded) and its own captured converter.
///
/// Self-healing: AVAudioEngine can go quiet without throwing (after sleep, or when the
/// default input changes while it is stopped, its tap keeps a stale format and simply
/// never fires). So the engine is rebuilt from scratch on wake and on input changes,
/// and a watchdog restarts capture if no audio arrives shortly after start.
final class AudioRecorder {
    enum RecorderError: LocalizedError {
        case noInput
        var errorDescription: String? { "No microphone input is available" }
    }

    static let targetSampleRate: Double = 16_000
    /// Hands-free safety cap: auto-stop after 5 minutes (~19 MB of samples).
    static let maxDuration: TimeInterval = 300

    private var engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var tapInstalled = false
    private var isCapturing = false
    private var limitFired = false
    /// Kept only so start() can reset resampler state left over from the previous recording.
    private var activeConverter: AVAudioConverter?
    private var configChangeObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var defaultInputListener: AudioObjectPropertyListenerBlock?
    /// Set when the input changed or the Mac woke mid-recording; the next start rebuilds.
    private var needsRebuild = false
    /// Tap callbacks since the last start(), so the watchdog can spot a silent engine.
    private var buffersSinceStart = 0
    private var watchdogGeneration = 0
    private var buffersAtLastCheck = 0
    private var stallRestartsLeft = 0
    private var startedAt: TimeInterval = 0
    /// True when the last stop() came back empty because the engine never delivered
    /// audio (as opposed to the user stopping a healthy recording within a few ms).
    private(set) var lastStopWasStalled = false

    /// Buffers arrive roughly every 85 ms; a second without one means capture stalled.
    static let stallCheckInterval: TimeInterval = 1.0
    static let maxStallRestarts = 1

    /// How long after (re)start the first buffer may take. Bluetooth headsets need
    /// a couple of seconds to switch into their microphone mode.
    private static var firstBufferDeadline: TimeInterval {
        defaultInputIsBluetooth ? 3.0 : 1.0
    }

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
        observeSystemChanges()
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

    /// Name of the current default input, for logs and "heard silence" messages.
    static var currentInputName: String {
        AVCaptureDevice.default(for: .audio)?.localizedName ?? "unknown input"
    }

    /// Throw away the engine and build a fresh one. Cheap (tens of ms) and the only
    /// reliable cure for an engine whose tap stopped delivering.
    func rebuild(reason: String) {
        FlowLog.shared.write("audio engine rebuilt (\(reason)), input: \(Self.currentInputName)")
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        activeConverter = nil
        engine = AVAudioEngine()
        needsRebuild = false
        prepare()
    }

    private func observeSystemChanges() {
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                self?.systemAudioChanged(reason: "woke from sleep")
            }
        }
        if defaultInputListener == nil {
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.systemAudioChanged(reason: "default input changed")
            }
            var address = Self.defaultInputAddress
            let status = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
            if status == noErr {
                defaultInputListener = listener
            } else {
                FlowLog.shared.write("could not watch the default input (OSStatus \(status))")
            }
        }
    }

    private static var defaultInputIsBluetooth: Bool {
        var address = defaultInputAddress
        var deviceID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                         0, nil, &size, &deviceID) == noErr else { return false }
        var transportAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &transportAddress, 0, nil, &size, &transport) == noErr
        else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    private static var defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private func systemAudioChanged(reason: String) {
        if isCapturing {
            // The in-flight recording is handled by the configuration-change path; just
            // make sure the next one starts on a clean engine.
            needsRebuild = true
            FlowLog.shared.write("\(reason) while recording; will rebuild on next start")
        } else {
            rebuild(reason: reason)
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
        buffersSinceStart += 1
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
        if needsRebuild || !tapInstalled {
            rebuild(reason: needsRebuild ? "pending input change" : "no input tap")
        }
        guard tapInstalled else { throw RecorderError.noInput }
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        buffersSinceStart = 0
        lock.unlock()
        limitFired = false
        // Engine is stopped here (tap silent), so resetting resampler state is race-free.
        activeConverter?.reset()
        do {
            try engine.start()
        } catch {
            FlowLog.shared.write("engine start failed: \(error.localizedDescription)")
            rebuild(reason: "start failed")
            guard tapInstalled else { throw RecorderError.noInput }
            try engine.start()
        }
        isCapturing = true
        startedAt = ProcessInfo.processInfo.systemUptime
        buffersAtLastCheck = 0
        stallRestartsLeft = Self.maxStallRestarts
        scheduleHealthCheck(after: Self.firstBufferDeadline)
    }

    /// Runs for the whole recording: if the buffer count stops moving (wedged at start,
    /// or the input died mid-recording without a configuration-change notification),
    /// rebuild and restart once, keeping what was already captured; if it stalls again,
    /// hand off to captureLostHandler so the user is told instead of talking into nothing.
    private func scheduleHealthCheck(after delay: TimeInterval) {
        watchdogGeneration += 1
        let generation = watchdogGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isCapturing, generation == self.watchdogGeneration else { return }
            self.lock.lock()
            let buffers = self.buffersSinceStart
            self.lock.unlock()
            if buffers > self.buffersAtLastCheck {
                self.buffersAtLastCheck = buffers
                self.scheduleHealthCheck(after: Self.stallCheckInterval)
            } else {
                self.recoverStalledCapture(neverStarted: buffers == 0)
            }
        }
    }

    private func recoverStalledCapture(neverStarted: Bool) {
        let what = neverStarted ? "no audio after start" : "audio stopped mid-recording"
        guard stallRestartsLeft > 0 else {
            FlowLog.shared.write("\(what) again after a restart; giving up, input: \(Self.currentInputName)")
            isCapturing = false
            engine.stop()
            captureLostHandler?()
            return
        }
        stallRestartsLeft -= 1
        rebuild(reason: what)
        do {
            guard tapInstalled else { throw RecorderError.noInput }
            try engine.start()
            scheduleHealthCheck(after: Self.firstBufferDeadline)
        } catch {
            FlowLog.shared.write("restart failed: \(error.localizedDescription)")
            isCapturing = false
            captureLostHandler?()
        }
    }

    /// How many samples have been captured so far (live transcription).
    var capturedSampleCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return samples.count
    }

    /// A copy of part of the recording so far, without stopping. Only the requested
    /// range is copied, so live passes don't duplicate minutes of audio every tick.
    func samples(in range: Range<Int>) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let lower = min(max(range.lowerBound, 0), samples.count)
        let upper = min(max(range.upperBound, lower), samples.count)
        return Array(samples[lower..<upper])
    }

    /// Stops the mic and returns everything captured, as 16 kHz mono Float32.
    func stop() -> [Float] {
        isCapturing = false
        watchdogGeneration += 1
        engine.stop()
        lock.lock()
        lastStopWasStalled = buffersSinceStart == 0
            && ProcessInfo.processInfo.systemUptime - startedAt >= 0.5
        let result = samples
        samples = []
        lock.unlock()
        return result
    }

    func cancel() {
        isCapturing = false
        watchdogGeneration += 1
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
