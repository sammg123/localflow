import Foundation

/// One agent session: a single Claude Code process that keeps running between turns, so
/// follow-ups go to the same session and background commands carry on. Everything that
/// happens comes on `events`, and the last event is always `.ended`. Call `close()` when
/// done: a session that's only let go of runs on until `sessionLimit`.
final class AgentRunner: @unchecked Sendable {
    /// The longest a session can run before it's stopped.
    static let sessionLimit: Duration = .seconds(4 * 3_600)
    /// How long Claude Code gets to finish after its input closes before it's stopped.
    static let closeGrace: Duration = .seconds(2)
    static let deniedMessage = "The user didn't allow this."

    let events: AsyncStream<AgentEvent>
    private let continuation: AsyncStream<AgentEvent>.Continuation
    private let executable: String?
    private let model: String
    private let effort: String
    private let displayID: UInt32
    private let mcpExecutable: String
    private let home: String
    private let configDirectory: String
    private let sessionLimit: Duration
    private let closeGrace: Duration
    private let log: @Sendable (String) -> Void
    /// Writes to Claude Code's input one at a time, off the caller's thread: a big
    /// screenshot can wait on Claude Code to read it.
    private let writes = DispatchQueue(label: "LocalFlow.AgentRunner.input")
    private let lock = NSLock()
    private var state = State()

    private enum Phase { case idle, running, closing, ended }

    /// Everything that changes, kept behind `lock`.
    private struct State {
        var phase = Phase.idle
        var process: Process?
        var input: FileHandle?
        /// Lines written before Claude Code started, sent once it has.
        var pending: [Data] = []
        var folder: URL?
        /// Something has happened in this turn (words, a tool); a usage limit before that
        /// means the turn can't run at all.
        var turnActive = false
        var errorCode: String?
        var fatal: AskError?
    }

    private struct Launch: @unchecked Sendable {
        let process: Process
        let reader: ToolOutputLines
        let input: FileHandle
        let errors: URL
        let errorOutput: FileHandle
    }

    init(executable: String? = ClaudeInvocation.locate(), model: String, effort: String = AgentInvocation.defaultEffort,
         displayID: UInt32, mcpExecutable: String = Bundle.main.executablePath ?? "", home: String = NSHomeDirectory(),
         configDirectory: String = ClaudeInvocation.configDirectory(), sessionLimit: Duration = sessionLimit,
         closeGrace: Duration = closeGrace, log: @escaping @Sendable (String) -> Void = { FlowLog.shared.write($0) }) {
        (events, continuation) = AsyncStream.makeStream(of: AgentEvent.self)
        self.executable = executable
        self.model = model
        self.effort = effort
        self.displayID = displayID
        self.mcpExecutable = mcpExecutable
        self.home = home
        self.configDirectory = configDirectory
        self.sessionLimit = sessionLimit
        self.closeGrace = closeGrace
        self.log = log
    }

    /// The input pipe. Writing after Claude Code exits fails instead of killing LocalFlow.
    static func makeInputPipe() -> Pipe {
        let pipe = Pipe()
        _ = fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        return pipe
    }

    // MARK: Driving the session

    /// Starts Claude Code with the task (and a screenshot, if any). Failures, such as no
    /// Claude Code on this Mac, come as `.ended`.
    func start(task: String, imagePNGBase64: String?) {
        let starting = locked { state -> Bool in
            guard state.phase == .idle else { return false }
            state.phase = .running
            state.pending = [AgentInvocation.initialize(requestID: UUID().uuidString),
                             AgentInvocation.userMessage(text: task, imagePNGBase64: imagePNGBase64)]
            return true
        }
        guard starting else { return }
        guard let executable, FileManager.default.isExecutableFile(atPath: executable) else {
            return finish(.claudeMissing)
        }
        guard AskTool.isValidModel(model) else { return finish(.claude("the model name in Settings (\(model)) isn't valid")) }
        guard AskTool.isValidModel(effort) else { return finish(.claude("the effort setting (\(effort)) isn't valid")) }
        log("agent: starting")
        // Folders and files are set up off the caller's thread, which is usually the main one.
        Task.detached {
            do {
                await self.run(try self.prepare(executable: executable))
            } catch {
                self.finish(error as? AskError ?? .claude("couldn't set up the agent: \(error.localizedDescription)"))
            }
        }
    }

