import AppKit
import Carbon.HIToolbox

/// The real backend: posts mouse and keyboard events to the HID tap, takes screenshots
/// with ScreenCaptureKit, and opens apps with NSWorkspace. Nothing typed, pressed or
/// seen is logged.
@MainActor
final class LiveComputerBackend: ComputerBackend {
    /// Pauses that let the target app keep up, like a fast human.
    private enum Pause {
        static let afterMove: Duration = .milliseconds(50)
        static let betweenEvents: Duration = .milliseconds(10)
        static let betweenClicks: Duration = .milliseconds(60)
        static let betweenChunks: Duration = .milliseconds(15)
        static let dragSteps = 20
    }

    private let displayID: CGDirectDisplayID

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
    }

    func screenshot(size: CGSize) async throws -> Data {
        try await ComputerScreenshot.captureJPEG(displayID: displayID, size: size)
    }

    func click(at point: CGPoint, button: MouseButton, clicks: Int, modifiers: Set<KeyCombo.Modifier>) async throws {
        let events = try InputEvents()
        try await move(to: point)
        let flags = await events.holdModifiers(modifiers)
        // The tools only send 1 to 3, but never trust a caller with a range bound.
        let count = min(max(clicks, 1), 3)
        for clickNumber in 1...count {
            events.mouse(button.downType, at: point, button: button.cgButton, clickState: clickNumber, flags: flags)
            try? await Task.sleep(for: Pause.betweenEvents)
            events.mouse(button.upType, at: point, button: button.cgButton, clickState: clickNumber, flags: flags)
            if clickNumber < count { try? await Task.sleep(for: Pause.betweenClicks) }
        }
        await events.releaseModifiers(modifiers)
    }

    func move(to point: CGPoint) async throws {
        let events = try InputEvents()
        events.mouse(.mouseMoved, at: point, button: .left, clickState: 0, flags: [])
        try? await Task.sleep(for: Pause.afterMove)
    }

    func drag(from start: CGPoint, to end: CGPoint) async throws {
        let events = try InputEvents()
        try await move(to: start)
        events.mouse(.leftMouseDown, at: start, button: .left, clickState: 1, flags: [])
        try? await Task.sleep(for: Pause.afterMove)
        for step in 1...Pause.dragSteps {
            let progress = Double(step) / Double(Pause.dragSteps)
            let point = CGPoint(x: start.x + (end.x - start.x) * progress, y: start.y + (end.y - start.y) * progress)
            events.mouse(.leftMouseDragged, at: point, button: .left, clickState: 1, flags: [])
            try? await Task.sleep(for: Pause.betweenEvents)
        }
        try? await Task.sleep(for: Pause.afterMove)
        events.mouse(.leftMouseUp, at: end, button: .left, clickState: 1, flags: [])
    }

    func type(_ text: String) async throws {
        let events = try InputEvents()
        for chunk in TypingChunks.split(text) {
            switch chunk {
            case .text(let run): events.unicode(run)
            case .returnKey: await events.tap(CGKeyCode(kVK_Return), flags: [])
            }
            try? await Task.sleep(for: Pause.betweenChunks)
        }
    }

    func press(_ combo: KeyCombo) async throws {
        let events = try InputEvents()
        let held = await events.holdModifiers(combo.modifiers)
        await events.tap(combo.keyCode, flags: held.union(combo.keyFlags))
        await events.releaseModifiers(combo.modifiers)
    }

    func scroll(at point: CGPoint, direction: ScrollDirection, amount: Int) async throws {
        let events = try InputEvents()
        try await move(to: point)
        for _ in 0..<amount {
            events.scroll(direction, at: point)
            try? await Task.sleep(for: Pause.betweenChunks)
        }
    }

    func openApp(named name: String) async throws -> String {
        guard let url = appURL(for: name) else {
            let hints = AppLocator.suggestions(for: name)
            let hint = hints.isEmpty ? " Call list_apps to see what's running." : " Did you mean: \(hints.joined(separator: ", "))?"
            throw ComputerError("No app named \"\(name)\" was found.\(hint)")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            let app = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            app.activate()
            return app.localizedName ?? url.deletingPathExtension().lastPathComponent
        } catch {
            throw ComputerError("Couldn't open \(url.deletingPathExtension().lastPathComponent): \(error.localizedDescription)")
        }
    }

    func runningApps() -> [RunningApp] {
        AppList.running()
    }

    /// Bundle id first when it looks like one, then the Applications folders, then a
    /// running app with that name (Finder, for one, lives elsewhere).
    private func appURL(for name: String) -> URL? {
        let workspace = NSWorkspace.shared
        if AppLocator.looksLikeBundleID(name), let url = workspace.urlForApplication(withBundleIdentifier: name) {
            return url
        }
        if let url = AppLocator.find(name) { return url }
        if let url = workspace.urlForApplication(withBundleIdentifier: name) { return url }
        return workspace.runningApplications.first {
            $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame
        }?.bundleURL
    }
}

