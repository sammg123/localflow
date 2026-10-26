import AppKit
import AVFoundation
import Carbon.HIToolbox
import Foundation
import Testing
@testable import LocalFlow

@Suite("Ask: Ollama client against real servers")
struct AskClientIntegrationTests {
    @Test("nothing listening means Ollama isn't running")
    func ollamaDown() async {
        // Port 9 (discard) has no listener on a Mac.
        let client = OllamaClient(baseURL: URL(string: "http://127.0.0.1:9")!)
        let body = OllamaChatBody.ask(model: "any", question: "hi", imageBase64: "")

        await #expect(throws: AskError.ollamaNotRunning) {
            for try await _ in client.stream(body) {}
        }
    }

    @Test("a model that isn't downloaded says how to get it",
          .enabled(if: ProcessInfo.processInfo.environment["LOCALFLOW_E2E"] == "1"))
    func modelMissing() async {
        let body = OllamaChatBody.ask(model: "localflow-no-such-model:1b", question: "hi", imageBase64: "")

        await #expect(throws: AskError.modelMissing("localflow-no-such-model:1b")) {
            for try await _ in OllamaClient().stream(body) {}
        }
    }
}

/// The whole Ask pipeline minus the key and the bubble: a spoken question through
/// Parakeet, a real screenshot, a real answer from the local model.
/// Run with LOCALFLOW_E2E=1 (needs Ollama, the model, and Screen Recording for the terminal).
@MainActor
@Suite("Ask: end to end", .enabled(if: ProcessInfo.processInfo.environment["LOCALFLOW_E2E"] == "1"))
struct AskEndToEndTests {
    @Test("spoken question + screenshot -> streamed answer", .timeLimit(.minutes(3)))
    func asksAboutTheScreen() async throws {
        let question = "What app is open on my screen right now?"
        let samples = try Self.speak(question)
        let engine = ParakeetTranscriber()
        try await engine.prepare()

        let heard = try await engine.transcribe(samples: samples)
        let screen = try #require(NSScreen.main)
        let png = try await ScreenCapturer.capturePNG(of: screen)
        let started = ContinuousClock.now
        var firstToken: Duration?
        var answer = ""
        let body = OllamaChatBody.ask(model: Settings.defaultAskModel, question: heard,
                                      imageBase64: png.base64EncodedString())
        for try await token in OllamaClient().stream(body) {
            if firstToken == nil { firstToken = started.duration(to: .now) }
            answer += token
        }

        #expect(heard.lowercased().contains("screen"))
        #expect(png.count > 10_000)
        #expect(!answer.isEmpty)
        print("E2E heard: \(heard)\nE2E image: \(png.count / 1024) KB\nE2E first token: \(firstToken.map { "\($0)" } ?? "-"), total \(started.duration(to: .now))\nE2E answer: \(answer)")
    }

    @Test("a follow-up uses what was said earlier in the conversation", .timeLimit(.minutes(3)))
    func followUpUsesMemory() async throws {
        let screen = try #require(NSScreen.main)
        let png = try await ScreenCapturer.capturePNG(of: screen)
        let history = [AskTurn(question: "Pick a fruit at random and tell me which.", answer: "I picked a mango.")]
        let body = OllamaChatBody.ask(model: Settings.defaultAskModel, question: "Which fruit did you pick?",
                                      imageBase64: png.base64EncodedString(), history: history)
        var answer = ""

        for try await token in OllamaClient().stream(body) { answer += token }

        print("E2E follow-up answer: \(answer)")
        #expect(answer.lowercased().contains("mango"))
    }

    /// `say` straight to 16 kHz mono float, the format the recorder hands the engine.
    private static func speak(_ text: String) throws -> [Float] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ask-e2e-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", url.path, "--data-format=LEF32@16000", text]
        try say.run()
        say.waitUntilExit()
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                   frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channel = try #require(buffer.floatChannelData?[0])
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}

/// Puts the real bubble and outline on screen for a couple of seconds, streams text
/// into the bubble, then clicks ✕ with a synthetic mouse click. Silent; the pointer is
/// put back where it was. Run with LOCALFLOW_E2E=1 (posting the click needs the
/// terminal to have Accessibility).
@MainActor
@Suite("Ask: on screen", .serialized, .enabled(if: ProcessInfo.processInfo.environment["LOCALFLOW_E2E"] == "1"))
struct AskOnScreenTests {
    @Test("bubble grows upward from the pill's spot and ✕ closes it on the first click")
    func bubbleStreamsAndCloses() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let screen = try #require(NSScreen.main)
        let panel = AnswerPanel(closeHint: "Esc to close   ·   Right ⌥ to ask again")
        var closed = false
        panel.onClose = {
            closed = true
            panel.hide()
        }

        panel.show(on: screen)
        panel.model.question = "What's on my screen?"
        pump(0.4)
        let lookingHeight = panel.frame.height
        panel.model.phase = .answering
        for word in "A Brightspace slide on **equilibrium in dominant strategies**, page 35 of 100. It says each player does best regardless of what the other does.".split(separator: " ") {
            panel.model.answer += word + " "
            pump(0.03)
        }
        panel.model.answer += "\n```r\nse <- sd(boot$stat)\n```"
        panel.model.phase = .done
        pump(0.5)
        let frame = panel.frame
        Self.snapshot(frame, name: "live-bubble")

        #expect(frame.minY == screen.visibleFrame.minY + 28)
        #expect(frame.height > lookingHeight)
        #expect(frame.width == AnswerPanel.width)