    /// A follow-up turn in the same session.
    func send(text: String, imagePNGBase64: String?) {
        write(AgentInvocation.userMessage(text: text, imagePNGBase64: imagePNGBase64), kind: "turn") { state in
            state.turnActive = false
            state.errorCode = nil
        }
    }

    /// The user's answer to a permission prompt. Allowing sends `input` back unchanged.
    func answer(requestID: String, allow: Bool, input: AgentJSON, message: String?) {
        let line = allow ? AgentInvocation.allow(requestID: requestID, input: input)
            : AgentInvocation.deny(requestID: requestID, message: message ?? Self.deniedMessage)
        write(line, kind: allow ? "allow" : "deny")
    }

    /// Stops the current turn; the session stays open.
    func interrupt() {
        write(AgentInvocation.interrupt(requestID: UUID().uuidString), kind: "interrupt")
    }

    /// Ends the session: closes Claude Code's input, then stops it if it hasn't exited
    /// after a grace period. Its temporary folder is removed.
    func close() {
        let (wasIdle, process) = locked { state -> (Bool, Process?) in
            switch state.phase {
            case .idle:
                return (true, nil)
            case .running:
                state.phase = .closing
                state.pending = []
                return (false, state.process)
            case .closing, .ended:
                return (false, nil)
            }
        }
        if wasIdle { return finish(nil) }
        guard let process else { return } // not started yet; `launched` closes it
        log("agent: closing")
        ProcessTree.endDescendants(of: process.processIdentifier)
        closeInput()
        stopLater(process)
    }

