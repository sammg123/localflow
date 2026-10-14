import AVFoundation
import Foundation
import Speech

/// Apple's on-device SpeechAnalyzer/SpeechTranscriber (macOS 26). No download inside the
/// app bundle — the model lives in system storage and runs out-of-process (zero RAM here).
///
/// Uses the batch path: one big buffer through analyzeSequence(_:). The chunked-streaming
/// path has a known macOS 26.3 bug with pre-recorded audio (FB22149971).
final class AppleSpeechTranscriber: Transcriber {
    private(set) var state: TranscriberState = .notReady
    let displayName = "Apple Speech"

    private var locale: Locale?

    func prepare() async throws {
        guard state != .ready else { return }
        state = .loading

        guard SpeechTranscriber.isAvailable else {
            state = .failed("SpeechTranscriber isn't available on this Mac")
            throw TranscriberError.engineFailure("SpeechTranscriber unavailable")
        }
        // Locales must be compared via bcp47 ("en_US" vs "en-US" silently mismatch).
        var candidate = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
        if candidate == nil {
            candidate = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en_US"))
        }
        guard let resolved = candidate else {
            state = .failed("No supported dictation locale")
            throw TranscriberError.engineFailure("No supported locale")
        }
        locale = resolved

        let transcriber = SpeechTranscriber(locale: resolved, preset: .transcription)
        let installed = Set(await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) })
        if !installed.contains(resolved.identifier(.bcp47)) {
            state = .downloadingModel
            do {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    try await request.downloadAndInstall()
                }
            } catch {
                state = .failed("Model download failed: \(error.localizedDescription)")
                throw error
            }
        }
        state = .ready
    }

    func transcribe(samples: [Float]) async throws -> String {
        guard state == .ready, let locale else { throw TranscriberError.notReady }
        guard !samples.isEmpty else { return "" }

        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)

        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioRecorder.targetSampleRate,
            channels: 1,
            interleaved: false
        ), let pcm = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw TranscriberError.engineFailure("Couldn't allocate audio buffer")
        }
        pcm.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            pcm.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }

        // The analyzer does no conversion itself; always convert to its preferred format —
        // even an interleaving mismatch fails with an opaque nilError.
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscriberError.engineFailure("No compatible analyzer audio format")
        }
        let converted = try Self.convert(pcm, to: analyzerFormat)

        // Subscribe to results BEFORE running analysis; the sequence ends when analysis does.
        async let transcriptFuture = transcriber.results.reduce(into: "") { acc, result in
            acc += String(result.text.characters)
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        continuation.yield(AnalyzerInput(buffer: converted))
        continuation.finish()

        if let lastSampleTime = try await analyzer.analyzeSequence(stream) {
            try await analyzer.finalizeAndFinish(through: lastSampleTime)
        } else {
            await analyzer.cancelAndFinishNow()
        }

        return try await transcriptFuture.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard buffer.format != format else { return buffer }
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else {
            throw TranscriberError.engineFailure("Couldn't create audio converter")
        }
        converter.primeMethod = .none

        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up) + 32)
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw TranscriberError.engineFailure("Couldn't allocate conversion buffer")
        }

        var nsError: NSError?
        var consumed = false
        // .endOfStream (not .noDataNow) after the single buffer: this is a one-shot
        // conversion, and end-of-stream makes the converter flush its resampler tail.
        let status = converter.convert(to: out, error: &nsError) { _, statusPtr in
            defer { consumed = true }
            statusPtr.pointee = consumed ? .endOfStream : .haveData
            return consumed ? nil : buffer
        }
        guard status != .error else {
            throw TranscriberError.engineFailure(nsError?.localizedDescription ?? "Audio conversion failed")
        }
        return out
    }
}
