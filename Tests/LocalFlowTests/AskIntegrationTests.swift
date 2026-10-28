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
    @Test("bubble grows upward from the pill's spot, Chats opens the chats, and ✕ closes it")
    func bubbleStreamsAndCloses() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let screen = try #require(NSScreen.main)
        let panel = AnswerPanel(closeHint: "Esc to minimize   ·   ⇧Esc to close   ·   Right ⌥ to ask again")
        var closed = false
        panel.onClose = {
            closed = true
            panel.hide()
        }

        panel.show(question: "What's on my screen?", on: screen)
        pump(0.4)
        let lookingHeight = panel.frame.height
        Self.snapshot(panel.frame, name: "live-looking")
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

        // Clicks go to the bubble in this process only: you may be clicking other apps,
        // which (by design) puts the bubble behind them.
        let window = try #require(NSApp.windows.first { $0.frame == frame && $0.isVisible })
        // Chats sits left of copy, – and ✕ (22 pt buttons, 8 pt apart).
        var openedChats = false
        panel.onOpenChats = { openedChats = true }
        click(NSPoint(x: frame.maxX - 18 - 3 * (22 + 8) - 11, y: frame.maxY - 18 - 11), in: window)

        #expect(openedChats)

        // ✕ sits at the top-right: 18 pt padding, 22 pt button.
        click(NSPoint(x: frame.maxX - 18 - 11, y: frame.maxY - 18 - 11), in: window)
        pump(0.5)

        #expect(closed)
        #expect(!panel.isVisible)
    }

    @Test("the answer's words can be dragged over and copied with Cmd+C, or all of it with Cmd+A")
    func answerTextCopies() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = MainMenu.make() // as the app has it; its shortcuts must not clash
        let screen = try #require(NSScreen.main)
        let clipboard = SavedClipboard()
        defer { clipboard.restore() }
        let panel = AnswerPanel(closeHint: "Esc to minimize   ·   ⇧Esc to close   ·   Right ⌥ to ask again")
        let answer = "Run brew services restart ollama and then ask again in a few seconds."
        defer { panel.hide() }

        panel.show(question: "Why did Ask say Ollama isn't running?", on: screen)
        panel.model.answer = answer
        panel.model.phase = .done
        pump(0.6)
        let frame = panel.frame
        let window = try #require(NSApp.windows.first { $0.frame == frame && $0.isVisible })

        // The copy button, left of – and ✕ (22 pt buttons, 8 pt apart), copies it all and
        // leaves the keyboard with the app being worked in.
        clipboard.clearForTest()
        click(NSPoint(x: frame.maxX - 18 - 2 * (22 + 8) - 11, y: frame.maxY - 18 - 11), in: window)

        #expect(clipboard.copiedByTest() == answer)
        #expect(!panel.isKey)

        // The answer's first line: 18 pt padding, the 22 pt header row, 12 pt spacing.
        let line = frame.maxY - 18 - 22 - 12 - 10
        drag(from: NSPoint(x: frame.minX + 18, y: line), to: NSPoint(x: frame.minX + 18 + 120, y: line), in: window)
        pressKeyInSelf(UInt16(kVK_ANSI_C), flags: .maskCommand)
        pump(0.2)
        let dragged = clipboard.copiedByTest() ?? ""

        #expect(panel.isKey)
        #expect(!dragged.isEmpty)
        #expect(answer.hasPrefix(dragged))
        #expect(dragged.count < answer.count)

        pressKeyInSelf(UInt16(kVK_ANSI_A), flags: .maskCommand)
        pressKeyInSelf(UInt16(kVK_ANSI_C), flags: .maskCommand)
        pump(0.2)

        #expect(clipboard.copiedByTest() == answer)
    }

    @Test("the Chats window shows past chats by day and one in full")
    func chatsWindowShows() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        var clock = Date().addingTimeInterval(-3 * 86_400)
        let store = AskChatStore(fileURL: nil, now: { clock })
        store.record(question: "What's the dominant strategy here?", answer: "Bottom for player one: it pays more whatever the other player does.")
        clock = Date().addingTimeInterval(-3_600)
        store.startNewChat()
        store.record(question: "Why did Ask say Ollama isn't running?", answer: "Restart it:\n```sh\nbrew services restart ollama\n```\nThen **ask again**.")
        clock = Date().addingTimeInterval(-3_000)
        store.record(question: "And if that fails?", answer: "Check `ollama list` shows the model.")
        let chats = AskHistoryWindowController(store: store) { _ in }
        defer { chats.close() }

        chats.show(activating: false)
        pump(1.0)
        Self.snapshot(window: chats.contentView?.window?.windowNumber, name: "live-chats-window")

        #expect(chats.isVisible)
        #expect(chats.frame.width >= 720)
    }

    @Test("a long question sent from the Ask window shows the dots and Thinking until the first word")
    func sendShowsWorking() async throws {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.main)
        let client = FakeModelClient()
        client.tokenDelay = .seconds(3)
        client.tokens = ["Both players pick Bottom/Right. Neither gains by switching alone, so it's the only "
                         + "equilibrium in the table, and each player's choice is dominant whatever the other one does."]
        let panel = AnswerPanel(closeHint: "Esc to minimize   ·   ⇧Esc to close   ·   Right ⌥ to ask again")
        let answers = AskController(client: client, surface: panel, closeHint: "Esc to minimize   ·   ⇧Esc to close   ·   Right ⌥ to ask again")
        let composer = AskComposerPanel()
        let mic = FakeMic() // the session holds it weakly
        // Long enough to wrap the question onto two lines in the bubble's header.
        let spoken = String(repeating: "Can you look at this table of payoffs and tell me which strategy each player should pick, and why? ", count: 2)
        let session = AskSession(
            mic: mic, composer: composer, answers: answers,
            transcribe: { _ in spoken },
            canOpen: { true }, chime: {}, swallowPress: {}, holdDelay: nil, liveInterval: nil
        )
        defer { answers.dismiss() }

        // Tap to type, tap to talk, Return: the app's real send path, with the run loop running freely.
        session.keyDown(at: 0)
        session.keyUp(held: 0.1, at: 0.1)
        session.keyDown(at: 1)
        session.keyUp(held: 0.1, at: 1.1)
        await run(0.8)
        session.send()
        await run(1.5)
        Self.snapshot(panel.frame, name: "live-send-thinking")
        let working = panel.frame.height

        #expect([.looking, .thinking].contains(panel.model.phase))
        // Two header lines, the dots row and the hint; about 103 pt with the row missing.
        #expect(working >= 120)

        // The words replace the row, and the bubble grows to show all three lines.
        await run(4)
        Self.snapshot(panel.frame, name: "live-send-answer")

        #expect([.answering, .done].contains(panel.model.phase))
        #expect(panel.frame.height > working)
    }

    @Test("– tucks the answer into the corner chip, the chip brings it back, and another app stays under it until clicked")
    func bubbleMinimizesAndExpands() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let screen = try #require(NSScreen.main)
        let otherApp = try OtherAppWindow.build()
        let panel = AnswerPanel(closeHint: "Esc to minimize   ·   ⇧Esc to close   ·   Right ⌥ to ask again")
        var changes = 0
        var closed = false
        panel.onMinimizeChange = { changes += 1 }
        panel.onClose = {
            closed = true
            panel.hide()
        }

        panel.show(question: "What's the Nash equilibrium in this table?", on: screen)
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

        // Another app's window comes in front over all of it without switching apps, the
        // way Terminal's does when it takes the keyboard back as the Ask window closes.
        // The answer stays on top...
        let expanded = panel.frame
        let cover = try OtherAppWindow(binary: otherApp, covering: expanded.insetBy(dx: -40, dy: -40))
        defer { cover.close() }
        pump(1.2)

        #expect(!panel.isMinimized)
        #expect(changes == 2)

        // ...until that app is clicked: then it goes behind, and being covered completely
        // tucks it into the chip.
        click(atAppKitPoint: NSPoint(x: expanded.minX - 20, y: expanded.midY), on: screen)
        pump(1.2)
        cover.close()

        #expect(panel.isMinimized)
        #expect(changes == 3)

        // Switching to another app without a click (Cmd-Tab) counts as clicking it.
        click(atAppKitPoint: NSPoint(x: chip.minX + 80, y: chip.midY), on: screen)
        pump(0.6)
        #expect(!panel.isMinimized)
        let switched = try OtherAppWindow(binary: otherApp, covering: panel.frame.insetBy(dx: -40, dy: -40),
                                          activates: true)
        defer { switched.close() }
        pump(1.2)
        switched.close()

        #expect(panel.isMinimized)
        #expect(changes == 5)

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
        NSApp.mainMenu = MainMenu.make() // as the app has it; its shortcuts must not clash
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

    @Test("the hands-free window, paused, takes typing; Return pastes and Esc cancels")
    func dictationWindowTakesTyping() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = MainMenu.make()
        let screen = try #require(NSScreen.main)
        let window = DictationComposerPanel()
        var pasted: String?
        var cancelled = false
        window.onSend = { pasted = window.model.text }
        window.onCancel = { cancelled = true }

        window.model.reset(mode: .voice)
        window.model.text = "Hello there."
        window.show(on: screen)
        pump(0.3)
        window.model.mode = .typing // paused
        pump(0.3)
        pressKeyInSelf(UInt16(kVK_ANSI_A), flags: .maskCommand)
        typeIntoSelf("Hello there, edited by hand.")
        pump(0.3)
        Self.snapshot(window.frame, name: "dictation-paused")
        pressKeyInSelf(UInt16(kVK_Return))
        pump(0.2)
        pressKeyInSelf(UInt16(kVK_Escape))
        pump(0.2)
        window.hide()

        #expect(pasted == "Hello there, edited by hand.")
        #expect(cancelled)
        #expect(window.frame.size == DictationComposerView.size)
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

    @Test("the Ask key's monitor tells Shift+Esc from Esc")
    func shiftEscapeReachesAsk() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let monitor = HotkeyMonitor(choice: .rightOption)
        var pressed: [String] = []
        monitor.onEscape = { pressed.append("esc") }
        monitor.onShiftEscape = { pressed.append("shift-esc") }
        monitor.escapeEnabled = true
        monitor.startMonitoring()
        defer { monitor.stopMonitoring() }
        pump(0.2)

        pressKeyInSelf(UInt16(kVK_Escape), flags: .maskShift)
        pressKeyInSelf(UInt16(kVK_Escape))
        pump(0.2)

        #expect(pressed == ["shift-esc", "esc"])
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
    /// Lets the app's own tasks (transcribing, answering) run; the main run loop keeps
    /// drawing meanwhile.
    private func run(_ seconds: TimeInterval) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

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

    /// Press, move in steps, release, the way a hand selects text.
    private func drag(from start: NSPoint, to end: NSPoint, in window: NSWindow) {
        queueMouse(.leftMouseDown, at: start, in: window)
        for step in 1...10 {
            let t = CGFloat(step) / 10
            queueMouse(.leftMouseDragged, at: NSPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t),
                       in: window)
        }
        queueMouse(.leftMouseUp, at: end, in: window)
        pump(0.4)
    }

    private func click(_ point: NSPoint, in window: NSWindow) {
        queueMouse(.leftMouseDown, at: point, in: window)
        queueMouse(.leftMouseUp, at: point, in: window)
        pump(0.3)
    }

    /// A mouse event (screen point, AppKit coordinates) queued for a window in this process:
    /// the real pointer never moves and no other app sees it. Queued rather than sent, since
    /// a text view's mouse-down runs its own loop that pulls the drag and release from the queue.
    private func queueMouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) {
        let event = NSEvent.mouseEvent(
            with: type, location: window.convertPoint(fromScreen: point), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
        if let event { NSApp.postEvent(event, atStart: false) }
    }

    /// Saves one window, even partly covered, when LOCALFLOW_SNAPSHOT_DIR is set.
    private static func snapshot(window number: Int?, name: String) {
        guard let dir = ProcessInfo.processInfo.environment["LOCALFLOW_SNAPSHOT_DIR"], let number else { return }
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", "\(number)", "\(dir)/\(name).png"]
        try? capture.run()
        capture.waitUntilExit()
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

/// A window owned by another process, standing in for Terminal: it comes in front over
/// the bubble, and can switch to itself like Cmd-Tab. It never touches any other app.
@MainActor
private final class OtherAppWindow {
    struct BuildFailed: Error {}

    private let process = Process()

    /// Compiled once per test, before anything is on screen.
    static func build() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("localflow-other-app-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = dir.appendingPathComponent("main.swift")
        let binary = dir.appendingPathComponent("other-app")
        try Self.source.write(to: source, atomically: true, encoding: .utf8)
        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
        compile.arguments = [source.path, "-o", binary.path]
        try compile.run()
        compile.waitUntilExit()
        guard compile.terminationStatus == 0 else { throw BuildFailed() }
        return binary
    }

    /// Returns once the window is up and in front; `activates` also switches to it.
    init(binary: URL, covering rect: NSRect, activates: Bool = false) throws {
        let output = Pipe()
        process.executableURL = binary
        process.arguments = [rect.minX, rect.minY, rect.width, rect.height].map { "\($0)" } + (activates ? ["activate"] : [])
        process.standardOutput = output
        try process.run()
        _ = output.fileHandleForReading.availableData
    }

    func close() {
        guard process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
    }

    private static let source = """
    import AppKit

    final class Cover: NSWindow {
        override var canBecomeKey: Bool { true }
    }

    let rect = CommandLine.arguments.dropFirst().compactMap { Double($0) }
    let activates = CommandLine.arguments.contains("activate")
    let app = NSApplication.shared
    // Launching would switch to it otherwise; Terminal is already the app in front.
    app.setActivationPolicy(activates ? .accessory : .prohibited)
    let cover = Cover(contentRect: NSRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3]),
                      styleMask: [.borderless], backing: .buffered, defer: false)
    cover.backgroundColor = .darkGray
    if activates { app.activate(ignoringOtherApps: true) }
    cover.orderFrontRegardless()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        print("ready")
        fflush(stdout)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 30) { exit(0) }
    app.run()
    """
}

/// Whatever was on the clipboard before a test that copies, put back afterwards, unless
/// someone copied something else in the meantime (the Mac is in use while tests run).
@MainActor
private final class SavedClipboard {
    private let items: [[NSPasteboard.PasteboardType: Data]]
    /// The clipboard's change count after the test's own last write.
    private var ours: Int

    init() {
        items = (NSPasteboard.general.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        }
        ours = NSPasteboard.general.changeCount
    }

    /// Clears it for the test, remembering that the clear was the test's.
    func clearForTest() {
        NSPasteboard.general.clearContents()
        ours = NSPasteboard.general.changeCount
    }

    /// What the app under test just copied; nil if something else changed it too.
    func copiedByTest() -> String? {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount == ours + 1 else { return nil }
        ours = pasteboard.changeCount
        return pasteboard.string(forType: .string)
    }

    func restore() {
        guard NSPasteboard.general.changeCount == ours else { return }
        NSPasteboard.general.clearContents()
        let restored = items.map { saved in
            let item = NSPasteboardItem()
            saved.forEach { item.setData($0.value, forType: $0.key) }
            return item
        }
        NSPasteboard.general.writeObjects(restored)
    }
}
