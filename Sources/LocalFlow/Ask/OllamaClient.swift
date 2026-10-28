import Foundation

/// One finished question and answer, kept so follow-ups have context.
struct AskTurn: Equatable {
    let question: String
    let answer: String
}

/// What a follow-up carries from the current chat. Text only; old screenshots are
/// never kept or re-sent.
enum AskMemory {
    /// The newest turns whose text fits `budget` characters, oldest dropped first.
    static func fitting(_ turns: [AskTurn], budget: Int) -> [AskTurn] {
        var used = 0
        var kept: [AskTurn] = []
        for turn in turns.reversed() {
            used += turn.question.count + turn.answer.count
            guard used <= budget else { break }
            kept.insert(turn, at: 0)
        }
        return kept
    }
}

/// The /api/chat request Ask sends to the local Ollama server.
struct OllamaChatBody: Encodable, Equatable {
    struct Message: Encodable, Equatable {
        let role: String
        let content: String
        let images: [String]?
    }

    struct Options: Encodable, Equatable {
        let temperature: Double
        let numCtx: Int
        let numPredict: Int

        enum CodingKeys: String, CodingKey {
            case temperature
            case numCtx = "num_ctx"
            case numPredict = "num_predict"
        }
    }

    /// How long the model stays in memory after an ask. Short, so ~6 GB isn't held
    /// all day; a follow-up within the window answers without reloading.
    static let keepAlive = "5m"

    static let systemPrompt = """
    You are LocalFlow Ask. The image is a screenshot of the user's screen right now, exactly \
    what they are looking at. They asked a question out loud (it was transcribed, so it may \
    have small errors). Answer it from what is on the screen. Lead with the answer in one or \
    two sentences, then add detail only if it helps. Stay under 120 words. No headings and no \
    tables. Put code in fenced code blocks. Earlier questions and answers in this conversation \
    were about earlier screenshots you can no longer see; use them only as context for \
    follow-ups. The attached image is the screen right now.
    """

    let model: String
    let messages: [Message]
    let stream: Bool
    let think: Bool
    let keepAlive: String
    let options: Options

    enum CodingKeys: String, CodingKey {
        case model, messages, stream, think, options
        case keepAlive = "keep_alive"
    }

    static func ask(model: String, question: String, imageBase64: String,
                    history: [AskTurn] = []) -> OllamaChatBody {
        let earlier = history.flatMap { turn in
            [Message(role: "user", content: turn.question, images: nil),
             Message(role: "assistant", content: turn.answer, images: nil)]
        }
        return OllamaChatBody(
            model: model,
            messages: [Message(role: "system", content: systemPrompt, images: nil)]
                + earlier
                + [Message(role: "user", content: question, images: [imageBase64])],
            stream: true,
            // Thinking mode took over 5 minutes per answer on qwen3.5:9b in testing.
            think: false,
            keepAlive: keepAlive,
            options: Options(temperature: 0.2, numCtx: 8192, numPredict: 700)
        )
    }
}

/// One line of Ollama's newline-delimited JSON stream, as events.
enum OllamaStreamEvent: Equatable {
    case token(String)
    case done
    case failed(String)

    private struct Line: Decodable {
        struct Message: Decodable { let content: String? }
        let message: Message?
        let done: Bool?
        let error: String?
    }

    static func parse(line: String) -> [OllamaStreamEvent] {
        guard let data = line.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Line.self, from: data) else { return [] }
        if let error = decoded.error { return [.failed(error)] }
        var events: [OllamaStreamEvent] = []
        if let content = decoded.message?.content, !content.isEmpty { events.append(.token(content)) }
        if decoded.done == true { events.append(.done) }
        return events
    }
}

enum AskError: Error, Equatable {
    case ollamaNotRunning
    case modelMissing(String)
    case ollama(String)
    case timedOut
    case screenCaptureFailed(String)
    /// The Codex tool (for ChatGPT answers) isn't on this Mac.
    case chatGPTMissing
    case chatGPTSignedOut
    /// The ChatGPT workspace (a school or company plan) doesn't allow Codex from the
    /// command-line tool, which is how Ask reaches it. Only its admin can change that.
    case chatGPTWorkspaceBlocked
    case chatGPT(String)