/// Builds and posts CGEvents from a private event source, so keys the user is holding
/// never mix into the agent's events.
@MainActor
private struct InputEvents {
    private let source: CGEventSource

    init() throws {
        guard AXIsProcessTrusted() else {
            throw ComputerError("LocalFlow needs Accessibility permission to control the mouse and keyboard "
                + "(System Settings > Privacy & Security > Accessibility).")
        }
        guard let source = CGEventSource(stateID: .privateState) else {
            throw ComputerError("Couldn't create keyboard and mouse events.")
        }
        self.source = source
    }

    func mouse(_ type: CGEventType, at point: CGPoint, button: CGMouseButton, clickState: Int, flags: CGEventFlags) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: button) else { return }
        if clickState > 0 { event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState)) }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    func key(_ code: CGKeyCode, down: Bool, flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    func tap(_ code: CGKeyCode, flags: CGEventFlags) async {
        key(code, down: true, flags: flags)
        try? await Task.sleep(for: .milliseconds(10))
        key(code, down: false, flags: flags)
    }

    /// Presses the modifier keys down in a fixed order and returns the flags they make.
    func holdModifiers(_ modifiers: Set<KeyCombo.Modifier>) async -> CGEventFlags {
        var held: CGEventFlags = []
        for modifier in KeyCombo.Modifier.allCases where modifiers.contains(modifier) {
            held.formUnion(modifier.flag)
            key(modifier.keyCode, down: true, flags: held)
            try? await Task.sleep(for: .milliseconds(10))
        }
        return held
    }

    func releaseModifiers(_ modifiers: Set<KeyCombo.Modifier>) async {
        var held = modifiers.reduce(CGEventFlags()) { $0.union($1.flag) }
        for modifier in KeyCombo.Modifier.allCases.reversed() where modifiers.contains(modifier) {
            held.subtract(modifier.flag)
            key(modifier.keyCode, down: false, flags: held)
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Up to 20 UTF-16 units as one key press, whatever the keyboard layout.
    func unicode(_ text: String) {
        let units = Array(text.utf16)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
            event.flags = []
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            event.post(tap: .cghidEventTap)
        }
    }

    /// One wheel notch. Positive wheel values scroll up (vertical) and left (horizontal).
    func scroll(_ direction: ScrollDirection, at point: CGPoint) {
        let (vertical, horizontal): (Int32, Int32) = switch direction {
        case .up: (1, 0)
        case .down: (-1, 0)
        case .left: (0, 1)
        case .right: (0, -1)
        }
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2,
                                  wheel1: vertical, wheel2: horizontal, wheel3: 0) else { return }
        event.location = point
        event.post(tap: .cghidEventTap)
    }
}

private extension MouseButton {
    var cgButton: CGMouseButton {
        switch self {
        case .left: return .left
        case .right: return .right
        case .middle: return .center
        }
    }

    var downType: CGEventType {
        switch self {
        case .left: return .leftMouseDown
        case .right: return .rightMouseDown
        case .middle: return .otherMouseDown
        }
    }

    var upType: CGEventType {
        switch self {
        case .left: return .leftMouseUp
        case .right: return .rightMouseUp
        case .middle: return .otherMouseUp
        }
    }
}
