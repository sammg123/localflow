import CoreGraphics
import Foundation
import Testing
@testable import LocalFlow

/// Records what the tools asked for instead of touching the real mouse, keyboard or screen.
@MainActor
final class FakeComputerBackend: ComputerBackend {
    private(set) var calls: [String] = []
    var failure: ComputerError?
    var apps: [RunningApp] = []
    let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0])

    func screenshot(size: CGSize) async throws -> Data {
        try record("screenshot \(Int(size.width))x\(Int(size.height))")
        return jpeg
    }

    func click(at point: CGPoint, button: MouseButton, clicks: Int, modifiers: Set<KeyCombo.Modifier>) async throws {
        let held = modifiers.map(\.rawValue).sorted().joined(separator: "+")
        try record("click \(point.x),\(point.y) \(button.rawValue) x\(clicks) [\(held)]")
    }

    func move(to point: CGPoint) async throws {
        try record("move \(point.x),\(point.y)")
    }

    func drag(from start: CGPoint, to end: CGPoint) async throws {
        try record("drag \(start.x),\(start.y) -> \(end.x),\(end.y)")
    }

    func type(_ text: String) async throws {
        try record("type \(text)")
    }

    func press(_ combo: KeyCombo) async throws {
        try record("press \(combo.keyCode) \(combo.modifiers.map(\.rawValue).sorted())")
    }

    func scroll(at point: CGPoint, direction: ScrollDirection, amount: Int) async throws {
        try record("scroll \(point.x),\(point.y) \(direction.rawValue) \(amount)")
    }

    func openApp(named name: String) async throws -> String {
        try record("open \(name)")
        return name
    }

    func runningApps() -> [RunningApp] {
        calls.append("list")
        return apps
    }

    private func record(_ call: String) throws {
        calls.append(call)
        if let failure { throw failure }
    }
}

@MainActor
@Suite("Computer: MCP server over JSON-RPC")
struct ComputerMCPServerTests {
    nonisolated static let laptop = ScreenMapping(displayBounds: CGRect(x: 0, y: 0, width: 1512, height: 982))

    private let backend = FakeComputerBackend()

    private func makeServer(mapping: ScreenMapping? = laptop) -> MCPServer {
        MCPServer(tools: ComputerTools(backend: backend, mapping: { mapping }), log: { _ in })
    }

    private func line(_ message: JSONValue) throws -> String {
        String(decoding: try JSONEncoder().encode(message), as: UTF8.self)
    }

    private func send(_ server: MCPServer, id: JSONValue = 1, method: String,
                      params: JSONValue = [:]) async throws -> JSONValue {
        let request: JSONValue = ["jsonrpc": "2.0", "id": id, "method": .string(method), "params": params]
        let reply = try #require(await server.reply(to: try line(request)))
        #expect(!reply.contains("\n"))
        return try JSONDecoder().decode(JSONValue.self, from: Data(reply.utf8))
    }

    private func call(_ server: MCPServer, _ tool: String, _ arguments: JSONValue = [:]) async throws -> JSONValue {
        let reply = try await send(server, method: "tools/call", params: ["name": .string(tool), "arguments": arguments])
        return try #require(reply["result"])
    }

