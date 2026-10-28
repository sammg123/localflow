import CoreGraphics
import Foundation

/// The real-world side of the tools: screen, mouse, keyboard and apps. Points are
/// global CGEvent points; the tools have already checked and converted them.
@MainActor
protocol ComputerBackend: AnyObject {
    /// A JPEG of the display at exactly this size.
    func screenshot(size: CGSize) async throws -> Data
    func click(at point: CGPoint, button: MouseButton, clicks: Int, modifiers: Set<KeyCombo.Modifier>) async throws
    func move(to point: CGPoint) async throws
    func drag(from start: CGPoint, to end: CGPoint) async throws
    func type(_ text: String) async throws
    func press(_ combo: KeyCombo) async throws
    func scroll(at point: CGPoint, direction: ScrollDirection, amount: Int) async throws
    /// Opens or switches to the app and returns the name it goes by.
    func openApp(named name: String) async throws -> String
    func runningApps() -> [RunningApp]
}

/// Something the backend couldn't do, in words the agent can act on.
struct ComputerError: Error, Equatable, Sendable, LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

/// What a tool call returns to the agent.
struct ToolResult: Equatable, Sendable {
    enum Content: Equatable, Sendable {
        case text(String)
        case jpeg(Data)
    }

    let content: [Content]
    let isError: Bool

    static func text(_ text: String) -> ToolResult {
        ToolResult(content: [.text(text)], isError: false)
    }

    static func error(_ text: String) -> ToolResult {
        ToolResult(content: [.text(text)], isError: true)
    }

    var json: JSONValue {
        let items: [JSONValue] = content.map { item in
            switch item {
            case .text(let text):
                return ["type": "text", "text": .string(text)]
            case .jpeg(let data):
                return ["type": "image", "data": .string(data.base64EncodedString()), "mimeType": "image/jpeg"]
            }
        }
        return isError ? ["content": .array(items), "isError": true] : ["content": .array(items)]
    }
}

/// Runs one tool call: checks the arguments, maps screenshot pixels to the display,
/// and asks the backend. Every failure becomes an error result, never a crash.
@MainActor
final class ComputerTools {
    private let backend: ComputerBackend
    private let mapping: () -> ScreenMapping?

    /// `mapping` is asked on every call, so a display that changes resolution or
    /// goes away is noticed. Nil means it's gone.
    init(backend: ComputerBackend, mapping: @escaping () -> ScreenMapping?) {
        self.backend = backend
        self.mapping = mapping
    }

    func call(_ tool: String, arguments: [String: JSONValue]) async -> ToolResult {
        do {
            let command = try ComputerCommand.parse(tool: tool, arguments: arguments)
            return try await run(command)
        } catch let error as ToolInputError {
            return .error(error.message)
        } catch let error as ComputerError {
            return .error(error.message)
        } catch {
            return .error("\(tool) failed: \(error.localizedDescription)")
        }
    }

    private func run(_ command: ComputerCommand) async throws -> ToolResult {
        switch command {
        case .screenshot:
            let screen = try currentMapping()
            let jpeg = try await backend.screenshot(size: screen.imageSize)
            let note = "Screen \(screen.imageWidth)x\(screen.imageHeight). "
                + "Coordinates for other tools are pixels in this image."
            return ToolResult(content: [.jpeg(jpeg), .text(note)], isError: false)
        case .click(let pixel, let button, let clicks, let modifiers):
            try await backend.click(at: try point(pixel), button: button, clicks: clicks, modifiers: modifiers)
            let kind = [2: "Double-clicked", 3: "Triple-clicked"][clicks] ?? "Clicked"
            return .text("\(kind) \(button.rawValue) at \(pixel.x),\(pixel.y)")
        case .move(let pixel):
            try await backend.move(to: try point(pixel))
            return .text("Moved to \(pixel.x),\(pixel.y)")
        case .drag(let start, let end):
            try await backend.drag(from: try point(start), to: try point(end))
            return .text("Dragged from \(start.x),\(start.y) to \(end.x),\(end.y)")
        case .type(let text):
            try await backend.type(text)
            return .text("Typed \(text.count) characters")
        case .key(let combo, let keys):
            try await backend.press(combo)
            return .text("Pressed \(keys)")
        case .scroll(let pixel, let direction, let amount):
            try await backend.scroll(at: try point(pixel), direction: direction, amount: amount)
            return .text("Scrolled \(direction.rawValue) \(amount) at \(pixel.x),\(pixel.y)")
        case .openApp(let name):
            return .text("Opened \(try await backend.openApp(named: name))")
        case .listApps:
            return .text(AppList.describe(backend.runningApps()))
        case .wait(let seconds):
            try await Task.sleep(for: .seconds(seconds))
            return .text("Waited \(String(format: "%g", seconds))s")
        }
    }

    private func currentMapping() throws -> ScreenMapping {
        guard let screen = mapping() else {
            throw ComputerError("The display this agent controls isn't connected any more.")
        }
        return screen
    }

    private func point(_ pixel: Pixel) throws -> CGPoint {
        let screen = try currentMapping()
        guard screen.contains(x: pixel.x, y: pixel.y) else {
            throw ToolInputError("\(pixel.x),\(pixel.y) is outside the screenshot "
                + "(\(screen.imageWidth)x\(screen.imageHeight)). Take a new screenshot and use its pixels.")
        }
        return screen.toGlobal(x: Double(pixel.x), y: Double(pixel.y))
    }
}
