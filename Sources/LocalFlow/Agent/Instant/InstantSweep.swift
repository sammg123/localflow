import Foundation

/// Whether a request can be an Instant edit.
enum InstantVerdict: Equatable, Sendable {
    /// A small change to how something looks.
    case small
    /// Bigger than a few small edits; the reason is one sentence for the user.
    case tooBig(String)
    /// It changes what the app does, not how it looks.
    case notUI(String)
    /// The check couldn't run or its answer couldn't be read; the reason says what to do.
    case unavailable(String)
}

/// A project as the sweep named it from LocalFlow's memory. The path isn't checked yet.
struct InstantProject: Equatable, Sendable {
    let name: String
    let path: String
}

/// What the sweep looks at: the request, the screen, LocalFlow's memory of the user's
/// projects (folders, repos, domains, logo and app-name cues) and recent Instant runs.
struct InstantSweepInput: Equatable, Sendable {
    let request: String
    let screenshotPNGBase64: String?
    let memory: String
    let recent: [String]
}

struct InstantSweepResult: Equatable, Sendable {
    let verdict: InstantVerdict
    /// Nil when it couldn't tell which project the screen shows.
    let project: InstantProject?
    /// One short line saying what will change, such as "Making the Save button round".
    let change: String

    static func unavailable(_ reason: String) -> InstantSweepResult {
        InstantSweepResult(verdict: .unavailable(reason), project: nil, change: "")
    }
}

protocol InstantSweeping: Sendable {
    func check(_ input: InstantSweepInput) async -> InstantSweepResult
}

/// One quick Sonnet call through Claude Code, with no tools, before an Instant run.
struct InstantSweep: InstantSweeping {
    /// Runs Claude Code once with these arguments and this stdin, and returns its output.
    typealias Run = @Sendable (_ arguments: [String], _ input: Data) async throws -> String

    static let timeout: Duration = .seconds(20)
    static let unavailableMessage = "Couldn't check the size of that edit. Try again."
    static let missingMessage = "Instant Edits needs Claude Code on this Mac. Install it, then try again."
    static let signedOutMessage = "Sign LocalFlow in to Claude in Settings, then try again."
    static let outOfUsageMessage = "Your Claude plan's usage is used up for now, so Instant Edits can't run."

    private let run: Run
    private let log: @Sendable (String) -> Void

    init(run: @escaping Run = InstantSweep.claudeCode(), log: @escaping @Sendable (String) -> Void = { FlowLog.shared.write($0) }) {
        self.run = run
        self.log = log
    }

    func check(_ input: InstantSweepInput) async -> InstantSweepResult {
        guard !input.request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .unavailable(Self.unavailableMessage)
        }
        let started = ContinuousClock.now
        let result: InstantSweepResult
        do {
            let output = try await run(InstantSweepPrompt.arguments(), InstantSweepPrompt.input(for: input))
            result = InstantSweepPrompt.result(from: try InstantSweepPrompt.resultText(from: output))
        } catch {
            result = .unavailable(Self.message(for: error))
        }
        let seconds = (ContinuousClock.now - started).components.seconds
        // Count-only: never the request, the memory or the project.
        log("instant sweep: \(Self.logName(result.verdict)), project \(result.project == nil ? "unknown" : "named"), "
            + "\(input.request.count) chars, \(input.screenshotPNGBase64 == nil ? "no " : "")screenshot, \(seconds)s")
        return result
    }

    static func message(for error: Error) -> String {
        switch error as? AskError {
        case .claudeMissing: return missingMessage
        case .claudeSignedOut: return signedOutMessage
        case .claudeOutOfUsage: return outOfUsageMessage
        default: return unavailableMessage
        }
    }

    private static func logName(_ verdict: InstantVerdict) -> String {
        switch verdict {
        case .small: return "small"
        case .tooBig: return "too_big"
        case .notUI: return "not_ui"
        case .unavailable: return "unavailable"
        }
    }

    /// The real run: Claude Code on LocalFlow's own sign-in, in a private folder that
    /// doesn't outlive the check, the message on stdin, stopped at the time limit.
    static func claudeCode(executable: String? = ClaudeInvocation.locate(),
                           configDirectory: String = ClaudeInvocation.configDirectory(),
                           timeout: Duration = timeout) -> Run {
        { arguments, input in
            guard let executable else { throw AskError.claudeMissing }
            return try await InstantSweepProcess.run(executable: executable, configDirectory: configDirectory,
                                                     arguments: arguments, input: input, timeout: timeout)
        }
    }
}

/// Running Claude Code for one sweep, the way Ask's Claude client does.
enum InstantSweepProcess {
    static func run(executable: String, configDirectory: String, arguments: [String], input: Data,
                    timeout: Duration) async throws -> String {
        let files = FileManager.default
        let dir = try AskTool.makeFolder()
        defer { try? files.removeItem(at: dir) } // the screenshot never outlives the check
        let message = dir.appendingPathComponent("message.jsonl")
        let errors = dir.appendingPathComponent("stderr.txt")
        guard files.createFile(atPath: message.path, contents: input, attributes: AskTool.privateFile),
              files.createFile(atPath: errors.path, contents: nil, attributes: AskTool.privateFile) else {
            throw AskError.claude("couldn't write the request to a temporary folder")
        }
        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ClaudeInvocation.environment(tmp: files.temporaryDirectory.path,
                                                           configDirectory: configDirectory,
                                                           toolFolder: ClaudeInvocation.folder(of: executable))
        process.currentDirectoryURL = dir
        process.standardInput = try FileHandle(forReadingFrom: message)
        process.standardOutput = output
        process.standardError = try FileHandle(forWritingTo: errors)
        let reader = ToolOutputLines(reading: output.fileHandleForReading)
        defer { reader.finish() }
        var lines: [String] = []
        let status = try await AskTool.run(process, timeout: timeout,
                                           launchFailure: { .claude("couldn't start Claude Code: \($0)") },
                                           onExit: { reader.toolExited() }) {
            for await line in reader.lines { lines.append(line) }
        }
        try Task.checkCancellation()
        if status != 0, !lines.contains(where: { $0.contains("\"type\":\"result\"") }) {
            throw AskError.fromClaude(code: nil, text: AskTool.lastLine(of: AskTool.tail(of: errors)) ?? "it stopped")
        }
        return lines.joined(separator: "\n")
    }
}
