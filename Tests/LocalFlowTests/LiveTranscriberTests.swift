import Foundation
import Testing
@testable import LocalFlow

/// Polls until `condition` holds or the timeout passes.
@MainActor
private func waitUntil(timeout: Duration = .seconds(2), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

/// A growable fake recording that hands out copies of ranges, like AudioRecorder.
@MainActor
private final class FakeRecording {
    var audio: [Float]
    init(seconds: Double) { audio = Self.make(seconds) }
    func append(seconds: Double) { audio += Self.make(seconds) }
    func slice(_ range: Range<Int>) -> [Float] { Array(audio[range]) }
    private static func make(_ seconds: Double) -> [Float] {
        [Float](repeating: 0.1, count: Int(seconds * 16_000))
    }
}

@MainActor
@Suite("LiveTranscriber")
struct LiveTranscriberTests {
    private func makeLive(
        _ recording: FakeRecording,
        maxPassSamples: Int = 25 * 16_000,
        commitSamples: Int = 20 * 16_000,
        transcribe: @escaping ([Float]) async throws -> String,
        onText: @escaping (String) -> Void,
        log: @escaping (String) -> Void = { _ in }
    ) -> LiveTranscriber {
        LiveTranscriber(
            interval: .milliseconds(10),
            minSamples: 8_000,
            maxPassSamples: maxPassSamples,
            commitSamples: commitSamples,
            sampleCount: { recording.audio.count },
            samples: { recording.slice($0) },
            transcribe: transcribe,
            onText: onText,
            log: log
        )
    }

    @Test("shows the latest transcript as audio grows")
    func emitsLatestTranscript() async {
        let recording = FakeRecording(seconds: 1)
        var shown: [String] = []
        let live = makeLive(recording,
                            transcribe: { "words for \($0.count)" },
                            onText: { shown.append($0) })

        live.start()
        #expect(await waitUntil { shown.last == "words for 16000" })
        recording.append(seconds: 1)
        #expect(await waitUntil { shown.last == "words for 32000" })
        live.stop()
    }

    @Test("waits for enough audio before the first pass")
    func skipsShortAudio() async {
        let recording = FakeRecording(seconds: 0.25)
        var calls = 0
        let live = makeLive(recording,
                            transcribe: { _ in calls += 1; return "too early" },
                            onText: { _ in })

        live.start()
        try? await Task.sleep(for: .milliseconds(80))
        live.stop()

        #expect(calls == 0)
    }

    @Test("does not re-transcribe when no new audio arrived")
    func skipsUnchangedAudio() async {
        let recording = FakeRecording(seconds: 1)
        var calls = 0
        let live = makeLive(recording,
                            transcribe: { _ in calls += 1; return "same" },
                            onText: { _ in })

        live.start()
        try? await Task.sleep(for: .milliseconds(100))
        live.stop()

        #expect(calls == 1)
    }

    @Test("long recordings are transcribed in bounded passes and frozen text is kept")
    func boundsPassLength() async {
        // 1 s passes at most; 0.75 s frozen at a time. 3 s of audio = 3 frozen chunks
        // (2.25 s) + a 0.75 s tail.
        let recording = FakeRecording(seconds: 3)
        var passLengths: [Int] = []
        var chunk = 0
        var shown: [String] = []
        let live = makeLive(recording,
                            maxPassSamples: 16_000,
                            commitSamples: 12_000,
                            transcribe: { samples in
                                passLengths.append(samples.count)
                                chunk += 1
                                return "c\(chunk)"
                            },
                            onText: { shown.append($0) })

        live.start()
        #expect(await waitUntil { !shown.isEmpty })
        live.stop()

        #expect(passLengths == [12_000, 12_000, 12_000, 12_000])
        #expect(passLengths.allSatisfy { $0 <= 16_000 })
        #expect(shown.first == "c1 c2 c3 c4")
    }

    @Test("ignores empty results and keeps the last real text")
    func ignoresEmptyResults() async {
        let recording = FakeRecording(seconds: 1)
        var shown: [String] = []
        let live = makeLive(recording,
                            transcribe: { $0.count > 16_000 ? "" : "first words" },
                            onText: { shown.append($0) })

        live.start()
        #expect(await waitUntil { shown == ["first words"] })
        recording.append(seconds: 1)
        try? await Task.sleep(for: .milliseconds(60))
        live.stop()

        #expect(shown == ["first words"])
    }

    @Test("a transcription error does not stop later passes")
    func survivesErrors() async {
        struct Boom: Error {}
        let recording = FakeRecording(seconds: 1)
        var shown: [String] = []
        var logged: [String] = []
        let live = makeLive(recording,
                            transcribe: { samples in
                                if samples.count == 16_000 { throw Boom() }
                                return "recovered"
                            },
                            onText: { shown.append($0) },
                            log: { logged.append($0) })

        live.start()
        #expect(await waitUntil { logged.count == 1 })
        recording.append(seconds: 1)
        #expect(await waitUntil { shown == ["recovered"] })
        live.stop()
        #expect(logged.count == 1)
        #expect(logged.first?.hasPrefix("live pass failed") == true)
    }

    @Test("a pass that finishes after stop shows nothing")
    func stopsCleanly() async {
        // Like the real engine, this pass ignores cancellation: it only returns when
        // released, which happens after stop().
        let recording = FakeRecording(seconds: 1)
        var release: CheckedContinuation<Void, Never>?
        var shown: [String] = []
        let live = makeLive(recording,
                            transcribe: { _ in
                                await withCheckedContinuation { release = $0 }
                                return "late words"
                            },
                            onText: { shown.append($0) })

        live.start()
        #expect(await waitUntil { release != nil })
        live.stop()
        release?.resume()
        try? await Task.sleep(for: .milliseconds(50))

        #expect(shown.isEmpty)
        #expect(live.isRunning == false)
    }
}
