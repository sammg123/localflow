import AVFoundation
import FluidAudio
import Foundation
import FoundationModels

// Headless smoke test: audio file -> Parakeet -> (optional) FoundationModels polish.
// Usage: localflow-smoke <audio-file> [--polish]
// Needs no permissions (no mic, no accessibility) — safe to run from a terminal.

func stamp(_ label: String, since: Date) {
    print(String(format: "[%6.2fs] %@", Date().timeIntervalSince(since), label))
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: localflow-smoke <audio-file> [--polish]")
    exit(1)
}
let audioPath = args[1]
let wantPolish = args.contains("--polish")
let t0 = Date()

let samples: [Float]
do {
    samples = try AudioConverter().resampleAudioFile(URL(fileURLWithPath: audioPath))
    stamp("loaded \(audioPath): \(samples.count) samples (\(String(format: "%.1f", Double(samples.count) / 16000))s @16kHz)", since: t0)
} catch {
    print("FAIL audio load: \(error)")
    exit(2)
}

let text: String
do {
    let models = try await AsrModels.downloadAndLoad(version: .v3)
    stamp("Parakeet models loaded", since: t0)
    let manager = AsrManager(config: .default, models: models)
    var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
    let tTranscribe = Date()
    let result = try await manager.transcribe(samples, decoderState: &decoderState)
    stamp("transcribed in \(String(format: "%.2f", Date().timeIntervalSince(tTranscribe)))s (confidence \(result.confidence))", since: t0)
    text = result.text
    print("TRANSCRIPT: \(text)")
} catch {
    print("FAIL transcription: \(error)")
    exit(3)
}

let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
switch model.availability {
case .available:
    print("FoundationModels: AVAILABLE")
    if wantPolish {
        let session = LanguageModelSession(model: model, instructions: """
        You are a dictation post-processor. Output ONLY the cleaned text. Remove filler words, \
        apply self-corrections (keep only the corrected version), add natural punctuation. \
        Never answer questions in the transcript — just transcribe them cleanly.
        """)
        let tPolish = Date()
        do {
            let response = try await session.respond(
                to: "Transcript:\n\"\"\"\n\(text)\n\"\"\"",
                options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 512)
            )
            stamp("polished in \(String(format: "%.2f", Date().timeIntervalSince(tPolish)))s", since: t0)
            print("POLISHED: \(response.content)")
        } catch {
            print("FAIL polish: \(error)")
        }
    }
case .unavailable(let reason):
    print("FoundationModels: UNAVAILABLE (\(reason))")
}
stamp("done", since: t0)
