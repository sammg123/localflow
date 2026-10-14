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

    private func makeInserter(_ pasteboard: NSPasteboard,
                              trusted: Bool = true,
                              secureInput: Bool = false,
                              onPaste: @escaping () -> Void) -> TextInserter {
        TextInserter(
            pasteboard: pasteboard,
            isTrusted: { trusted },
            isSecureInput: { secureInput },
            postPaste: onPaste,
            restoreDelay: .milliseconds(5)
        )
    }

    @Test("pastes the transcript, then puts the previous clipboard back")
    func restoresPreviousClipboard() async {
        let pasteboard = makePasteboard(holding: "something I copied")
        defer { pasteboard.releaseGlobally() }
        var clipboardAtPaste: String?
        let inserter = makeInserter(pasteboard) {
            clipboardAtPaste = pasteboard.string(forType: .string)
        }

        let result = await inserter.insert("hello from localflow")

        #expect(result == .pasted)
        #expect(clipboardAtPaste == "hello from localflow")
        #expect(pasteboard.string(forType: .string) == "something I copied")
        #expect(inserter.lastTranscript == "hello from localflow")
    }

    @Test("a copy made while the paste lands is not overwritten")
    func keepsNewerCopy() async {
        let pasteboard = makePasteboard(holding: "something I copied")
        defer { pasteboard.releaseGlobally() }
        let inserter = makeInserter(pasteboard) {
            pasteboard.clearContents()
            pasteboard.setString("copied during the paste", forType: .string)
        }

        _ = await inserter.insert("hello from localflow")

        #expect(pasteboard.string(forType: .string) == "copied during the paste")
    }

    @Test("pasting the last transcript again also leaves the clipboard alone")
    func repasteRestoresClipboard() async {
        let pasteboard = makePasteboard(holding: "something I copied")
        defer { pasteboard.releaseGlobally() }
        var pasted: [String?] = []
        let inserter = makeInserter(pasteboard) {
            pasted.append(pasteboard.string(forType: .string))
        }

        _ = await inserter.insert("the dictation")
        let result = await inserter.pasteLastTranscript()

        #expect(result == .pasted)
        #expect(pasted == ["the dictation", "the dictation"])
        #expect(pasteboard.string(forType: .string) == "something I copied")
    }

    @Test("two pastes close together still give back the original clipboard")
    func overlappingPastesRestoreOriginal() async {
        let pasteboard = makePasteboard(holding: "something I copied")
        defer { pasteboard.releaseGlobally() }
        var pasted: [String?] = []
        let inserter = makeInserter(pasteboard) {
            pasted.append(pasteboard.string(forType: .string))
        }

        async let first = inserter.insert("first dictation")
        async let second = inserter.insert("second dictation")
        _ = await (first, second)

        #expect(pasted == ["first dictation", "second dictation"])
        #expect(pasteboard.string(forType: .string) == "something I copied")
    }

    @Test("with nothing dictated yet there is nothing to paste")
    func nothingToRepaste() async {
        let pasteboard = makePasteboard(holding: "something I copied")
        defer { pasteboard.releaseGlobally() }
        var pasteCount = 0
        let inserter = makeInserter(pasteboard) { pasteCount += 1 }

        let result = await inserter.pasteLastTranscript()

        #expect(result == nil)
        #expect(pasteCount == 0)
        #expect(pasteboard.string(forType: .string) == "something I copied")
    }

    @Test("secure input copies the transcript without pasting")
    func secureInputCopiesWithoutPasting() async {
        let pasteboard = makePasteboard(holding: "old clipboard")
        defer { pasteboard.releaseGlobally() }
        var pasteCount = 0
        let inserter = makeInserter(pasteboard, secureInput: true) { pasteCount += 1 }

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
        let inserter = makeInserter(pasteboard, trusted: false) { pasteCount += 1 }

        _ = await inserter.insert("no permission text")

        #expect(pasteCount == 0)
        #expect(pasteboard.string(forType: .string) == "no permission text")
    }
}

@Suite("Control + hotkey gesture")
struct ControlHotkeyTests {
    @Test("a quick tap pastes the last transcript")
    func tapPastesLast() {
        #expect(ControlHotkeyAction.forRelease(held: 0.1, commandAvailable: true) == .pasteLastTranscript)
        #expect(ControlHotkeyAction.forRelease(held: 0.1, commandAvailable: false) == .pasteLastTranscript)
    }

    @Test("a hold is still command mode")
    func holdIsCommandMode() {
        #expect(ControlHotkeyAction.forRelease(held: 1.2, commandAvailable: true) == .finishCommand)
    }

    @Test("a hold without Apple Intelligence explains why nothing happened")
    func holdWithoutModel() {
        #expect(ControlHotkeyAction.forRelease(held: 1.2, commandAvailable: false) == .commandUnavailable)
    }

    @Test("the tap/hold boundary matches the push-to-talk threshold")
    func boundary() {
        let t = HotkeyMonitor.tapThreshold
        #expect(ControlHotkeyAction.forRelease(held: t - 0.01, commandAvailable: true) == .pasteLastTranscript)
        #expect(ControlHotkeyAction.forRelease(held: t, commandAvailable: true) == .finishCommand)
    }
}
