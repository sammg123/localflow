import AppKit
import Foundation

/// One Claude Code session as the controller drives it: AgentRunner in the app.
protocol AgentSession: AnyObject, Sendable {
    var events: AsyncStream<AgentEvent> { get }
    func start(task: String, imagePNGBase64: String?)
    func send(text: String, imagePNGBase64: String?)
    func answer(requestID: String, allow: Bool, input: AgentJSON, message: String?)
    func interrupt()
    func close()
    /// Ends it now, with no grace period (LocalFlow is quitting).
    func terminate()
}

extension AgentRunner: AgentSession {}

/// Where the agent shows what it's doing: the floating panel in the app.
@MainActor
protocol AgentSurface: AnyObject {
    var model: AgentModel { get }
    var onAnswer: ((AgentApproval, AgentAnswer) -> Void)? { get set }
    var onStop: (() -> Void)? { get set }
    var onClose: (() -> Void)? { get set }
    /// The box in the agent's window closed: screen steps held for it can go ahead.
    var onInputClosed: (() -> Void)? { get set }
    /// Undo on an Instant edit.
    var onUndo: (() -> Void)? { get set }
    var isVisible: Bool { get }
    /// The user is typing in the agent's window, which has the keyboard.
    var isTakingInput: Bool { get }
    func show(on screen: NSScreen?)
    func hide()
    func setFollowUpHint(_ hint: String)
    @discardableResult func moveAside(avoiding points: [CGPoint]) -> Bool
}

extension AgentPanel: AgentSurface {}

/// Agent mode: hands a task (Do it in the Ask window) to Claude Code, which works on the
/// Mac with its terminal and file tools and LocalFlow's screen tools. Every step Claude
/// Code asks about goes through AgentPolicy: safe ones run, risky ones wait on a card in
/// the panel. The session stays open for more until the panel is closed.
@MainActor
final class AgentController {
    typealias MakeSession = @MainActor (_ model: String, _ displayID: UInt32, _ options: AgentRunOptions) -> AgentSession
    typealias LookUp = @MainActor (CGPoint) async -> ClickTarget.Found

    /// The reply streamed while working keeps only its newest text.
    static let maxReply = 20_000
    private static let screenTools = "mcp__\(AgentInvocation.serverName)__"
    private static let clickTool = screenTools + "click"

    private let surface: AgentSurface
    private let glow: ListeningIndicator
    private let makeSession: MakeSession
    private let displayIDFor: @MainActor (NSScreen?) -> UInt32
    private let mappingFor: @MainActor (UInt32) -> ScreenMapping?
    private let lookUp: LookUp
    private let frontApp: @MainActor () -> String?
    /// Settings' Always allow: nothing waits for an OK.
    private let alwaysAllow: @MainActor () -> Bool
    /// LocalFlow's memory files and when to add to them, read fresh for each new session.
    private let memory: @MainActor () -> String
    /// Instant Edits: its stages, its guard, its Undo.
    private let instantRuns: InstantRuns
    /// An Instant run getting ready (screen, project, design profile) before its session starts.
    private var preparing: Task<Void, Never>?
    /// The session is an Instant run's: no cards, its guard answers, stages for steps.
    private var isInstantRun = false
    private let chime: @MainActor () -> Void
    private let finished: @MainActor (_ succeeded: Bool) -> Void

    private var session: AgentSession?
    private var listener: Task<Void, Never>?
    private var screen: NSScreen?
    private var displayID: UInt32 = 0
    /// Kinds of step allowed with "Allow for this task", until the panel closes.
    private var grants: Set<String> = []
    /// Requests waiting on the user, by Claude Code's request id.
    private var waiting: [String: Pending] = [:]
    /// Screen steps waiting for the user to finish typing in the agent's window, in order.
    private var held: [(id: String, pending: Pending)] = [] {
        didSet { model.isHeld = !held.isEmpty }
    }
    /// Turns sent and not finished: more can be sent while one runs.
    private var openTurns = 0
    private var stopping = false
    /// The session was told to end; anything more starts a new one.
    private var ending = false

    private struct Pending {
        let toolName: String
        let input: AgentJSON
        let stepID: String
        let points: [CGPoint]
        let found: ClickTarget.Found
        /// The app in front when the step was asked for: Return sends in a chat app.
        let frontApp: String?
    }

