import Foundation
import FoundationModels

/// Transcript cleanup via Apple's on-device ~3B model (FoundationModels, macOS 26).
/// Zero download, zero app RAM: the model is managed by the OS.
///
/// Each dictation gets a FRESH session: the 4,096-token context window is shared across
/// a session's whole transcript, so reusing one session would eventually overflow it.
/// prewarm() builds the next session while the user is still speaking.
@MainActor
final class FoundationModelsPolisher: LLMPolisher {
    // Permissive guardrails are designed for exactly this: text-to-text transformation.
    // With plain String output this never throws guardrailViolation (refusals can still
    // come back AS the string — PromptBuilder.validated catches those).
    private let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
    private var pendingSession: LanguageModelSession?

    var isAvailable: Bool {
        model.availability == .available
    }

    var unavailableReason: String? {
        switch model.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "This Mac doesn't support Apple Intelligence"
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Apple Intelligence is off (System Settings → Apple Intelligence & Siri)"
        case .unavailable(.modelNotReady):
            return "Apple Intelligence model still downloading"
        case .unavailable(let reason):
            return "Apple Intelligence unavailable: \(reason)"
        }
    }

    func prewarm() {
        guard isAvailable else { return }
        if pendingSession == nil || pendingSession?.isResponding == true {
            pendingSession = LanguageModelSession(model: model, instructions: PromptBuilder.systemInstructions)
        }
        pendingSession?.prewarm()
    }

    func polish(transcript: String, category: AppCategory, appName: String, dictionary: [String]) async -> String? {
        guard isAvailable else { return nil }

        let session: LanguageModelSession
        if let pending = pendingSession, !pending.isResponding {
            session = pending
        } else {
            session = LanguageModelSession(model: model, instructions: PromptBuilder.systemInstructions)
        }
        pendingSession = nil

        // The 4,096-token window covers instructions (~350 tokens) + prompt scaffolding
        // (~150) + transcript + the RESPONSE (≈ transcript again). At ~3.5 chars/token,
        // the transcript's share is roughly (4096 - 500) / 2 tokens ≈ 6,000 characters.
        guard transcript.count < 6_000 else { return nil }

        let prompt = PromptBuilder.userPrompt(
            transcript: transcript, category: category, appName: appName, dictionary: dictionary
        )
        let options = GenerationOptions(
            sampling: .greedy, // deterministic cleanup
            maximumResponseTokens: max(256, transcript.count / 2)
        )

        do {
            let response = try await session.respond(to: prompt, options: options)
            return PromptBuilder.validated(output: response.content, input: transcript)
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize:
                // Retry once on a fresh session (shouldn't happen given the guard above).
                let fresh = LanguageModelSession(model: model, instructions: PromptBuilder.systemInstructions)
                if let output = try? await fresh.respond(to: prompt, options: options).content {
                    return PromptBuilder.validated(output: output, input: transcript)
                }
                return nil
            default:
                NSLog("LocalFlow: polish failed: \(error.localizedDescription)")
                return nil
            }
        } catch {
            NSLog("LocalFlow: polish failed: \(error.localizedDescription)")
            return nil
        }
    }

    func transform(selection: String, instruction: String) async -> String? {
        guard isAvailable else { return nil }
        // Same context-window budget reasoning as polish(): selection + response share it.
        guard selection.count < 6_000, instruction.count < 500 else { return nil }

        let session = LanguageModelSession(model: model, instructions: PromptBuilder.commandInstructions)
        let prompt = PromptBuilder.commandPrompt(selection: selection, instruction: instruction)
        let options = GenerationOptions(
            sampling: .greedy,
            maximumResponseTokens: max(512, selection.count / 2)
        )
        do {
            let response = try await session.respond(to: prompt, options: options)
            return PromptBuilder.validatedTransform(output: response.content, selection: selection)
        } catch {
            NSLog("LocalFlow: transform failed: \(error.localizedDescription)")
            return nil
        }
    }
}
