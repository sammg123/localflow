import AppKit
import Foundation
import Testing
@testable import LocalFlow

/// Run with LOCALFLOW_E2E=1. Needs Claude Code, and LocalFlow's own Claude sign-in for
/// the answer test (each sign-in folder has its own account, so the user's everyday
/// Claude Code sign-in doesn't count). Sends a drawn test image, never the screen.
@Suite("Ask: Claude against the real tool", .enabled(if: ProcessInfo.processInfo.environment["LOCALFLOW_E2E"] == "1"))
struct ClaudeIntegrationTests {
    /// A white card that says "Total due: $42.17".
    private func testImage() throws -> String {
        let size = NSSize(width: 480, height: 160)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        ("Total due: $42.17" as NSString).draw(at: NSPoint(x: 30, y: 60), withAttributes: [
            .font: NSFont.systemFont(ofSize: 36, weight: .bold), .foregroundColor: NSColor.black,
        ])
        image.unlockFocus()
        let rep = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        return try #require(rep.representation(using: .png, properties: [:])).base64EncodedString()
    }

    @Test("reads the screenshot and streams the answer", .timeLimit(.minutes(2)))
    func answers() async throws {
        let body = OllamaChatBody.ask(model: "claude-sonnet-5-5", question: "What is the total due? One short sentence.",
                                      imageBase64: try testImage())
        let client = ClaudeClient(model: "claude-sonnet-5-5")
        var chunks: [String] = []
        for try await chunk in client.stream(body) { chunks.append(chunk) }

        #expect(chunks.joined().contains("42.17"))
        #expect(!chunks.isEmpty)
    }

    @Test("an empty sign-in folder says to sign in", .timeLimit(.minutes(1)))
    func signedOut() async throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("claude-empty-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: empty) }
        let body = OllamaChatBody.ask(model: "claude-sonnet-5-5", question: "hi", imageBase64: try testImage())
        let client = ClaudeClient(model: "claude-sonnet-5-5", configDirectory: empty.path)

        await #expect(throws: AskError.claudeSignedOut) {
            for try await _ in client.stream(body) {}
        }
        let executable = try #require(ClaudeInvocation.locate())
        #expect(await ClaudeSignIn.status(executable: executable, configDirectory: empty.path) == .signedOut)
    }
}