    private var model: AgentModel { surface.model }

    /// The panel is up.
    var isActive: Bool { surface.isVisible }
    /// The connected MCP servers new sessions get, kept ready so a task starts at once.
    var connectorServers: [String: AgentJSON] = [:]

    init(surface: AgentSurface? = nil,
         indicator: ListeningIndicator? = nil,
         makeSession: @escaping MakeSession = { AgentRunner(model: $0, options: $2, displayID: $1) },
         displayID: @escaping @MainActor (NSScreen?) -> UInt32 = AgentController.displayID(of:),
         mapping: @escaping @MainActor (UInt32) -> ScreenMapping? = { ScreenMapping(displayID: $0) },
         lookUp: @escaping LookUp = { point in await Task.detached { ClickTarget.find(at: point) }.value },
         frontApp: @escaping @MainActor () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
         alwaysAllow: @escaping @MainActor () -> Bool = { Settings.shared.agentAlwaysAllow },
         memory: @escaping @MainActor () -> String = { FlowMemory().promptSection(for: .agent) },
         instant: InstantRuns? = nil,
         chime: @escaping @MainActor () -> Void = { SoundPlayer.playStart() },
         finished: @escaping @MainActor (Bool) -> Void = { $0 ? SoundPlayer.playStop() : SoundPlayer.playError() }) {
        self.surface = surface ?? AgentPanel()
        glow = indicator ?? ScreenGlow(tint: .agent)
        self.makeSession = makeSession
        displayIDFor = displayID
        mappingFor = mapping
        self.lookUp = lookUp
        self.frontApp = frontApp
        self.alwaysAllow = alwaysAllow
        self.memory = memory
        instantRuns = instant ?? InstantRuns()
        self.chime = chime
        self.finished = finished
        self.surface.onAnswer = { [weak self] approval, answer in self?.answer(approval, answer) }
        self.surface.onStop = { [weak self] in self?.stop() }
        self.surface.onClose = { [weak self] in self?.close() }
        self.surface.onInputClosed = { [weak self] in self?.releaseHeld() }
        self.surface.onUndo = { [weak self] in
            guard let self else { return }
            self.instantRuns.undo(on: self.model)
        }
    }

