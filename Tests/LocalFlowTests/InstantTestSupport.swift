import Foundation
@testable import LocalFlow

/// A throwaway folder for one Instant Edits test: a fake home and fake git projects
/// inside it. Nothing outside it is ever read or written. Call `cleanUp()` when done.
struct InstantSandbox {
    let root: URL
    let home: String

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("instant-test-\(UUID().uuidString)")
        home = root.appendingPathComponent("home").path
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    }

    /// A folder with a `.git` folder in it, like a real project's top folder.
    @discardableResult
    func project(_ name: String = "app") throws -> String {
        let path = root.appendingPathComponent(name).path
        try FileManager.default.createDirectory(atPath: path + "/.git", withIntermediateDirectories: true)
        return path
    }

    /// A project folder inside the fake home, as the sweep would name one.
    @discardableResult
    func homeProject(_ name: String = "app", marker: String = ".git") throws -> String {
        let path = home + "/code/" + name
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        if marker == ".git" {
            try FileManager.default.createDirectory(atPath: path + "/.git", withIntermediateDirectories: true)
        } else if !marker.isEmpty {
            try write("{}\n", to: path + "/" + marker)
        }
        return path
    }

    /// Writes `text` at `path`, making its folders.
    @discardableResult
    func write(_ text: String, to path: String) throws -> String {
        try writeData(Data(text.utf8), to: path)
    }

    @discardableResult
    func writeData(_ data: Data, to path: String) throws -> String {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return path
    }

    func read(_ path: String) -> String? {
        (try? Data(contentsOf: URL(fileURLWithPath: path))).map { String(decoding: $0, as: UTF8.self) }
    }

    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    var backups: URL {
        root.appendingPathComponent("backups")
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

enum InstantInput {
    static func edit(_ path: String, _ old: String, _ new: String, replaceAll: Bool? = nil) -> AgentJSON {
        var fields: [String: AgentJSON] = ["file_path": .string(path), "old_string": .string(old),
                                           "new_string": .string(new)]
        if let replaceAll { fields["replace_all"] = .bool(replaceAll) }
        return .object(fields)
    }

    static func write(_ path: String, _ content: String) -> AgentJSON {
        ["file_path": .string(path), "content": .string(content)]
    }

    static func read(_ path: String) -> AgentJSON {
        ["file_path": .string(path)]
    }

    static func bash(_ command: String) -> AgentJSON {
        ["command": .string(command), "description": "x"]
    }
}

extension InstantDecision {
    var isAllowed: Bool { self == .allow }

    var message: String? {
        if case .deny(let message) = self { return message }
        return nil
    }
}

/// `count` numbered lines of Swift-like code, balanced.
func instantLines(_ count: Int) -> String {
    (1...count).map { "let value\($0) = \($0)" }.joined(separator: "\n") + "\n"
}
