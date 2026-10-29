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
}

extension AgentRunner: AgentSession {}

/// Where the agent shows what it's doing: the floating panel in the app.
@MainActor
protocol AgentSurface: AnyObject {
    var model: AgentModel { get }
    var onAnswer: ((AgentApproval, AgentAnswer) -> Void)? { get set }
    var onStop: (() -> Void)? { get set }
    var onClose: (() -> Void)? { get set }
    var isVisible: Bool { get }
    func show(on screen: NSScreen?)
    func hide()
    func setFollowUpHint(_ hint: String)
    @discardableResult func moveAside(ifCovering point: CGPoint) -> Bool
}

extension AgentPanel: AgentSurface {}

/// Agent mode: hands a task (Do it in the Ask window) to Claude Code, which works on the
/// Mac with its terminal and file tools and LocalFlow's screen tools. Every step Claude
/// Code asks about goes through AgentPolicy: safe ones run, risky ones wait on a card in
/// the panel. The session stays open for more until the panel is closed.
@MainActor
final class AgentController {
    typealias MakeSession = @MainActor (_ model: String, _ displayID: UInt32) -> AgentSession

    /// The reply streamed while working keeps only its newest text.
    static let maxReply = 20_000
    private static let screenTools = "mcp__\(AgentInvocation.serverName)__"

    private let surface: AgentSurface
    private let glow: ListeningIndicator
    private let makeSession: MakeSession
    private let displayIDFor: @MainActor (NSScreen?) -> UInt32
    private let mappingFor: @MainActor (UInt32) -> ScreenMapping?
    private let targetTitle: @MainActor (CGPoint) -> String?
    private let chime: @MainActor () -> Void
    private let finished: @MainActor (_ succeeded: Bool) -> Void

    private var session: AgentSession?
    private var listener: Task<Void, Never>?
    private var screen: NSScreen?
    private var mapping: ScreenMapping?
    /// Kinds of step allowed with "Allow for this task", until the panel closes.
    private var grants: Set<String> = []
    /// Requests waiting on the user, by Claude Code's request id.
    private var waiting: [String: Pending] = [:]
    /// Turns sent and not finished: more can be sent while one runs.
    private var openTurns = 0
    private var stopping = false

    private struct Pending {
        let toolName: String
        let input: AgentJSON
        let stepID: String
        let points: [CGPoint]
        let target: String?
    }

    private var model: AgentModel { surface.model }

    /// The panel is up.
    var isActive: Bool { surface.isVisible }

    init(surface: AgentSurface? = nil,
         indicator: ListeningIndicator? = nil,
         makeSession: @escaping MakeSession = { AgentRunner(model: $0, displayID: $1) },
         displayID: @escaping @MainActor (NSScreen?) -> UInt32 = AgentController.displayID(of:),
         mapping: @escaping @MainActor (UInt32) -> ScreenMapping? = { ScreenMapping(displayID: $0) },
         targetTitle: @escaping @MainActor (CGPoint) -> String? = { ClickTarget.label(at: $0) },
         chime: @escaping @MainActor () -> Void = { SoundPlayer.playStart() },
         finished: @escaping @MainActor (Bool) -> Void = { $0 ? SoundPlayer.playStop() : SoundPlayer.playError() }) {
        self.surface = surface ?? AgentPanel()
        glow = indicator ?? ScreenGlow(color: AgentStyle.green)
        self.makeSession = makeSession
        displayIDFor = displayID
        mappingFor = mapping
        self.targetTitle = targetTitle
        self.chime = chime
        self.finished = finished
        self.surface.onAnswer = { [weak self] approval, answer in self?.answer(approval, answer) }
        self.surface.onStop = { [weak self] in self?.stop() }
        self.surface.onClose = { [weak self] in self?.close() }
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
    /// the same session; otherwise a new session starts on this screen.
    func run(_ task: String, on screen: NSScreen?) {
        let task = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { return }
        if let session, surface.isVisible {
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
        let displayID = displayIDFor(self.screen)
        mapping = mappingFor(displayID)
        let session = makeSession(Settings.shared.effectiveAgentModel, displayID)
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
    /// session stays open for more.
    func stop() {
        guard let session, model.status.isWorking else { return }
        FlowLog.shared.write("agent: stopped by the user")
        guard model.status != .starting else {
            // Nothing is running yet to interrupt; end it before it begins.
            return session.close()
        }
        stopping = true
        denyWaiting()
        session.interrupt()
    }

    /// The ✕: ends the session (and anything it left running) and puts everything away.
    func close() {
        let ending = session
        session = nil
        listener?.cancel()
        listener = nil
        waiting = [:]
        grants = []
        openTurns = 0
        stopping = false
        ending?.close()
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
            let target = name == Self.screenTools + "click" ? pointerPoints(name, input).first.flatMap(targetTitle) : nil
            model.addStep(id: id, title: AgentStepTitle.title(toolName: name, input: input, target: target))
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

    /// Safe steps go ahead; risky ones wait on a card. Once stopping, everything is no.
    private func review(requestID: String, toolName: String, input: AgentJSON, stepID: String) {
        let points = pointerPoints(toolName, input)
        let target = toolName == Self.screenTools + "click" ? points.first.flatMap(targetTitle) : nil
        model.addStep(id: stepID, title: AgentStepTitle.title(toolName: toolName, input: input, target: target))
        let pending = Pending(toolName: toolName, input: input, stepID: stepID, points: points, target: target)
        guard !stopping else {
            session?.answer(requestID: requestID, allow: false, input: input, message: nil)
            return model.finishStep(id: stepID, state: .denied)
        }
        switch AgentPolicy.decide(toolName: toolName, input: input, grants: grants, targetTitle: target) {
        case .allow:
            allow(requestID, pending)
        case .ask(let summary, let grantKey):
            FlowLog.shared.write("agent: asking before \(toolName)")
            waiting[requestID] = pending
            model.ask(AgentApproval(id: requestID, summary: summary, grantKey: grantKey))
            chime()
        }
    }

    /// Lets a step go ahead, first moving the panel out from under any point it acts on:
    /// screenshots leave the panel out, so the agent can't see it's there.
    private func allow(_ requestID: String, _ pending: Pending) {
        pending.points.forEach { surface.moveAside(ifCovering: $0) }
        session?.answer(requestID: requestID, allow: true, input: pending.input, message: nil)
    }

    /// After "Allow for this task", anything else waiting that it now covers goes ahead.
    private func allowWaitingCoveredByGrants() {
        for approval in model.approvals {
            guard let pending = waiting[approval.id],
                  AgentPolicy.decide(toolName: pending.toolName, input: pending.input, grants: grants,
                                     targetTitle: pending.target) == .allow else { continue }
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
        FlowLog.shared.write("agent: turn finished (\(stopping ? "stopped" : failure == nil ? "done" : "failed"))")
        stopping = false
        glow.hide()
    }

    /// The session is over: closed, or it failed. The panel stays up to say why.
    private func ended(_ error: AskError?) {
        session = nil
        listener = nil
        waiting = [:]
        grants = []
        openTurns = 0
        _ = model.clearApprovals()
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

    /// The global points a screen step acts on (where it clicks, drags or scrolls).
    private func pointerPoints(_ toolName: String, _ input: AgentJSON) -> [CGPoint] {
        guard let mapping, toolName.hasPrefix(Self.screenTools) else { return [] }
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