        // ✕ sits at the top-right: 18 pt padding, 22 pt button.
        click(atAppKitPoint: NSPoint(x: frame.maxX - 18 - 11, y: frame.maxY - 18 - 11), on: screen)
        pump(0.5)

        #expect(closed)
        #expect(!panel.isVisible)
    }

    @Test("– tucks the answer into the corner chip, the chip brings it back, and a covering window tucks it too")
    func bubbleMinimizesAndExpands() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let screen = try #require(NSScreen.main)
        let panel = AnswerPanel(closeHint: "Esc to close   ·   Right ⌥ to ask again")
        var changes = 0
        var closed = false
        panel.onMinimizeChange = { changes += 1 }
        panel.onClose = {
            closed = true
            panel.hide()
        }

        panel.show(on: screen)
        panel.model.question = "What's the Nash equilibrium in this table?"
        panel.model.answer = "Both players pick **Bottom/Right**: neither gains by switching alone."
        panel.model.phase = .done
        pump(0.6)
        let frame = panel.frame

        // – sits left of ✕: 18 pt padding, 22 pt buttons, 8 pt apart.
        click(atAppKitPoint: NSPoint(x: frame.maxX - 18 - 22 - 8 - 11, y: frame.maxY - 18 - 11), on: screen)
        pump(0.4)
        let chip = panel.chipFrame
        Self.snapshot(chip.insetBy(dx: -8, dy: -8), name: "live-chip")

        #expect(panel.isMinimized)
        #expect(panel.isVisible)
        #expect(changes == 1)
        #expect(chip.maxX == screen.visibleFrame.maxX - 20)

        click(atAppKitPoint: NSPoint(x: chip.minX + 80, y: chip.midY), on: screen)
        pump(0.6)

        #expect(!panel.isMinimized)
        #expect(changes == 2)

        // Another window lands completely on top of it, like Terminal being clicked.
        let cover = NSWindow(
            contentRect: panel.frame.insetBy(dx: -40, dy: -40),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        cover.backgroundColor = .darkGray
        cover.orderFrontRegardless()
        pump(1.2)
        cover.orderOut(nil)

        #expect(panel.isMinimized)
        #expect(changes == 3)

        // The chip's own ✕ closes it for good.
        click(atAppKitPoint: NSPoint(x: chip.maxX - 10 - 10, y: chip.midY), on: screen)
        pump(0.3)

        #expect(closed)
        #expect(!panel.isVisible)
    }

    @Test("the Ask window takes typing and edit shortcuts; Return sends and Esc cancels")
    func composerTakesTyping() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let screen = try #require(NSScreen.main)
        let composer = AskComposerPanel()
        var sent: String?
        var cancelled = false
        composer.onSend = { sent = composer.model.question }
        composer.onCancel = { cancelled = true }

        composer.model.reset(mode: .typing)
        composer.show(on: screen)
        pump(0.5)
        // (Key focus itself only exists in a launched app, not this test process; it was
        // checked with a launched probe app. Here the events go straight to this process.)
        typeIntoSelf("hi there")
        pressKeyInSelf(UInt16(kVK_ANSI_A), flags: .maskCommand)
        typeIntoSelf("What is the dominant strategy for player two?")
        pump(0.3)
        Self.snapshot(composer.frame, name: "live-composer")
        pressKeyInSelf(UInt16(kVK_Return))
        pump(0.2)
        pressKeyInSelf(UInt16(kVK_Escape))
        pump(0.2)
        composer.hide()

        #expect(sent == "What is the dominant strategy for player two?")
        #expect(cancelled)
        #expect(composer.frame.minY == screen.visibleFrame.minY + 28)
    }

    /// Key events go to this test process only, never to whatever app is in front.
    private func typeIntoSelf(_ text: String) {
        for character in text {
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
                let utf16 = Array(String(character).utf16)
                event?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                event?.postToPid(getpid())
            }
            pump(0.01)
        }
    }

    private func pressKeyInSelf(_ key: UInt16, flags: CGEventFlags = []) {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)
            event?.flags = flags
            event?.postToPid(getpid())
        }
        pump(0.05)
    }

    @Test("outline covers the whole display")
    func glowShows() async throws {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.main)
        let glow = ScreenGlow()

        glow.show(on: screen)
        pump(0.6)
        Self.snapshot(screen.frame, name: "live-glow")
        glow.hide()
        pump(0.4)
    }

    /// Runs the app's event loop for a while so windows draw and clicks get delivered.
    private func pump(_ seconds: TimeInterval) {
        let until = Date(timeIntervalSinceNow: seconds)
        while Date() < until {
            if let event = NSApp.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.01),
                                           inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
        }
    }

    private func click(atAppKitPoint point: NSPoint, on screen: NSScreen) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let target = CGPoint(x: point.x, y: primaryHeight - point.y)
        let restore = CGEvent(source: nil)?.location
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: target, mouseButton: .left)?
                .post(tap: .cghidEventTap)
            pump(0.05)
        }
        if let restore { CGWarpMouseCursorPosition(restore) }
    }

    /// Saves what is on screen in a rect (AppKit coordinates) when LOCALFLOW_SNAPSHOT_DIR is set.
    private static func snapshot(_ rect: NSRect, name: String) {
        guard let dir = ProcessInfo.processInfo.environment["LOCALFLOW_SNAPSHOT_DIR"] else { return }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? rect.height
        let region = "\(Int(rect.minX)),\(Int(primaryHeight - rect.maxY)),\(Int(rect.width)),\(Int(rect.height))"
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-R", region, "\(dir)/\(name).png"]
        try? capture.run()
        capture.waitUntilExit()
    }
}