    /// Ends the session now, with no grace period: LocalFlow is quitting, and a session
    /// left to finish on its own would carry on with no one to stop it.
    func terminate() {
        let (process, folder) = locked { state -> (Process?, URL?) in
            guard state.phase == .running || state.phase == .closing else { return (nil, nil) }
            state.phase = .closing
            state.pending = []
            return (state.process, state.folder)
        }
        log("agent: terminating")
        if let process { ProcessTree.endDescendantsNow(of: process.processIdentifier) }
        closeInput()
        if let process, process.isRunning { process.terminate() }
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    // MARK: Running

    private func prepare(executable: String) throws -> Launch {
        let files = FileManager.default
        let workingDirectory = try AgentFiles.makeWorkingDirectory(home: home)
        let folder = try AgentFiles.makeFolder()
        locked { $0.folder = folder }
        let config = folder.appendingPathComponent("mcp.json")
        let errors = folder.appendingPathComponent("stderr.txt")
        let configData = AgentInvocation.mcpConfig(executable: mcpExecutable, displayID: displayID)
        guard files.createFile(atPath: config.path, contents: configData, attributes: AskTool.privateFile),
              files.createFile(atPath: errors.path, contents: nil, attributes: AskTool.privateFile) else {
            throw AskError.claude("couldn't write the agent's settings to a temporary folder")
        }
        let input = Self.makeInputPipe()
        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = AgentInvocation.arguments(model: model, effort: effort, mcpConfigPath: config.path, home: home)
        process.environment = AgentInvocation.environment(home: home, tmp: files.temporaryDirectory.path,
                                                          configDirectory: configDirectory,
                                                          toolFolder: ClaudeInvocation.folder(of: executable))
        process.currentDirectoryURL = workingDirectory
        process.standardInput = input
        process.standardOutput = output
        let errorOutput = try FileHandle(forWritingTo: errors)
        process.standardError = errorOutput
        return Launch(process: process, reader: ToolOutputLines(reading: output.fileHandleForReading),
                      input: input.fileHandleForWriting, errors: errors, errorOutput: errorOutput)
    }

    private func run(_ launch: Launch) async {
        let reader = launch.reader
        defer {
            reader.finish()
            try? launch.errorOutput.close()
        }
        do {
            _ = try await AskTool.run(launch.process, timeout: sessionLimit,
                                      launchFailure: { .claude("couldn't start Claude Code: \($0)") },
                                      onExit: { reader.toolExited() }) {
                launched(launch)
                for await line in reader.lines { handle(line, process: launch.process) }
            }
            finish(endingError(errors: launch.errors))
        } catch {
            let (fatal, started) = locked { ($0.fatal, $0.process != nil) }
            if !started { writes.async { try? launch.input.close() } } // never handed to the session
            finish(fatal ?? error as? AskError ?? .claude(error.localizedDescription))
        }
    }

    /// Claude Code is running: send what was written before it started, unless the
    /// session was closed in the meantime.
    private func launched(_ launch: Launch) {
        let closing = locked { state -> Bool in
            state.process = launch.process
            guard state.phase == .running else { return true }
            state.input = launch.input
            for line in state.pending { enqueue(line, to: launch.input, kind: "start") }
            state.pending = []
            return false
        }
        log("agent: launched")
        guard closing else { return }
        writes.async { try? launch.input.close() }
        stopLater(launch.process)
    }

    private func handle(_ line: String, process: Process) {
        for event in AgentStream.parse(line: line) {
            let (forward, stop) = locked { review(event, &$0) }
            if stop {
                log("agent: stopping (\(locked { $0.fatal?.logName ?? "" }))")
                AskTool.stop(process)
            }
            if forward { continuation.yield(event) }
        }
    }

    /// Whether to pass `event` on, and whether it means the session can't go on: not
    /// signed in, or out of usage before the turn did anything.
    private func review(_ event: AgentEvent, _ state: inout State) -> (forward: Bool, stop: Bool) {
        guard state.fatal == nil else { return (false, false) }
        switch event {
        case .apiError(let code):
            state.errorCode = code
        case .usageLimit(let resetsAt) where !state.turnActive:
            state.fatal = .claudeOutOfUsage(resetsAt: resetsAt, detail: nil)
            return (false, true)
        case .turnFinished(let failure?, _):
            let error = AskError.fromClaude(code: state.errorCode, text: failure)
            if case .claudeSignedOut = error { state.fatal = error }
            if case .claudeOutOfUsage = error { state.fatal = error }
            if state.fatal != nil { return (false, true) }
            state.turnActive = false
            state.errorCode = nil
        case .turnFinished:
            state.turnActive = false
            state.errorCode = nil
        case .textDelta, .toolStarted, .toolFinished, .permissionRequest:
            state.turnActive = true
        default:
            break
        }
        return (true, false)
    }

    /// Why the session ended: what stopped it, nothing if it was closed, or else what
    /// Claude Code said last.
    private func endingError(errors: URL) -> AskError? {
        let (fatal, closing, code) = locked { ($0.fatal, $0.phase == .closing, $0.errorCode) }
        if let fatal { return fatal }
        if closing { return nil }
        let said = AskTool.lastLine(of: AgentFiles.tail(of: errors)) ?? AgentStream.noReason
        return AskError.fromClaude(code: code, text: said)
    }

    private func finish(_ error: AskError?) {
        let ending = locked { state -> (folder: URL?, input: FileHandle?, closing: Bool)? in
            guard state.phase != .ended else { return nil }
            let closing = state.phase == .closing
            state.phase = .ended
            defer {
                state.folder = nil
                state.input = nil
                state.process = nil
                state.pending = []
            }
            return (state.folder, state.input, closing)
        }
        guard let ending else { return }
        // Closed by the user while it was failing to start: that's still a close.
        let error = ending.closing ? nil : error
        if let folder = ending.folder { try? FileManager.default.removeItem(at: folder) }
        if let input = ending.input { writes.async { try? input.close() } }
        log("agent: ended (\(error?.logName ?? "closed"))")
        continuation.yield(.ended(error))
        continuation.finish()
    }

    // MARK: Input

    /// Queues one line for Claude Code. Before it starts, the line waits; once the session
    /// is closing or over, it's dropped.
    private func write(_ line: Data, kind: String, also change: (inout State) -> Void = { _ in }) {
        let accepted = locked { state -> Bool in
            guard state.phase == .running else { return false }
            change(&state)
            if let input = state.input { enqueue(line, to: input, kind: kind) } else { state.pending.append(line) }
            return true
        }
        log(accepted ? "agent: \(kind)" : "agent: \(kind) dropped, session not running")
    }

    /// Called with the lock held, so lines keep their order.
    private func enqueue(_ line: Data, to input: FileHandle, kind: String) {
        writes.async { [log] in
            do {
                try input.write(contentsOf: line)
            } catch {
                log("agent: couldn't write \(kind) (\((error as NSError).code))")
            }
        }
    }

    private func closeInput() {
        let input = locked { state -> FileHandle? in
            defer { state.input = nil }
            return state.input
        }
        if let input { writes.async { try? input.close() } }
    }

    private func stopLater(_ process: Process) {
        let grace = closeGrace
        Task.detached {
            try? await Task.sleep(for: grace)
            AskTool.stop(process)
        }
    }

    private func locked<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }
}
