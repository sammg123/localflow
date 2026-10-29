import Foundation
import Testing
@testable import LocalFlow

@Suite("Agent mode: reading Claude Code's output")
struct AgentStreamTests {
    private func line(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private func toolResult(id: String, content: Any, isError: Bool? = nil) -> String {
        var block: [String: Any] = ["type": "tool_result", "tool_use_id": id, "content": content]
        if let isError { block["is_error"] = isError }
        return line(["type": "user", "message": ["role": "user", "content": [block]]])
    }

    @Test("the session starting")
    func sessionStarted() {
        let text = #"{"type":"system","subtype":"init","session_id":"abc-123","tools":["Bash"],"model":"m"}"#
        #expect(AgentStream.parse(line: text) == [.sessionStarted(sessionID: "abc-123")])
    }

    @Test("words as they stream")
    func textDelta() {
        let delta = line(["type": "stream_event", "event": [
            "type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "Opening Mail"],
        ]])
        #expect(AgentStream.parse(line: delta) == [.textDelta("Opening Mail")])
        let toolInput = line(["type": "stream_event", "event": [
            "type": "content_block_delta", "delta": ["type": "input_json_delta", "partial_json": "{\"co"],
        ]])
        #expect(AgentStream.parse(line: toolInput).isEmpty)
    }

    @Test("a tool starting, with its input as sent; the full text block is not repeated")
    func toolStarted() {
        let message = line(["type": "assistant", "message": ["content": [
            ["type": "text", "text": "I'll list the files."],
            ["type": "tool_use", "id": "toolu_1", "name": "Bash",
             "input": ["command": "ls -la", "description": "List files", "timeout": 5000]],
        ]]])
        let input: AgentJSON = ["command": "ls -la", "description": "List files", "timeout": 5000]
        #expect(AgentStream.parse(line: message) == [.toolStarted(id: "toolu_1", name: "Bash", input: input)])
    }

    @Test("an API error code on an assistant message")
    func apiError() {
        let text = #"{"type":"assistant","message":{"model":"<synthetic>","content":[]},"error":"authentication_failed"}"#
        #expect(AgentStream.parse(line: text) == [.apiError("authentication_failed")])
    }

    @Test("a tool's result, as short plain text")
    func toolFinished() {
        #expect(AgentStream.parse(line: toolResult(id: "toolu_1", content: "a.txt\nb.txt\n"))
            == [.toolFinished(id: "toolu_1", isError: false, summary: "a.txt\nb.txt")])
        let blocks: [[String: Any]] = [["type": "text", "text": "Clicked."],
                                       ["type": "image", "source": ["type": "base64", "data": "AAAA"]]]
        #expect(AgentStream.parse(line: toolResult(id: "toolu_2", content: blocks, isError: true))
            == [.toolFinished(id: "toolu_2", isError: true, summary: "Clicked.\n[image]")])
    }

    @Test("a long tool result is cut to 300 characters")
    func longResult() throws {
        let events = AgentStream.parse(line: toolResult(id: "t", content: String(repeating: "x", count: 5_000)))
        guard case .toolFinished(_, _, let summary) = try #require(events.first) else {
            Issue.record("expected a tool result")
            return
        }
        #expect(summary.count <= 300)
        #expect(summary.hasPrefix("xxxx"))
    }

    @Test("a permission prompt, with the input kept exactly")
    func permissionRequest() {
        let prompt = line(["type": "control_request", "request_id": "082651b0-1", "request": [
            "subtype": "can_use_tool", "tool_name": "Bash", "display_name": "Bash",
            "input": ["command": "touch probe-file.txt", "description": "Create empty probe file"],
            "description": "Create empty probe file", "permission_suggestions": [["type": "addRules"]],
            "blocked_path": "/tmp/probe-file.txt", "tool_use_id": "toolu_9",
        ]])
        let input: AgentJSON = ["command": "touch probe-file.txt", "description": "Create empty probe file"]
        #expect(AgentStream.parse(line: prompt) == [.permissionRequest(
            requestID: "082651b0-1", toolName: "Bash", input: input,
            description: "Create empty probe file", toolUseID: "toolu_9")])

        let bare = line(["type": "control_request", "request_id": "r2", "request": [
            "subtype": "can_use_tool", "tool_name": "mcp__localflow__click", "input": ["x": 10, "y": 20],
        ]])
        #expect(AgentStream.parse(line: bare) == [.permissionRequest(
            requestID: "r2", toolName: "mcp__localflow__click", input: ["x": 10, "y": 20],
            description: nil, toolUseID: nil)])
    }

    @Test("a tool Claude Code itself refused")
    func permissionDenied() {
        let text = line(["type": "system", "subtype": "permission_denied", "tool_name": "Write",
                         "tool_use_id": "toolu_3", "message": "denied"])
        #expect(AgentStream.parse(line: text) == [.permissionDenied(toolName: "Write")])
    }

    @Test("the end of a turn, finished or failed")
    func turnFinished() {
        #expect(AgentStream.parse(line: line(["type": "result", "subtype": "success", "is_error": false,
                                              "result": "Sent the email."]))
            == [.turnFinished(failure: nil, finalText: "Sent the email.")])
        #expect(AgentStream.parse(line: line(["type": "result", "subtype": "success", "is_error": true,
                                              "result": "Not logged in"]))
            == [.turnFinished(failure: "Not logged in", finalText: nil)])
        #expect(AgentStream.parse(line: line(["type": "result", "subtype": "error_max_turns", "is_error": true]))
            == [.turnFinished(failure: "it stopped without saying why", finalText: nil)])
    }

    @Test("the plan's usage limit, the same way Ask reads it")
    func usageLimit() {
        let rejected = #"{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":1793229600,"isUsingOverage":false}}"#
        #expect(AgentStream.parse(line: rejected) == [.usageLimit(resetsAt: Date(timeIntervalSince1970: 1_793_229_600))])
        let allowed = #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1793229600}}"#
        #expect(AgentStream.parse(line: allowed).isEmpty)
        let overage = #"{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","isUsingOverage":true}}"#
        #expect(AgentStream.parse(line: overage).isEmpty)
    }

    @Test("everything else is ignored", arguments: [
        #"{"type":"control_response","response":{"subtype":"success","request_id":"x"}}"#,
        #"{"type":"stream_event","event":{"type":"message_start"}}"#,
        #"{"type":"system","subtype":"status"}"#,
        #"{"type":"control_request","request_id":"h","request":{"subtype":"hook_callback"}}"#,
        "not json",
        "",
        "[1,2]",
    ])
    func ignored(text: String) {
        #expect(AgentStream.parse(line: text).isEmpty)
    }
}
