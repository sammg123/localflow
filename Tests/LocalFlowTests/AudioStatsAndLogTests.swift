import Foundation
import Testing
@testable import LocalFlow

@Suite("AudioStats")
struct AudioStatsTests {
    @Test("peak of no audio is zero")
    func emptyPeak() {
        #expect(AudioStats.peak([]) == 0)
    }

    @Test("peak uses the loudest sample in either direction")
    func peakIsAbsolute() {
        #expect(AudioStats.peak([0.1, -0.6, 0.3]) == 0.6)
    }

    @Test("near-zero audio counts as silence")
    func detectsSilence() {
        let hiss = (0..<16_000).map { i in Float(i % 2 == 0 ? 0.0004 : -0.0004) }
        #expect(AudioStats.isSilent(hiss))
        #expect(AudioStats.isSilent([]))
    }

    @Test("speech-level audio is not silence")
    func speechIsNotSilent() {
        let speech = (0..<16_000).map { i in Float(sin(Double(i) / 8) * 0.2) }
        #expect(!AudioStats.isSilent(speech))
    }
}

@Suite("FlowLog")
struct FlowLogTests {
    private func tempLogURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("localflow-log-\(UUID().uuidString).log")
    }

    @Test("appends timestamped lines")
    func appendsLines() throws {
        let url = tempLogURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let log = FlowLog(url: url, maxBytes: 10_000)

        log.write("recording started")
        log.write("recording stopped")

        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].hasSuffix("recording started"))
        #expect(lines[1].hasSuffix("recording stopped"))
    }

    @Test("starts over when the file grows past the cap")
    func rotatesWhenFull() throws {
        let url = tempLogURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let log = FlowLog(url: url, maxBytes: 200)

        for i in 0..<40 { log.write("line \(i) with some padding text") }

        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
        #expect(size <= 200)
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        #expect(lines.last?.hasSuffix("line 39 with some padding text") == true)
        #expect(lines.first?.hasSuffix("line 0 with some padding text") == false)
    }
}

@Suite("Privacy")
struct LogPrivacyTests {
    /// The log must never carry what the user said. Every log call in the app is
    /// checked for interpolating a transcript-bearing variable.
    @Test("no log call interpolates transcript text")
    func logCallsCarryNoTranscript() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/LocalFlow")
        let files = try FileManager.default.subpathsOfDirectory(atPath: sources.path)
            .filter { $0.hasSuffix(".swift") }
        #expect(!files.isEmpty)
        let banned = ["\\(raw)", "\\(text)", "\\(preCleaned)", "\\(polished)", "\\(transcript",
                      "\\(selection)", "\\(instruction)", "\\(transformed)", "\\(frozen)", "\\(tailText)", "\\(shown)"]
        var logCalls = 0
        for file in files {
            let code = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            for line in code.split(separator: "\n") where line.contains("FlowLog.shared.write(") || line.contains("self.log(") {
                logCalls += 1
                for token in banned {
                    #expect(!line.contains(token), "\(file): \(line)")
                }
            }
        }
        #expect(logCalls > 5)
    }
}
