import Foundation

/// Where the agent is with the current task.
enum AgentStatus: Equatable {
    /// Claude Code is starting up.
    case starting
    case working
    /// Waiting on the user to allow or deny something risky.
    case needsApproval
    case done
    /// The user pressed Stop.
    case stopped
    case failed(String)

    var title: String {
        switch self {
        case .starting: return "Starting"
        case .working: return "Working"
        case .needsApproval: return "Needs your OK"
        case .done: return "Done"
        case .stopped: return "Stopped"
        case .failed: return "Couldn't finish"
        }
    }

    var isWorking: Bool {
        switch self {
        case .starting, .working, .needsApproval: return true
        case .done, .stopped, .failed: return false
        }
    }
}

/// One thing the agent did, in plain words ("Run tests", "Click Send").
struct AgentStep: Identifiable, Equatable {
    enum State: Equatable {
        case running
        case done
        case failed
        /// The user said no, or the agent was stopped first.
        case denied
    }

    let id: String
    let title: String
    let state: State

    func with(_ state: State) -> AgentStep { AgentStep(id: id, title: title, state: state) }
}

/// Something risky the agent wants to do, waiting for the user.
struct AgentApproval: Identifiable, Equatable {
    /// Claude Code's request id, answered with the decision.
    let id: String
    /// One line for the card, with commands in backticks.
    let summary: String
    /// What "Allow for this task" allows from then on.
    let grantKey: String

    /// Kinds too open to allow for the whole task: a command that can't be read in full,
    /// LocalFlow itself, a program opened from the terminal.
    static let oneAtATime: Set<String> = ["Bash:complex", "Bash:variable command", "Bash:curl | sh",
                                          "Bash:pipe to shell", "Bash:unknown", "Bash:localflow", "click:localflow",
                                          "Bash:open program"]

    var canAllowForTask: Bool { Self.canGrant(grantKey) }

    nonisolated static func canGrant(_ key: String) -> Bool { !oneAtATime.contains(key) }
}

/// What the agent panel shows. Never logged: tasks, steps and replies can hold anything.
@MainActor
final class AgentModel: ObservableObject {
    /// A long task keeps only its newest steps.
    static let maxSteps = 60

    @Published private(set) var task = ""
    @Published var status: AgentStatus = .starting
    @Published private(set) var steps: [AgentStep] = []
    @Published private(set) var approvals: [AgentApproval] = []
    /// The agent's words: streamed while it works, its summary once done.
    @Published var reply = ""
    /// For the elapsed counter in the header.
    @Published private(set) var startedAt = Date()
    /// An Instant Edits run: its steps are the fixed stages, not every tool call.
    @Published private(set) var isInstant = false
    /// The Instant edit just made can still be put back.
    @Published var canUndo = false
    /// Steps on the screen wait while the user types in the agent's window.
    @Published var isHeld = false
    /// Steps dropped off the front of a long task, still counted as earlier.
    private var dropped = 0

    func start(task: String, instant: Bool = false) {
        self.task = task
        isInstant = instant
        canUndo = false
        isHeld = false
        status = .starting
        steps = []
        approvals = []
        reply = ""
        dropped = 0
        startedAt = Date()
    }

    /// More for the same session: the new words become the task, the steps carry on.
    func followUp(task: String) {
        self.task = task
        status = approvals.isEmpty ? .working : .needsApproval
        reply = ""
        startedAt = Date()
    }

    func addStep(id: String, title: String) {
        guard !steps.contains(where: { $0.id == id }) else { return }
        let added = steps + [AgentStep(id: id, title: title, state: .running)]
        let overflow = max(0, added.count - Self.maxSteps)
        dropped += overflow
        steps = Array(added.dropFirst(overflow))
    }

    /// Only a running step finishes: one turned down stays turned down when its error arrives.
    func finishStep(id: String, state: AgentStep.State) {
        steps = steps.map { $0.id == id && $0.state == .running ? $0.with(state) : $0 }
    }

    /// Names a step better once what it acts on is known ("Click" → "Click “Send”").
    func retitle(id: String, title: String) {
        steps = steps.map { $0.id == id ? AgentStep(id: id, title: title, state: $0.state) : $0 }
    }

    /// Steps still running when the task ends didn't finish.
    func endRunningSteps(as state: AgentStep.State) {
        steps = steps.map { $0.state == .running ? $0.with(state) : $0 }
    }

    /// The newest `limit` steps, and how many came before them.
    func visibleSteps(limit: Int) -> (steps: [AgentStep], earlier: Int) {
        let shown = Array(steps.suffix(limit))
        return (shown, dropped + steps.count - shown.count)
    }

    func ask(_ approval: AgentApproval) {
        guard !approvals.contains(where: { $0.id == approval.id }) else { return }
        approvals = approvals + [approval]
        if status.isWorking { status = .needsApproval }
    }

    func resolve(id: String) {
        approvals = approvals.filter { $0.id != id }
        if approvals.isEmpty, status == .needsApproval { status = .working }
    }

    /// Every waiting approval is dropped (stopped, ended); returns their ids to deny.
    func clearApprovals() -> [String] {
        let ids = approvals.map(\.id)
        approvals = []
        if status == .needsApproval { status = .working }
        return ids
    }
}

/// Splits approval text on backticks so commands show in code type. Plain text only:
/// nothing in it (a link from the model, say) ever becomes clickable.
enum CodeSpans {
    struct Span: Equatable {
        let text: String
        let isCode: Bool
    }

    static func split(_ text: String) -> [Span] {
        let parts = text.components(separatedBy: "`")
        // An even count of parts means an unclosed backtick: show it all as written.
        guard parts.count > 1, parts.count % 2 == 1 else {
            return text.isEmpty ? [] : [Span(text: text, isCode: false)]
        }
        return parts.enumerated()
            .filter { !$0.element.isEmpty }
            .map { Span(text: $0.element, isCode: $0.offset % 2 == 1) }
    }
}