    /// The kind of failure, for the log. Never the text inside it, which can echo what
    /// the user asked.
    var logName: String {
        switch self {
        case .ollamaNotRunning: return "ollamaNotRunning"
        case .modelMissing: return "modelMissing"
        case .ollama: return "ollama"
        case .timedOut: return "timedOut"
        case .screenCaptureFailed: return "screenCaptureFailed"
        case .chatGPTMissing: return "chatGPTMissing"
        case .chatGPTSignedOut: return "chatGPTSignedOut"
        case .chatGPTWorkspaceBlocked: return "chatGPTWorkspaceBlocked"
        case .chatGPT: return "chatGPT"
        }
    }

    /// What the answer bubble says. Written for the user, with the fix in it.
    var message: String {
        switch self {
        case .ollamaNotRunning:
            return "Ollama isn't running, so there's no model to ask. Start it, then ask again."
        case .modelMissing(let model):
            return "The \(model) model isn't downloaded. Run: ollama pull \(model)"
        case .ollama(let detail):
            return "The model failed: \(detail)"
        case .timedOut:
            return "The model took too long to answer. Ask again in a moment."
        case .screenCaptureFailed(let detail):
            return "Couldn't capture the screen: \(detail)"
        case .chatGPTMissing:
            return "ChatGPT answers use the Codex tool that comes with the ChatGPT app, and it isn't on this Mac. "
                + "Install the ChatGPT app, or switch Ask to the local model in Settings."
        case .chatGPTSignedOut:
            return "Codex isn't signed in to your ChatGPT account. Open the ChatGPT app, sign in to Codex, then ask again."
        case .chatGPTWorkspaceBlocked:
            return "Your ChatGPT workspace only allows Codex in the Codex app, not the command-line tool Ask uses. "
                + "Switch Ask to the local model in Settings, or sign Codex in with a personal ChatGPT plan."
        case .chatGPT(let detail):
            return "ChatGPT failed: \(detail)"
        }
    }

    static func fromHTTP(status: Int, body: Data, model: String) -> AskError {
        let detail = (try? JSONDecoder().decode([String: String].self, from: body))?["error"]
        if status == 404 || detail?.contains("not found") == true { return .modelMissing(model) }
        return .ollama(detail ?? "HTTP \(status)")
    }

    static func from(_ error: URLError) -> AskError {
        switch error.code {
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost:
            return .ollamaNotRunning
        case .timedOut:
            return .timedOut
        default:
            return .ollama(error.localizedDescription)
        }
    }
}

/// The model Ask talks to. A protocol so the flow can be exercised without a server.
protocol AskModelClient: Sendable {
    /// Load the model into memory ahead of the question, without generating anything.
    func preload(model: String) async
    func stream(_ body: OllamaChatBody) -> AsyncThrowingStream<String, Error>
}

/// Talks to Ollama on this Mac only (127.0.0.1). Nothing leaves the machine.
struct OllamaClient: AskModelClient {
    static let defaultBaseURL = URL(string: "http://127.0.0.1:11434")!
    /// Longest silence allowed between streamed chunks, including the cold load.
    static let idleTimeout: TimeInterval = 90

    private let baseURL: URL
    private let session: URLSession

    init(baseURL: URL = defaultBaseURL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    func preload(model: String) async {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = Self.idleTimeout
        request.httpBody = try? JSONEncoder().encode(["model": model, "keep_alive": OllamaChatBody.keepAlive])
        do {
            _ = try await session.data(for: request)
        } catch {
            // The ask itself reports the real failure; this only warms the model.
            FlowLog.shared.write("ask preload failed: \(error.localizedDescription)")
        }
    }

    func stream(_ body: OllamaChatBody) -> AsyncThrowingStream<String, Error> {
        let session = self.session
        let url = baseURL.appendingPathComponent("api/chat")
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.timeoutInterval = Self.idleTimeout
                    request.httpBody = try JSONEncoder().encode(body)

                    let (bytes, response) = try await session.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else {
                        var data = Data()
                        for try await byte in bytes { data.append(byte) }
                        throw AskError.fromHTTP(status: status, body: data, model: body.model)
                    }
                    for try await line in bytes.lines {
                        for event in OllamaStreamEvent.parse(line: line) {
                            switch event {
                            case .token(let text):
                                continuation.yield(text)
                            case .done:
                                continuation.finish()
                                return
                            case .failed(let detail):
                                throw AskError.ollama(detail)
                            }
                        }
                    }
                    continuation.finish()
                } catch let error as URLError {
                    continuation.finish(throwing: AskError.from(error))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