    static func displayID(of screen: NSScreen?) -> UInt32 {
        let number = (screen ?? NSScreen.main)?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
        return (number as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }

    func setFollowUpHint(_ hint: String) {
        surface.setFollowUpHint(hint)
    }

    // MARK: - What the user does

    /// A task from the Ask window. With the panel up and its session open, it's more for
    /// the same session; otherwise a new session starts on this screen. With `instant`,
    /// it's an Instant Edits run, always on its own.
    func run(_ task: String, on screen: NSScreen?, instant: Bool = false) {
        let task = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { return }
        if instant { return runInstant(task, on: screen) }
        if let session, surface.isVisible, !ending, !isInstantRun {
            model.followUp(task: task)
            openTurns += 1
            stopping = false
            glow.show(on: self.screen)
            session.send(text: task, imagePNGBase64: nil)
            FlowLog.shared.write("agent: more for the task")
            return
        }
        close()
        self.screen = screen ?? NSScreen.main
        displayID = displayIDFor(self.screen)
        let session = makeSession(Settings.shared.effectiveAgentModel, displayID,
                                  AgentRunOptions(appendPrompt: AgentInvocation.prompt(memory: memory()),
                                                  servers: connectorServers))
        self.session = session
        openTurns = 1
        model.start(task: task)
        surface.show(on: self.screen)
        glow.show(on: self.screen)
        listen(to: session)
        session.start(task: task, imagePNGBase64: nil)
        FlowLog.shared.write("agent: task started")
    }

    /// The Stop button: what's waiting is turned down and the current turn stops. The
    /// session stays open for more, unless there's nothing to interrupt yet or more is
    /// queued behind this turn: then the session ends.
    func stop() {
        if let preparing {
            preparing.cancel()
            self.preparing = nil
            model.endRunningSteps(as: .denied)
            model.status = .stopped
            glow.hide()
            return
        }
        guard let session, !ending, model.status.isWorking else { return }
        FlowLog.shared.write("agent: stopped by the user")
        stopping = true
        denyWaiting()
        guard model.status != .starting, openTurns <= 1 else {
            ending = true
            return session.close()
        }
        session.interrupt()
    }

    /// LocalFlow is quitting: the session ends now rather than after a grace period.
    func shutdown() {
        let current = session
        close()
        current?.terminate()
    }

    /// The ✕: ends the session (and anything it left running) and puts everything away.
    func close() {
        let current = session
        // Already told to end by Stop: once is enough.
        let alreadyEnding = ending
        preparing?.cancel()
        preparing = nil
        if isInstantRun {
            instantRuns.turnEnded(on: model)
            instantRuns.finish()
            isInstantRun = false
        }
        session = nil
        listener?.cancel()
        listener = nil
        waiting = [:]
        held = []
        grants = []
        openTurns = 0
        stopping = false
        ending = false
        if !alreadyEnding { current?.close() }
        surface.hide()
        glow.hide()
    }

    private func answer(_ approval: AgentApproval, _ answer: AgentAnswer) {
        guard let pending = waiting.removeValue(forKey: approval.id) else { return }
        model.resolve(id: approval.id)
        switch answer {
        case .deny:
            FlowLog.shared.write("agent: user denied \(pending.toolName)")
            session?.answer(requestID: approval.id, allow: false, input: pending.input, message: nil)
            model.finishStep(id: pending.stepID, state: .denied)
        case .allowOnce:
            FlowLog.shared.write("agent: user allowed \(pending.toolName)")
            allow(approval.id, pending)
        case .allowForTask where !approval.canAllowForTask:
            FlowLog.shared.write("agent: user allowed \(pending.toolName)")
            allow(approval.id, pending)
        case .allowForTask:
            FlowLog.shared.write("agent: user allowed \(pending.toolName) for the task")
            grants.insert(approval.grantKey)
            allow(approval.id, pending)
            allowWaitingCoveredByGrants()
        }
    }

    // MARK: - What the session does

    private func listen(to session: AgentSession) {
        listener = Task { [weak self] in
            for await event in session.events {
                guard let self, self.session === session else { return }
                self.handle(event)
            }
        }
    }

    private func handle(_ event: AgentEvent) {
        switch event {
        case .sessionStarted:
            markWorking()
        case .textDelta(let text):
            markWorking()
            model.reply = String((model.reply + text).suffix(Self.maxReply))
        case .toolStarted(let id, let name, let input):
            markWorking()
            // An Instant run's steps are its stages.
            if !isInstantRun {
                model.addStep(id: id, title: AgentStepTitle.title(toolName: name, input: input, target: nil))
            }
        case .toolFinished(let id, let isError, _):
            model.finishStep(id: id, state: isError ? .failed : .done)
        case .permissionRequest(let requestID, let toolName, let input, _, let toolUseID):
            review(requestID: requestID, toolName: toolName, input: input, stepID: toolUseID ?? requestID)
        case .turnFinished(let failure, let finalText):
            turnFinished(failure: failure, finalText: finalText)
        case .ended(let error):
            ended(error)
        case .permissionDenied, .usageLimit, .apiError:
            break
        }
    }

    private func markWorking() {
        if model.status == .starting { model.status = .working }
    }

    /// Safe steps go ahead; risky ones wait on a card. Screenshots leave the panel out,
    /// so the agent can't see it: it moves off every point a step acts on first, and only
    /// then is what's under a click looked up (else it would be the panel's own button).
    private func review(requestID: String, toolName: String, input: AgentJSON, stepID: String) {
        if isInstantRun { return reviewInstant(requestID: requestID, toolName: toolName, input: input) }
        let points = pointerPoints(toolName, input)
        surface.moveAside(avoiding: points)
        model.addStep(id: stepID, title: AgentStepTitle.title(toolName: toolName, input: input, target: nil))
        let front = frontApp()
        guard toolName == Self.clickTool, let point = points.first else {
            return decide(requestID, Pending(toolName: toolName, input: input, stepID: stepID, points: points,
                                             found: .unnamed, frontApp: front))
        }
        let asked = session
        Task { [weak self] in
            guard let self else { return }
            let found = await self.lookUp(point)
            guard self.session === asked, asked != nil else { return }
            if let name = found.name {
                self.model.retitle(id: stepID, title: AgentStepTitle.title(toolName: toolName, input: input, target: name))
            }
            self.decide(requestID, Pending(toolName: toolName, input: input, stepID: stepID, points: points,
                                           found: found, frontApp: front))
        }
    }

    private func decide(_ requestID: String, _ pending: Pending) {
        guard !stopping, !ending else {
            session?.answer(requestID: requestID, allow: false, input: pending.input, message: nil)
            return model.finishStep(id: pending.stepID, state: .denied)
        }
        // The user's typing would land where the agent clicks or types, and the agent's in the box.
        if surface.isTakingInput, Self.actsOnScreen(pending.toolName) {
            held.append((requestID, pending))
            return
        }
        switch verdict(for: pending) {
        case .allow:
            allow(requestID, pending)
        case .refuse(let message):
            session?.answer(requestID: requestID, allow: false, input: pending.input, message: message)
            model.finishStep(id: pending.stepID, state: .denied)
        case .ask(let summary, let grantKey):
            FlowLog.shared.write("agent: asking before \(pending.toolName)")
            waiting[requestID] = pending
            model.ask(AgentApproval(id: requestID, summary: summary, grantKey: grantKey))
            chime()
        }
    }

    private enum Verdict: Equatable {
        case allow
        case ask(summary: String, grantKey: String)
        /// Turned down without asking; the message tells the agent why.
        case refuse(String)
    }

    /// A click still landing on a LocalFlow window (the Ask window, an answer) asks: the
    /// agent can't see those, and they can start or approve things. With Always allow on,
    /// nothing asks, and such a click is turned down with word to look again.
    private func verdict(for pending: Pending) -> Verdict {
        if alwaysAllow() {
            return pending.found == .localFlow ? .refuse(Self.lookAgain) : .allow
        }
        if pending.found == .localFlow, !grants.contains(Self.localFlowGrant) {
            return .ask(summary: "Click on a LocalFlow window", grantKey: Self.localFlowGrant)
        }
        switch AgentPolicy.decide(toolName: pending.toolName, input: pending.input, grants: grants,
                                  targetTitle: pending.found.name, frontApp: pending.frontApp) {
        case .allow: return .allow
        case .ask(let summary, let grantKey): return .ask(summary: summary, grantKey: grantKey)
        }
    }

    private static let localFlowGrant = "click:localflow"
    static let lookAgain = "That spot is covered by a LocalFlow window, which isn't in your screenshots. "
        + "Take a new screenshot and try again."
    /// Screen steps that click, type or press where the user's typing would go.
    private static let screenActions: Set<String> = ["click", "type", "key", "drag", "scroll", "move", "open_app"]

    private static func actsOnScreen(_ toolName: String) -> Bool {
        toolName.hasPrefix(screenTools) && screenActions.contains(String(toolName.dropFirst(screenTools.count)))
    }

    /// The box closed: the screen steps held for it are looked at again (the window may
    /// have moved off where they act).
    private func releaseHeld() {
        let released = held
        held = []
        for item in released {
            review(requestID: item.id, toolName: item.pending.toolName, input: item.pending.input,
                   stepID: item.pending.stepID)
        }
    }

    /// Lets a step go ahead, after one more check that the panel is clear of where it
    /// acts (a card or step may have grown it since).
    private func allow(_ requestID: String, _ pending: Pending) {
        surface.moveAside(avoiding: pending.points)
        session?.answer(requestID: requestID, allow: true, input: pending.input, message: nil)
    }

    /// After "Allow for this task", anything else waiting that it now covers goes ahead.
    private func allowWaitingCoveredByGrants() {
        for approval in model.approvals {
            guard let pending = waiting[approval.id], verdict(for: pending) == .allow else { continue }
            waiting[approval.id] = nil
            model.resolve(id: approval.id)
            allow(approval.id, pending)
        }
    }

    private func denyWaiting() {
        for id in model.clearApprovals() {
            guard let pending = waiting.removeValue(forKey: id) else { continue }
            session?.answer(requestID: id, allow: false, input: pending.input, message: nil)
            model.finishStep(id: pending.stepID, state: .denied)
        }
        waiting = [:]
        let released = held
        held = []
        for item in released {
            session?.answer(requestID: item.id, allow: false, input: item.pending.input, message: nil)
            model.finishStep(id: item.pending.stepID, state: .denied)
        }
    }

    private func turnFinished(failure: String?, finalText: String?) {
        openTurns = max(0, openTurns - 1)
        if let finalText, !finalText.isEmpty { model.reply = finalText }
        guard openTurns == 0 else { return }
        denyWaiting()
        if stopping {
            model.endRunningSteps(as: .denied)
            model.status = .stopped
        } else if let failure {
            model.endRunningSteps(as: .failed)
            model.status = .failed(AskError.claude(failure).message)
            finished(false)
        } else {
            model.endRunningSteps(as: .done)
            model.status = .done
            finished(true)
        }
        if isInstantRun { instantRuns.turnEnded(on: model) }
        FlowLog.shared.write("agent: turn finished (\(stopping ? "stopped" : failure == nil ? "done" : "failed"))")
        stopping = false
        glow.hide()
    }

    /// The session is over: closed, or it failed. The panel stays up to say why.
    private func ended(_ error: AskError?) {
        session = nil
        listener = nil
        waiting = [:]
        held = []
        grants = []
        openTurns = 0
        ending = false
        _ = model.clearApprovals()
        if isInstantRun { instantRuns.turnEnded(on: model) }
        if let error {
            model.endRunningSteps(as: .failed)
            model.status = .failed(error.message)
            finished(false)
        } else if model.status.isWorking {
            model.endRunningSteps(as: .denied)
            model.status = .stopped
        }
        stopping = false
        glow.hide()
    }

    // MARK: - Instant Edits

    /// Gets ready stage by stage on the panel, then starts a session that may only make
    /// the one small UI change, in the one project.
    private func runInstant(_ task: String, on screen: NSScreen?) {
        // Before close(), which drops a project question nobody answered.
        let request = instantRuns.request(for: task)
        close()
        self.screen = screen ?? NSScreen.main
        displayID = displayIDFor(self.screen)
        isInstantRun = true
        model.start(task: task, instant: true)
        model.status = .working
        surface.show(on: self.screen)
        glow.show(on: self.screen)
        FlowLog.shared.write("instant: run started")
        preparing = Task { [weak self, displayID] in
            guard let self else { return }
            let outcome = await self.instantRuns.prepare(request, displayID: displayID) { stage in
                // Stopped or closed while getting ready: a late stage leaves the panel alone.
                guard !Task.isCancelled else { return }
                InstantRuns.show(stage, on: self.model)
            }
            guard !Task.isCancelled, self.isInstantRun else { return }
            self.preparing = nil
            switch outcome {
            case .stopped(let stop):
                self.instantRuns.stopped(stop, request: request, on: self.model)
                self.glow.hide()
                self.finished(false)
            case .ready(let plan):
                self.startInstant(plan)
            }
        }
    }

    private func startInstant(_ plan: InstantPlan) {
        InstantRuns.ready(plan, on: model)
        let session = makeSession(InstantPrompt.model, displayID, instantRuns.began(plan))
        self.session = session
        openTurns = 1
        listen(to: session)
        session.start(task: plan.request, imagePNGBase64: plan.screenshotPNGBase64)
    }

    /// No cards in Instant Edits: its guard allows, or refuses with a word to the model.
    private func reviewInstant(requestID: String, toolName: String, input: AgentJSON) {
        guard !stopping, !ending else {
            session?.answer(requestID: requestID, allow: false, input: input, message: nil)
            return
        }
        switch instantRuns.review(toolName: toolName, input: input) {
        case .allow:
            session?.answer(requestID: requestID, allow: true, input: input, message: nil)
        case .deny(let message):
            session?.answer(requestID: requestID, allow: false, input: input, message: message)
        }
    }

    /// The global points a screen step acts on (where it clicks, drags or scrolls).
    /// Mapped afresh each time, as the screen server does, so a display change mid-session
    /// can't put the two out of step.
    private func pointerPoints(_ toolName: String, _ input: AgentJSON) -> [CGPoint] {
        guard toolName.hasPrefix(Self.screenTools), let mapping = mappingFor(displayID) else { return [] }
        let point = { (x: String, y: String) -> CGPoint? in
            guard let px = input[x]?.number, let py = input[y]?.number else { return nil }
            return mapping.toGlobal(x: px, y: py)
        }
        switch toolName.dropFirst(Self.screenTools.count) {
        case "click", "move", "scroll": return [point("x", "y")].compactMap { $0 }
        case "drag": return [point("from_x", "from_y"), point("to_x", "to_y")].compactMap { $0 }
        default: return []
        }
    }
}
