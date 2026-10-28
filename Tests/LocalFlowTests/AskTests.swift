import AppKit
import Foundation
import SwiftUI
import Testing
@testable import LocalFlow

@Suite("Ask: Ollama request and stream")
struct OllamaProtocolTests {
    @Test("chat body carries the screenshot, the question and the local-model options")
    func chatBodyShape() throws {
        let body = OllamaChatBody.ask(model: "qwen3.5:9b", question: "what's my CI", imageBase64: "AAAA")

        let json = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])

        #expect(json["model"] as? String == "qwen3.5:9b")
        #expect(json["stream"] as? Bool == true)
        #expect(json["think"] as? Bool == false)
        #expect(json["keep_alive"] as? String == OllamaChatBody.keepAlive)
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.count == 2)
        #expect(messages[0]["role"] as? String == "system")
        #expect(messages[0]["images"] == nil)
        #expect(messages[1]["role"] as? String == "user")
        #expect(messages[1]["content"] as? String == "what's my CI")
        #expect(messages[1]["images"] as? [String] == ["AAAA"])
        let options = try #require(json["options"] as? [String: Any])
        #expect(options["num_ctx"] as? Int == 8192)
        #expect(options["num_predict"] != nil)
    }

    @Test("stream lines become tokens, a finish, or an error", arguments: [
        (#"{"message":{"role":"assistant","content":"Your CI"},"done":false}"#, [OllamaStreamEvent.token("Your CI")]),
        (#"{"message":{"role":"assistant","content":""},"done":true,"eval_count":40}"#, [.done]),
        (#"{"message":{"role":"assistant","content":"end"},"done":true}"#, [.token("end"), .done]),
        (#"{"error":"model runner has unexpectedly stopped"}"#, [.failed("model runner has unexpectedly stopped")]),
        ("", []),
        ("not json", []),
    ])
    func parsesStreamLine(line: String, expected: [OllamaStreamEvent]) {
        #expect(OllamaStreamEvent.parse(line: line) == expected)
    }

    @Test("a missing model tells you the pull command")
    func missingModel() {
        let body = Data(#"{"error":"model 'qwen3.5:9b' not found"}"#.utf8)

        let error = AskError.fromHTTP(status: 404, body: body, model: "qwen3.5:9b")

        #expect(error == .modelMissing("qwen3.5:9b"))
        #expect(error.message.contains("ollama pull qwen3.5:9b"))
    }

    @Test("other HTTP failures keep Ollama's own message")
    func otherHTTPFailure() {
        let body = Data(#"{"error":"out of memory"}"#.utf8)

        #expect(AskError.fromHTTP(status: 500, body: body, model: "m") == .ollama("out of memory"))
        #expect(AskError.fromHTTP(status: 502, body: Data(), model: "m") == .ollama("HTTP 502"))
    }

    @Test("connection failures mean Ollama isn't running", arguments: [
        URLError.Code.cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
    ])
    func connectionFailure(code: URLError.Code) {
        #expect(AskError.from(URLError(code)) == .ollamaNotRunning)
    }

    @Test("the log gets the kind of failure, never the text inside it", arguments: [
        (AskError.ollama("the user's question was: what's my SSN"), "ollama"),
        (.modelMissing("qwen3.5:9b"), "modelMissing"),
        (.screenCaptureFailed("denied"), "screenCaptureFailed"),
        (.ollamaNotRunning, "ollamaNotRunning"),
        (.timedOut, "timedOut"),
    ])
    func logName(error: AskError, expected: String) {
        #expect(error.logName == expected)
    }

    @Test("a stalled model is a timeout, not a crash")
    func timeout() {
        #expect(AskError.from(URLError(.timedOut)) == .timedOut)
    }
}

@Suite("Ask: screenshot sizing")
struct AskImageSizingTests {
    @Test("fits the longest side, keeps the aspect ratio, never upscales", arguments: [
        (1512, 982, 1512, 982),
        (3024, 1964, 1920, 1247),
        (5120, 2880, 1920, 1080),
        (1080, 1920, 1080, 1920),
        (2160, 3840, 1080, 1920),
    ])
    func fits(width: Int, height: Int, expectedWidth: Int, expectedHeight: Int) {
        let size = AskImageSizing.fit(width: width, height: height)

        #expect(size.width == expectedWidth)
        #expect(size.height == expectedHeight)
    }
}

@Suite("Ask: key choice")
struct AskKeyChoiceTests {
    @Test("the ask key works unless it is off or the same as the dictation key", arguments: [
        (AskKeyChoice.rightOption, HotkeyChoice.fnKey, HotkeyChoice?.some(.rightOption)),
        (.rightCommand, .fnKey, .some(.rightCommand)),
        (.rightOption, .rightOption, nil),
        (.rightCommand, .rightCommand, nil),
        (.off, .fnKey, nil),
    ])
    func effectiveKey(ask: AskKeyChoice, dictation: HotkeyChoice, expected: HotkeyChoice?) {
        #expect(AskKeyChoice.effectiveHotkey(ask: ask, dictation: dictation) == expected)
    }

}

@Suite("Ask: answer formatting")
struct AnswerFormatterTests {
    @Test("splits fenced code from prose")
    func splitsCode() {
        let text = "Your CI is 3.62 to 3.75.\n```r\nse <- sd(boot$stat)\nmean_bar + c(-1, 1) * 1.96 * se\n```\nThat's the SE method."

        let segments = AnswerFormatter.segments(text)

        #expect(segments == [
            .prose("Your CI is 3.62 to 3.75."),
            .code("se <- sd(boot$stat)\nmean_bar + c(-1, 1) * 1.96 * se"),
            .prose("That's the SE method."),
        ])
    }

    @Test("an unclosed fence mid-stream still shows as code")
    func unclosedFence() {
        #expect(AnswerFormatter.segments("Try:\n```\nx <- 1") == [.prose("Try:"), .code("x <- 1")])
    }

    @Test("plain prose is one segment and blank text is none")
    func prose() {
        #expect(AnswerFormatter.segments("It's RStudio.") == [.prose("It's RStudio.")])
        #expect(AnswerFormatter.segments("  \n ").isEmpty)
    }
}

@Suite("Ask: joining typed and spoken words")
struct AskTextTests {
    @Test("spoken words follow typed ones with one space", arguments: [
        ("", "what's this", "what's this"),
        ("In this table,", "which dominates", "In this table, which dominates"),
        ("Typed ", "  spoken  ", "Typed spoken"),
        ("Typed", "", "Typed"),
    ])
    func joins(typed: String, spoken: String, expected: String) {
        #expect(AskText.join(typed, spoken) == expected)
    }
}

@MainActor
@Suite("Ask: rendering")
struct AskRenderTests {
    @Test("answer bubble renders in every phase", arguments: [
        AnswerPhase.looking,
        .thinking,
        .answering,
        .done,
        .failed("Ollama isn't running. Start it, then ask again."),
    ])
    func rendersAnswer(phase: AnswerPhase) throws {
        let model = AnswerModel()
        model.question = "What's my 95% confidence interval and what do I write next?"
        model.phase = phase
        if phase == .answering || phase == .done {
            model.answer = "Your 95% percentile CI is **3.62 to 3.75**.\n```r\nse <- sd(boot_almond_mean$stat)\nmean_bar + c(-1, 1) * 1.96 * se\n```\nThat's the SE method."
        }
        let renderer = ImageRenderer(content: AnswerView(model: model, closeHint: "Right ⌥ or Fn closes", scrolls: false))
        renderer.scale = 2

        let image = try #require(renderer.nsImage)

        #expect(image.size.width == AnswerPanel.width)
        #expect(image.size.height > 60)
        try saveSnapshot(image, name: "answer-\(phase.snapshotName)")
    }

    @Test("the Ask window renders in each mode", arguments: [
        (ComposerMode.voice, ""),
        (.voice, "What's the Nash equilibrium in this table, and which strategy is dominant for player two?"),
        (.finishing, "What's the Nash equilibrium in this table?"),
        (.typing, ""),
    ])
    func rendersComposer(mode: ComposerMode, text: String) throws {
        let model = ComposerModel()
        model.mode = mode
        model.text = text
        model.level = 0.5
        model.keyName = "Right ⌥"
        let renderer = ImageRenderer(content: AskComposerView(model: model))
        renderer.scale = 2

        let image = try #require(renderer.nsImage)

        #expect(image.size == AskComposerView.size)
        try saveSnapshot(image, name: "composer-\(mode)-\(text.count)")
    }

    @Test("the window's title and hint say what the key does in each mode")
    func composerCopy() {
        let model = ComposerModel()
        model.keyName = "Right ⌥"

        model.mode = .voice
        #expect(model.title == "Listening")
        #expect(model.hint.contains("Right ⌥ to stop"))
        model.mode = .typing
        #expect(model.hint.contains("Right ⌥ to talk"))
        #expect(model.hint.contains("Return to ask"))
        #expect(model.hint.contains("⌘Return to do it"))
    }

    @Test("send is off only when there's nothing to send")
    func canSend() {
        let model = ComposerModel()

        model.mode = .typing
        #expect(!model.canSend)
        model.text = "  "
        #expect(!model.canSend)
        model.text = "why?"
        #expect(model.canSend)
        model.mode = .voice
        model.text = ""
        #expect(model.canSend)
    }

    @Test("the minimized chip renders in every phase", arguments: [
        AnswerPhase.thinking, .answering, .done, .failed("Ollama isn't running."),
    ])
    func rendersChip(phase: AnswerPhase) throws {
        let model = AnswerModel()
        model.question = "What's the Nash equilibrium in this table, and which strategy dominates?"
        model.phase = phase
        let renderer = ImageRenderer(content: AnswerChipView(model: model))
        renderer.scale = 2

        let image = try #require(renderer.nsImage)

        #expect(image.size == AnswerChipView.size)
        try saveSnapshot(image, name: "chip-\(phase.snapshotName)")
    }

    @Test("the working label counts seconds once it's been a moment", arguments: [
        (AnswerPhase.looking, 0.5, "Looking at your screen"),
        (.thinking, 1.0, "Thinking"),
        (.thinking, 4.2, "Thinking · 4s"),
        (.thinking, 61.0, "Thinking · 61s"),
    ])
    func workingLabel(phase: AnswerPhase, elapsed: TimeInterval, expected: String) {
        #expect(WorkingLabel.text(for: phase, elapsed: elapsed) == expected)
    }

    @Test("only another app's ordinary window over all of the bubble counts as covering it", arguments: [
        ([window(x: 0, y: 0, w: 1000, h: 800)], true),
        ([window(x: 150, y: 450, w: 300, h: 100)], false),               // partly over it
        ([window(x: 0, y: 0, w: 1000, h: 800, layer: 25)], false),        // menu bar, lock screen, overlays
        ([window(x: 0, y: 0, w: 1000, h: 800, alpha: 0)], false),         // invisible
        ([], false),                                                      // screen locked or asleep
    ])
    func coveringWindows(windows: [[String: Any]], covered: Bool) {
        // The bubble at 100,400 (top-left coordinates), 460 x 200.
        let bubble = CGRect(x: 100, y: 400, width: 460, height: 200)

        #expect(AnswerPanel.isCovered(bubble, by: windows) == covered)
    }

    @Test("a click on an app's window sends the bubble behind it; the desktop, Dock and menu bar don't", arguments: [
        (42, [window(x: 0, y: 0, w: 900, h: 600, number: 42)], 42 as Int?),
        (42, [window(x: 0, y: 0, w: 1512, h: 982, layer: 20, number: 42)], nil),         // the Dock
        (42, [window(x: 0, y: 0, w: 1512, h: 982, layer: -2147483603, number: 42)], nil), // the desktop
        (42, [window(x: 0, y: 0, w: 900, h: 600, number: 7)], nil),                      // not listed
        (0, [window(x: 0, y: 0, w: 900, h: 600, number: 0)], nil),                       // nothing under the click
    ] as [(Int, [[String: Any]], Int?)])
    func windowToGoBehind(clicked: Int, windows: [[String: Any]], expected: Int?) {
        #expect(AnswerPanel.windowToGoBehind(clicked, among: windows) == expected)
    }

    @Test("switching to an app finds its frontmost ordinary window", arguments: [
        ([window(x: 0, y: 0, w: 500, h: 300, number: 3, pid: 99),
          window(x: 0, y: 0, w: 500, h: 300, layer: 25, number: 4, pid: 7),
          window(x: 0, y: 0, w: 500, h: 300, number: 5, pid: 7),
          window(x: 0, y: 0, w: 500, h: 300, number: 6, pid: 7)], 5 as Int?),
        ([window(x: 0, y: 0, w: 500, h: 300, number: 3, pid: 99)], nil),              // no windows open
    ] as [([[String: Any]], Int?)])
    func frontWindow(windows: [[String: Any]], expected: Int?) {
        #expect(AnswerPanel.frontWindow(of: 7, among: windows) == expected)
    }

    @Test("screen glow renders at the screen's size")
    func rendersGlow() throws {
        let size = CGSize(width: 1512, height: 982)
        let renderer = ImageRenderer(content: GlowView(pulses: false).frame(width: size.width, height: size.height))

        let image = try #require(renderer.nsImage)

        #expect(image.size == size)
        try saveSnapshot(image, name: "glow")
    }

    private func saveSnapshot(_ image: NSImage, name: String) throws {
        guard let dir = ProcessInfo.processInfo.environment["LOCALFLOW_SNAPSHOT_DIR"],
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }
}

/// A window as CGWindowListCopyWindowInfo describes it.
private func window(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, layer: Int = 0, alpha: Double = 1,
                    number: Int = 1, pid: Int = 1) -> [String: Any] {
    [
        kCGWindowNumber as String: number,
        kCGWindowOwnerPID as String: pid,
        kCGWindowLayer as String: layer,
        kCGWindowAlpha as String: alpha,
        kCGWindowBounds as String: CGRect(x: x, y: y, width: w, height: h).dictionaryRepresentation,
    ]
}

private extension AnswerPhase {
    var snapshotName: String {
        switch self {
        case .looking: return "looking"
        case .thinking: return "thinking"
        case .answering: return "answering"
        case .done: return "done"
        case .failed: return "failed"
        }
    }
}

@Suite("Ask: conversation memory")
struct AskMemoryTests {
    private let one = AskTurn(question: "What's this slide?", answer: "Nash equilibrium.")
    private let two = AskTurn(question: "Define it", answer: "Each player's best response.")
    private let three = AskTurn(question: "Example?", answer: "Prisoner's dilemma.")

    @Test("history fits a size budget, dropping the oldest turns first")
    func historyBudget() {
        let long = AskTurn(question: String(repeating: "q", count: 600), answer: String(repeating: "a", count: 600))

        let kept = AskMemory.fitting([long, one, two], budget: 200)

        #expect(kept == [one, two])
        #expect(AskMemory.fitting([one, two], budget: 0).isEmpty)
    }

    @Test("follow-ups carry earlier turns as text, and only the newest question has the screenshot")
    func bodyWithHistory() {
        let body = OllamaChatBody.ask(model: "m", question: "And player two?", imageBase64: "IMG", history: [one, two])

        #expect(body.messages.map(\.role) == ["system", "user", "assistant", "user", "assistant", "user"])
        #expect(body.messages[1].content == one.question)
        #expect(body.messages[2].content == one.answer)
        #expect(body.messages.dropLast().allSatisfy { $0.images == nil })
        #expect(body.messages.last?.images == ["IMG"])
        #expect(body.messages.last?.content == "And player two?")
    }
}