    private func texts(_ result: JSONValue) -> [String] {
        (result["content"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }
    }

    @Test("initialize echoes the protocol version and names the server")
    func initialize() async throws {
        let reply = try await send(makeServer(), id: 1, method: "initialize",
                                   params: ["protocolVersion": "2025-03-26", "capabilities": [:]])

        #expect(reply["jsonrpc"] == "2.0")
        #expect(reply["id"] == 1)
        let result = try #require(reply["result"])
        #expect(result["protocolVersion"] == "2025-03-26")
        #expect(result["capabilities"] == ["tools": [:]])
        #expect(result["serverInfo"] == ["name": "localflow", "version": "1.0"])
    }

    @Test("notifications get no reply, and ping gets an empty result")
    func notificationsAndPing() async throws {
        let server = makeServer()
        let initialized: JSONValue = ["jsonrpc": "2.0", "method": "notifications/initialized"]

        #expect(await server.reply(to: try line(initialized)) == nil)
        let ping = try await send(server, id: "abc", method: "ping")
        #expect(ping["id"] == "abc")
        #expect(ping["result"] == [:])
    }

    @Test("tools/list returns the ten tools with object schemas and their required fields")
    func toolsList() async throws {
        let reply = try await send(makeServer(), method: "tools/list")
        let tools = try #require(reply["result"]?["tools"]?.arrayValue)
        let byName = Dictionary(uniqueKeysWithValues: tools.compactMap { tool in
            tool["name"]?.stringValue.map { ($0, tool) }
        })
        let required: [String: [String]] = [
            "screenshot": [], "click": ["x", "y"], "move": ["x", "y"],
            "drag": ["from_x", "from_y", "to_x", "to_y"], "type": ["text"], "key": ["keys"],
            "scroll": ["x", "y", "direction"], "open_app": ["name"], "list_apps": [], "wait": ["seconds"],
        ]

        #expect(tools.count == 10)
        #expect(Set(byName.keys) == Set(required.keys))
        for (name, fields) in required {
            let tool = try #require(byName[name])
            let schema = try #require(tool["inputSchema"])
            #expect(schema["type"] == "object", "\(name)")
            #expect(schema["properties"]?.objectValue != nil, "\(name)")
            #expect(schema["required"]?.arrayValue?.compactMap(\.stringValue) == fields, "\(name)")
            #expect(tool["description"]?.stringValue?.isEmpty == false, "\(name)")
            for field in fields {
                #expect(schema["properties"]?[field] != nil, "\(name).\(field)")
            }
        }
        for name in ["click", "type", "key"] {
            let irreversible = byName[name]?["inputSchema"]?["properties"]?["irreversible"]
            #expect(irreversible?["type"] == "boolean")
            #expect(irreversible?["description"]?.stringValue
                == "Set true when this action sends, posts, submits, buys, deletes, or otherwise can't be undone.")
        }
    }

    @Test("a screenshot comes back as a JPEG and the image size")
    func screenshot() async throws {
        let result = try await call(makeServer(), "screenshot")
        let content = try #require(result["content"]?.arrayValue)

        #expect(content.count == 2)
        #expect(content[0]["type"] == "image")
        #expect(content[0]["mimeType"] == "image/jpeg")
        #expect(content[0]["data"]?.stringValue == backend.jpeg.base64EncodedString())
        #expect(content[1]["type"] == "text")
        #expect(content[1]["text"] == "Screen 1280x831. Coordinates for other tools are pixels in this image.")
        #expect(result["isError"] == nil || result["isError"] == false)
        #expect(backend.calls == ["screenshot 1280x831"])
    }

    @Test("a click turns screenshot pixels into global points")
    func click() async throws {
        let result = try await call(makeServer(), "click",
                                    ["x": 640, "y": 415, "button": "right", "clicks": 2,
                                     "modifiers": ["cmd"], "irreversible": true])

        #expect(result["isError"] == nil || result["isError"] == false)
        #expect(backend.calls == ["click 756.0,490.21875 right x2 [command]"])
        #expect(!texts(result).isEmpty)
    }

