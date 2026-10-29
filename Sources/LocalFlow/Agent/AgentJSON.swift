import Foundation

/// A JSON value that round-trips unchanged, so a tool's input goes back to Claude Code
/// exactly as it came when the user allows it.
enum AgentJSON: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([AgentJSON])
    case object([String: AgentJSON])

    /// From what JSONSerialization gives back. Booleans stay booleans, not 0 and 1.
    init?(any: Any) {
        switch any {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            self = CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            let values = array.compactMap(AgentJSON.init(any:))
            guard values.count == array.count else { return nil }
            self = .array(values)
        case let object as [String: Any]:
            let pairs = object.compactMap { key, value in AgentJSON(any: value).map { (key, $0) } }
            guard pairs.count == object.count else { return nil }
            self = .object(Dictionary(uniqueKeysWithValues: pairs))
        default:
            return nil
        }
    }

    static func decode(_ data: Data) -> AgentJSON? {
        guard let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return AgentJSON(any: any)
    }

    /// Compact JSON with sorted keys and plain slashes.
    func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data("null".utf8)
    }

    subscript(key: String) -> AgentJSON? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var number: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var array: [AgentJSON]? {
        if case .array(let value) = self { return value }
        return nil
    }
}

extension AgentJSON: Encodable {
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension AgentJSON: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(floatLiteral value: Double) { self = .number(value) }
    init(arrayLiteral elements: AgentJSON...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, AgentJSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
