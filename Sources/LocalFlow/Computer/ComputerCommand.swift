import Foundation

/// A point in the agent's screenshot, in image pixels.
struct Pixel: Equatable, Sendable {
    let x: Int
    let y: Int
}

enum MouseButton: String, CaseIterable, Sendable {
    case left, right, middle
}

enum ScrollDirection: String, CaseIterable, Sendable {
    case up, down, left, right
}

/// A bad tool input, explained in a sentence the agent can act on.
struct ToolInputError: Error, Equatable, Sendable {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}

/// A checked tool call. Coordinates are still screenshot pixels here; whether they
/// fall inside the screenshot is checked when the call runs.
enum ComputerCommand: Equatable, Sendable {
    case screenshot
    case click(Pixel, button: MouseButton, clicks: Int, modifiers: Set<KeyCombo.Modifier>)
    case move(Pixel)
    case drag(from: Pixel, to: Pixel)
    case type(String)
    case key(KeyCombo, keys: String)
    case scroll(Pixel, direction: ScrollDirection, amount: Int)
    case openApp(String)
    case listApps
    case wait(seconds: Double)

    /// Longest text one type call takes; longer text goes in several calls.
    static let maxTypedCharacters = 5_000
    static let scrollAmounts = 1...20
    static let defaultScrollAmount = 3
    static let maxWaitSeconds = 10.0
    static let maxAppNameLength = 200

    static func parse(tool: String, arguments: [String: JSONValue]) throws -> ComputerCommand {
        let args = ToolArguments(tool: tool, values: arguments)
        switch tool {
        case "screenshot":
            return .screenshot
        case "click":
            _ = try args.optionalBool("irreversible")
            return .click(try args.pixel("x", "y"), button: try args.choice("button", default: .left),
                          clicks: try args.optionalInt("clicks", in: 1...3) ?? 1,
                          modifiers: try args.modifiers("modifiers"))
        case "move":
            return .move(try args.pixel("x", "y"))
        case "drag":
            return .drag(from: try args.pixel("from_x", "from_y"), to: try args.pixel("to_x", "to_y"))
        case "type":
            _ = try args.optionalBool("irreversible")
            return .type(try args.text("text", maxLength: maxTypedCharacters))
        case "key":
            _ = try args.optionalBool("irreversible")
            let keys = try args.text("keys", maxLength: 100).trimmingCharacters(in: .whitespaces)
            switch KeyCombo.parseResult(keys) {
            case .success(let combo): return .key(combo, keys: keys)
            case .failure(let error): throw ToolInputError(error.message)
            }
        case "scroll":
            return .scroll(try args.pixel("x", "y"), direction: try args.choice("direction", default: nil),
                           amount: try args.optionalInt("amount", in: scrollAmounts) ?? defaultScrollAmount)
        case "open_app":
            return .openApp(try appName(args))
        case "list_apps":
            return .listApps
        case "wait":
            return .wait(seconds: try args.number("seconds", in: 0...maxWaitSeconds))
        default:
            throw ToolInputError("Unknown tool \"\(tool)\".")
        }
    }

    private static func appName(_ args: ToolArguments) throws -> String {
        let name = try args.text("name", maxLength: maxAppNameLength).trimmingCharacters(in: .whitespaces)
        guard AppLocator.isValidName(name) else {
            throw ToolInputError("name must be an app name like Safari or a bundle id like com.apple.Safari, not a path.")
        }
        return name
    }
}

/// Reads typed values out of a tool's arguments, naming the field when one is wrong.
private struct ToolArguments {
    let tool: String
    let values: [String: JSONValue]

    func pixel(_ xKey: String, _ yKey: String) throws -> Pixel {
        Pixel(x: try coordinate(xKey), y: try coordinate(yKey))
    }

    private func coordinate(_ key: String) throws -> Int {
        guard let value = values[key], value != .null else {
            throw ToolInputError("\(tool) needs \(key): a whole number of pixels in the screenshot.")
        }
        guard let number = value.intValue else {
            throw ToolInputError("\(key) must be a whole number of pixels in the screenshot.")
        }
        guard number >= 0 else { throw ToolInputError("\(key) must be 0 or more.") }
        return number
    }

    func optionalInt(_ key: String, in range: ClosedRange<Int>) throws -> Int? {
        guard let value = values[key], value != .null else { return nil }
        guard let number = value.intValue, range.contains(number) else {
            throw ToolInputError("\(key) must be a whole number from \(range.lowerBound) to \(range.upperBound).")
        }
        return number
    }

    func optionalBool(_ key: String) throws -> Bool? {
        guard let value = values[key], value != .null else { return nil }
        guard let flag = value.boolValue else { throw ToolInputError("\(key) must be true or false.") }
        return flag
    }

    func number(_ key: String, in range: ClosedRange<Double>) throws -> Double {
        guard let number = values[key]?.doubleValue, number.isFinite, range.contains(number) else {
            throw ToolInputError("\(key) must be a number from \(Int(range.lowerBound)) to \(Int(range.upperBound)).")
        }
        return number
    }

    func text(_ key: String, maxLength: Int) throws -> String {
        guard let text = values[key]?.stringValue, !text.isEmpty else {
            throw ToolInputError("\(tool) needs \(key): a non-empty string.")
        }
        guard text.count <= maxLength else {
            throw ToolInputError("\(key) is too long (over \(maxLength) characters). Split it into several calls.")
        }
        return text
    }

    /// One of an enum's raw values; nil default means the field is required.
    func choice<Choice: RawRepresentable & CaseIterable>(_ key: String, default fallback: Choice?) throws -> Choice
    where Choice.RawValue == String {
        let options = Choice.allCases.map(\.rawValue).joined(separator: ", ")
        guard let value = values[key], value != .null else {
            if let fallback { return fallback }
            throw ToolInputError("\(tool) needs \(key): one of \(options).")
        }
        guard let raw = value.stringValue, let choice = Choice(rawValue: raw.lowercased()) else {
            throw ToolInputError("\(key) must be one of \(options).")
        }
        return choice
    }

    func modifiers(_ key: String) throws -> Set<KeyCombo.Modifier> {
        guard let value = values[key], value != .null else { return [] }
        guard let names = value.arrayValue else {
            throw ToolInputError("\(key) must be a list like [\"cmd\", \"shift\"].")
        }
        return Set(try names.map { name in
            guard let text = name.stringValue, let modifier = KeyCombo.Modifier.named(text) else {
                let shown = name.stringValue ?? "\(name)"
                throw ToolInputError("Unknown modifier \"\(shown)\" in \(key). Use cmd, shift, option or control.")
            }
            return modifier
        })
    }
}
