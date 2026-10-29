import Foundation

/// What happens in an agent session, read off Claude Code's stream-json output.
enum AgentEvent: Equatable, Sendable {
    case sessionStarted(sessionID: String)
    /// Words of the reply as they stream.
    case textDelta(String)
    case toolStarted(id: String, name: String, input: AgentJSON)
    /// `summary` is the start of what the tool gave back, as plain text.
    case toolFinished(id: String, isError: Bool, summary: String)
    /// Claude Code wants to use a tool and is waiting for the host's answer.
    case permissionRequest(requestID: String, toolName: String, input: AgentJSON, description: String?,
                           toolUseID: String?)
    /// Claude Code refused a tool by itself.
    case permissionDenied(toolName: String)
    /// A turn ended; `failure` is what it said when it failed, `finalText` the reply.
    case turnFinished(failure: String?, finalText: String?)
    /// The plan's usage limit is hit and no extra usage is covering it.
    case usageLimit(resetsAt: Date?)
    /// An error code on an assistant message, such as authentication_failed.
    case apiError(String)
    /// The session is over. Only the runner sends this; `nil` means it was closed.
    case ended(AskError?)
}

/// Reads one line of Claude Code's output into the events that matter to the agent.
enum AgentStream {
    /// A tool result is shown as at most this many characters.
    static let summaryLimit = 300
    static let noReason = "it stopped without saying why"

    static func parse(line: String) -> [AgentEvent] {
        guard let json = AgentJSON.decode(Data(line.utf8)) else { return [] }
        switch json["type"]?.string {
        case "system":
            return system(json)
        case "stream_event":
            return textDelta(json["event"]).map { [.textDelta($0)] } ?? []
        case "assistant":
            return assistant(json)
        case "user":
            return toolResults(json["message"]?["content"])
        case "control_request":
            return permissionRequest(json).map { [$0] } ?? []
        case "rate_limit_event":
            // Same rule as Ask: extra usage can still pay, so only a real stop counts.
            guard case .usageLimit(let resetsAt)? = ClaudeStreamEvent.parse(line: line) else { return [] }
            return [.usageLimit(resetsAt: resetsAt)]
        case "result":
            return [result(json)]
        default:
            return []
        }
    }

    private static func system(_ json: AgentJSON) -> [AgentEvent] {
        switch json["subtype"]?.string {
        case "init":
            return json["session_id"]?.string.map { [.sessionStarted(sessionID: $0)] } ?? []
        case "permission_denied":
            return json["tool_name"]?.string.map { [.permissionDenied(toolName: $0)] } ?? []
        default:
            return []
        }
    }

    private static func textDelta(_ event: AgentJSON?) -> String? {
        guard let event, event["type"]?.string == "content_block_delta",
              let delta = event["delta"], delta["type"]?.string == "text_delta",
              let text = delta["text"]?.string, !text.isEmpty else { return nil }
        return text
    }

    /// Tools starting. Text blocks are skipped: their words already came as deltas.
    private static func assistant(_ json: AgentJSON) -> [AgentEvent] {
        let blocks = json["message"]?["content"]?.array ?? []
        let tools: [AgentEvent] = blocks.compactMap { block in
            guard block["type"]?.string == "tool_use", let id = block["id"]?.string,
                  let name = block["name"]?.string else { return nil }
            return .toolStarted(id: id, name: name, input: block["input"] ?? [:])
        }
        let error = json["error"]?.string.map { [AgentEvent.apiError($0)] } ?? []
        return tools + error
    }

    private static func toolResults(_ content: AgentJSON?) -> [AgentEvent] {
        (content?.array ?? []).compactMap { block in
            guard block["type"]?.string == "tool_result", let id = block["tool_use_id"]?.string else { return nil }
            return .toolFinished(id: id, isError: block["is_error"]?.bool ?? false, summary: summary(block["content"]))
        }
    }

    /// A tool result's text, images as [image], cut to the limit.
    static func summary(_ content: AgentJSON?) -> String {
        let text: String
        switch content {
        case .string(let value)?:
            text = value
        case .array(let blocks)?:
            text = blocks.compactMap { block in
                switch block["type"]?.string {
                case "text": return block["text"]?.string
                case "image": return "[image]"
                default: return nil
                }
            }.joined(separator: "\n")
        default:
            text = ""
        }
        return String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(summaryLimit))
    }

    private static func permissionRequest(_ json: AgentJSON) -> AgentEvent? {
        guard let id = json["request_id"]?.string, let request = json["request"],
              request["subtype"]?.string == "can_use_tool", let tool = request["tool_name"]?.string else { return nil }
        return .permissionRequest(requestID: id, toolName: tool, input: request["input"] ?? [:],
                                  description: request["description"]?.string,
                                  toolUseID: request["tool_use_id"]?.string)
    }

    private static func result(_ json: AgentJSON) -> AgentEvent {
        let text = json["result"]?.string
        guard json["is_error"]?.bool == true else { return .turnFinished(failure: nil, finalText: text) }
        let failure = text.flatMap { $0.isEmpty ? nil : $0 } ?? noReason
        return .turnFinished(failure: failure, finalText: nil)
    }
}
