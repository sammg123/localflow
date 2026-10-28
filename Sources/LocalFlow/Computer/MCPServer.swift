import Foundation

/// A Model Context Protocol server over stdio: newline-delimited JSON-RPC 2.0, one
/// request handled at a time so actions never overlap. Malformed lines are skipped,
/// and a failed tool call is an error result, so a bad call never stops the server.
@MainActor
final class MCPServer {
    static let serverName = "localflow"
    static let serverVersion = "1.0"
    /// Used when a client's initialize doesn't say which version it speaks.
    static let defaultProtocolVersion = "2025-06-18"

    private enum ErrorCode {
        static let invalidRequest = -32600
        static let methodNotFound = -32601
        static let invalidParams = -32602
    }

    private let tools: ComputerTools
    private let log: (String) -> Void

    /// `log` gets method and tool names only, never arguments or results.
    init(tools: ComputerTools, log: @escaping (String) -> Void = { FlowLog.shared.write($0) }) {
        self.tools = tools
        self.log = log
    }

    /// Answers each line in order, until the input ends.
    func serve(_ lines: AsyncStream<String>, write: (String) throws -> Void) async {
        log("computer-mcp: started")
        for await line in lines {
            guard let reply = await reply(to: line) else { continue }
            do {
                try write(reply)
            } catch {
                log("computer-mcp: couldn't write a reply, stopping")
                return
            }
        }
        log("computer-mcp: input closed")
    }

    /// The reply line for one request line, or nil when there's nothing to say
    /// (a notification, a response, or something that isn't JSON-RPC).
    func reply(to line: String) async -> String? {
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
              let fields = message.objectValue,
              let id = fields["id"], id != .null else { return nil }
        guard let method = fields["method"]?.stringValue else {
            let isResponse = fields["result"] != nil || fields["error"] != nil
            return isResponse ? nil : encode(failure(id: id, code: ErrorCode.invalidRequest, "Invalid request"))
        }
        let params = fields["params"]?.objectValue ?? [:]
        return encode(await respond(id: id, method: method, params: params))
    }

    private func respond(id: JSONValue, method: String, params: [String: JSONValue]) async -> JSONValue {
        switch method {
        case "initialize":
            let version = params["protocolVersion"]?.stringValue ?? Self.defaultProtocolVersion
            return success(id: id, [
                "protocolVersion": .string(version),
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": .string(Self.serverName), "version": .string(Self.serverVersion)],
            ])
        case "ping":
            return success(id: id, [:])
        case "tools/list":
            return success(id: id, ["tools": .array(ComputerToolSchemas.all)])
        case "tools/call":
            guard let name = params["name"]?.stringValue else {
                return failure(id: id, code: ErrorCode.invalidParams, "tools/call needs a tool name")
            }
            log("computer-mcp: \(Self.loggable(name))")
            let result = await callTool(name, arguments: params["arguments"])
            if result.isError { log("computer-mcp: \(Self.loggable(name)) returned an error") }
            return success(id: id, result.json)
        default:
            return failure(id: id, code: ErrorCode.methodNotFound, "Method not found: \(method)")
        }
    }

    private func callTool(_ name: String, arguments: JSONValue?) async -> ToolResult {
        guard let arguments, arguments != .null else { return await tools.call(name, arguments: [:]) }
        guard let object = arguments.objectValue else { return .error("arguments must be an object.") }
        return await tools.call(name, arguments: object)
    }

    private static let knownTools = Set(ComputerToolSchemas.all.compactMap { $0["name"]?.stringValue })

    /// Tool names come from the client: log known ones, not whatever was sent.
    private static func loggable(_ name: String) -> String {
        knownTools.contains(name) ? name : "unknown tool"
    }

    private func success(id: JSONValue, _ result: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private func failure(id: JSONValue, code: Int, _ message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .int(code), "message": .string(message)]]
    }

    private func encode(_ message: JSONValue) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(message) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
