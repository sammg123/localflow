import AppKit
import Testing
@testable import LocalFlow

@MainActor
@Suite("TextInserter clipboard behaviour")
struct TextInserterTests {
    private func makePasteboard(holding existing: String) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: .init("localflow-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString(existing, forType: .string)
        return pasteboard
    }

    @Test("transcript stays on the clipboard after it is pasted")
    func transcriptStaysOnClipboardAfterPaste() async {
        let pasteboard = makePasteboard(holding: "old clipboard")
        defer { pasteboard.releaseGlobally() }
        var pasteCount = 0
        let inserter = TextInserter(
            pasteboard: pasteboard,
            isTrusted: { true },
            isSecureInput: { false },
            postPaste: { pasteCount += 1 }
        )

        let result = await inserter.insert("hello from localflow")

        #expect(result == .pasted)
        #expect(pasteCount == 1)
        #expect(pasteboard.string(forType: .string) == "hello from localflow")
        #expect(pasteboard.types?.contains(TextInserter.concealedType) == true)
        #expect(inserter.lastTranscript == "hello from localflow")
    }

    @Test("secure input copies the transcript without pasting")
    func secureInputCopiesWithoutPasting() async {
        let pasteboard = makePasteboard(holding: "old clipboard")
        defer { pasteboard.releaseGlobally() }
        var pasteCount = 0
        let inserter = TextInserter(
            pasteboard: pasteboard,
            isTrusted: { true },
            isSecureInput: { true },
            postPaste: { pasteCount += 1 }
        )

        let result = await inserter.insert("secret field text")

        guard case .leftOnClipboard = result else {
            Issue.record("expected leftOnClipboard, got \(result)")
            return
        }
        #expect(pasteCount == 0)
        #expect(pasteboard.string(forType: .string) == "secret field text")
    }

    @Test("missing Accessibility copies the transcript without pasting")
    func untrustedCopiesWithoutPasting() async {
        let pasteboard = makePasteboard(holding: "old clipboard")
        defer { pasteboard.releaseGlobally() }
        var pasteCount = 0
        let inserter = TextInserter(
            pasteboard: pasteboard,
            isTrusted: { false },
            isSecureInput: { false },
            postPaste: { pasteCount += 1 }
        )

        _ = await inserter.insert("no permission text")

        #expect(pasteCount == 0)
        #expect(pasteboard.string(forType: .string) == "no permission text")
    }
}