    @Test("move, drag, scroll, type and key reach the backend")
    func otherActions() async throws {
        let server = makeServer()

        _ = try await call(server, "move", ["x": 0, "y": 0])
        _ = try await call(server, "drag", ["from_x": 0, "from_y": 0, "to_x": 640, "to_y": 0])
        _ = try await call(server, "scroll", ["x": 640, "y": 415, "direction": "down"])
        _ = try await call(server, "type", ["text": "hello"])
        _ = try await call(server, "key", ["keys": "cmd+a"])

        #expect(backend.calls == [
            "move 0.0,0.0",
            "drag 0.0,0.0 -> 756.0,0.0",
            "scroll 756.0,490.21875 down 3",
            "type hello",
            "press 0 [\"command\"]",
        ])
    }

    @Test("a click outside the screenshot is an error result and nothing is clicked")
    func outsideImage() async throws {
        let result = try await call(makeServer(), "click", ["x": 1280, "y": 10])

        #expect(result["isError"] == true)
        #expect(texts(result).first?.contains("outside") == true)
        #expect(backend.calls.isEmpty)
    }

    @Test("bad arguments come back as an error result, not a protocol error")
    func badArguments() async throws {
        let server = makeServer()
        let reply = try await send(server, method: "tools/call",
                                   params: ["name": "click", "arguments": ["x": "ten", "y": 5]])

        #expect(reply["error"] == nil)
        #expect(reply["result"]?["isError"] == true)
        #expect(texts(try #require(reply["result"])).first?.contains("x") == true)
        let unknownKey = try await call(server, "key", ["keys": "cmd+hyper"])
        #expect(unknownKey["isError"] == true)
        #expect(texts(unknownKey).first?.contains("hyper") == true)
        let unknownTool = try await call(server, "teleport")
        #expect(unknownTool["isError"] == true)
        #expect(backend.calls.isEmpty)
    }

    @Test("a backend failure comes back as an error result with its message")
    func backendFailure() async throws {
        backend.failure = ComputerError("LocalFlow needs Accessibility permission.")

        let result = try await call(makeServer(), "type", ["text": "hi"])

        #expect(result["isError"] == true)
        #expect(texts(result) == ["LocalFlow needs Accessibility permission."])
    }

    @Test("when the display is gone, screen tools explain instead of acting")
    func displayGone() async throws {
        let server = makeServer(mapping: nil)

        let click = try await call(server, "click", ["x": 1, "y": 1])
        let screenshot = try await call(server, "screenshot")
        let typed = try await call(server, "type", ["text": "still works"])

        #expect(click["isError"] == true)
        #expect(screenshot["isError"] == true)
        #expect(typed["isError"] == nil || typed["isError"] == false)
        #expect(backend.calls == ["type still works"])
    }

    @Test("list_apps names the running apps and the frontmost one")
    func listApps() async throws {
        backend.apps = [
            RunningApp(name: "Safari", bundleID: "com.apple.Safari", isFrontmost: true),
            RunningApp(name: "Finder", bundleID: "com.apple.finder", isFrontmost: false),
        ]

        let text = try #require(texts(try await call(makeServer(), "list_apps")).first)

        #expect(text.contains("Safari (com.apple.Safari)"))
        #expect(text.contains("Finder (com.apple.finder)"))
        #expect(text.contains("Frontmost: Safari"))
    }

    @Test("open_app and wait report what they did")
    func openAndWait() async throws {
        let server = makeServer()

        #expect(texts(try await call(server, "open_app", ["name": "Safari"])) == ["Opened Safari"])
        #expect(texts(try await call(server, "wait", ["seconds": 0.01])) == ["Waited 0.01s"])
        #expect(backend.calls == ["open Safari"])
    }

    @Test("an unknown method with an id gets error -32601")
    func unknownMethod() async throws {
        let reply = try await send(makeServer(), id: 7, method: "resources/list")

        #expect(reply["id"] == 7)
        #expect(reply["error"]?["code"] == -32601)
        #expect(reply["result"] == nil)
    }

    @Test("malformed lines and tool calls without an id are ignored", arguments: [
        "not json", "{", "", "   ", "[1,2]", #"{"jsonrpc":"2.0","id":3,"result":{}}"#,
        #"{"jsonrpc":"2.0","method":"tools/call","params":{"name":"click","arguments":{"x":1,"y":1}}}"#,
    ])
    func ignored(line: String) async {
        #expect(await makeServer().reply(to: line) == nil)
        #expect(backend.calls.isEmpty)
    }

    @Test("serve answers each line in order and returns when input ends")
    func serve() async throws {
        let server = makeServer()
        let (lines, input) = AsyncStream.makeStream(of: String.self)
        input.yield(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
        input.yield("garbage")
        input.yield(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        input.finish()
        var written: [String] = []

        await server.serve(lines) { written.append($0) }

        #expect(written.count == 2)
        #expect(written.first?.contains(#""id":1"#) == true)
        #expect(written.last?.contains(#""id":2"#) == true)
    }
}
