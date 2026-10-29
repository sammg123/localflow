import Foundation

/// Instant Edits in the agent's window. Gets each run ready stage by stage (the screen,
/// the project, its design profile, the change) and shows the stages as the panel's
/// steps, answers the run's permission requests through its guard, and undoes its edits.
@MainActor
final class InstantRuns {
    /// `project` is one the user chose, or nil to have the sweep tell.
    typealias Prepare = @MainActor (_ request: String, _ project: InstantProject?, _ displayID: UInt32,
                                    _ recent: [String], _ onStage: (InstantStage) -> Void) async -> InstantOutcome
    typealias MakeGuard = @MainActor (InstantPlan) -> InstantGuard
    /// Notes a project in LocalFlow's memory, so the next run knows it.
    typealias Remember = @MainActor (InstantProject) -> Void

    /// Small edits want speed over deliberation.
    static let effort = "low"
    static let maxRecent = 5
    static let noProfile = "No design profile, matching the app's own styles"
    static let notAProject = "That folder isn't a project's top folder. Choose the one with .git or package.json in it."

    /// The panel's steps for the stages.
    enum Step {
        static let screen = "instant.screen"
        static let project = "instant.project"
        static let profile = "instant.profile"
        static let change = "instant.change"
    }

    /// Lines about the last few runs ("Northwind: Making the title bold"), newest first: how
    /// the sweep tells which project "it" is when the user doesn't say.
    private(set) var recent: [String] = []

    private let prepareRun: Prepare
    private let makeGuard: MakeGuard
    private let remember: Remember
    private let home: String
    /// The run under way, and what guards its edits.
    private var plan: InstantPlan?
    private var fence: InstantGuard?
    /// A request that stopped to ask which project it's in: the answer joins it.
    private var unanswered: String?
    private static let answerJoin = "\n\nAbout which project this is, the user says: "

    init(prepare: @escaping Prepare = InstantRuns.live, makeGuard: @escaping MakeGuard = InstantRuns.liveGuard,
         remember: @escaping Remember = InstantRuns.liveRemember, home: String = NSHomeDirectory()) {
        prepareRun = prepare
        self.makeGuard = makeGuard
        self.remember = remember
        self.home = home
    }

    // MARK: Getting ready

    /// After LocalFlow asked which project, the user's answer and the request it was about.
    func request(for task: String) -> String {
        guard let asked = unanswered else { return task }
        unanswered = nil
        return asked + Self.answerJoin + task
    }

    /// A run that gets as far as editing has found its project, so it's remembered.
    func prepare(_ request: String, project: InstantProject? = nil, displayID: UInt32,
                 onStage: (InstantStage) -> Void) async -> InstantOutcome {
        let outcome = await prepareRun(request, project, displayID, recent, onStage)
        if case .ready(let plan) = outcome { remember(plan.project) }
        return outcome
    }

    /// The user chose a folder for the request that asked which project: that request and
    /// the project, remembered for next time. Nil when no request is waiting, or (with the
    /// reason as the reply) when the folder isn't a project's top folder.
    func chose(_ folder: String, on model: AgentModel) -> (request: String, project: InstantProject)? {
        guard let asked = unanswered else { return nil }
        // The chosen folder settles which project, so any typed answer about it is dropped.
        let request = asked.range(of: Self.answerJoin).map { String(asked[..<$0.lowerBound]) } ?? asked
        guard let root = InstantFolders.projectRoot(folder, home: home) else {
            model.reply = Self.notAProject
            FlowLog.shared.write("instant: the chosen folder isn't a project")
            return nil
        }
        let project = InstantProject(name: URL(fileURLWithPath: root).lastPathComponent, path: root)
        unanswered = nil
        model.canChooseProject = false
        remember(project)
        return (request, project)
    }

    static func show(_ stage: InstantStage, on model: AgentModel) {
        switch stage {
        case .viewingScreen:
            model.addStep(id: Step.screen, title: "Viewing screen")
        case .locatingProject:
            model.finishStep(id: Step.screen, state: .done)
            model.addStep(id: Step.project, title: "Locating project")
        case .projectFound(let name):
            model.retitle(id: Step.project, title: name)
            model.finishStep(id: Step.project, state: .done)
        case .readingDesignProfile:
            model.addStep(id: Step.profile, title: "Reading design profile")
        case .makingChange(let detail):
            model.finishStep(id: Step.profile, state: .done)
            model.addStep(id: Step.change, title: detail.isEmpty ? "Making the change" : detail)
        }
    }

    /// Ready to edit: says so when the project has no design profile to go by.
    static func ready(_ plan: InstantPlan, on model: AgentModel) {
        if plan.profile.isEmpty { model.retitle(id: Step.profile, title: noProfile) }
    }

    /// Stopped before editing anything: the reason (or the project question) is the reply.
    func stopped(_ stop: InstantStop, request: String, on model: AgentModel) {
        if case .needsProject = stop { unanswered = request } else { unanswered = nil }
        model.canChooseProject = unanswered != nil
        model.endRunningSteps(as: .denied)
        if case .unavailable(let message) = stop {
            model.status = .failed(message)
        } else {
            model.reply = stop.message
            model.status = .stopped
        }
        FlowLog.shared.write("instant: stopped before editing (\(Self.kind(stop)))")
    }

    // MARK: The run

    /// The session's settings, and a fresh guard for this run's edits.
    func began(_ plan: InstantPlan) -> AgentRunOptions {
        self.plan = plan
        fence = makeGuard(plan)
        return AgentRunOptions(effort: Self.effort, appendPrompt: plan.instructions, tools: InstantPrompt.tools)
    }

    func review(toolName: String, input: AgentJSON) -> InstantDecision {
        fence?.review(toolName: toolName, input: input) ?? .deny(InstantRefusal.noRun)
    }

    /// Checks what the run changed (putting back anything it left broken) and offers Undo.
    /// Only the first call after a run does anything.
    func turnEnded(on model: AgentModel) {
        guard let fence, !fence.runEnded else { return }
        let putBack = fence.verifyAfterRun()
        model.canUndo = fence.hasChanges
        if !putBack.isEmpty {
            let names = putBack.joined(separator: ", ")
            model.reply += (model.reply.isEmpty ? "" : "\n\n") + "Put back \(names): the edit left it broken."
        }
        if let plan {
            recent = Array(([plan.project.name + ": " + plan.change] + recent).prefix(Self.maxRecent))
        }
    }

    func undo(on model: AgentModel) {
        guard let fence else { return }
        let result = fence.undo()
        model.canUndo = false
        model.reply = Self.undoMessage(result)
        FlowLog.shared.write("instant: undo put back \(result.restored), removed \(result.deleted), left \(result.failed)")
    }

    /// The run is over and its window closed: nothing left to guard or undo.
    func finish() {
        plan = nil
        fence = nil
        unanswered = nil
    }

    static func undoMessage(_ result: InstantUndoResult) -> String {
        let files = { (count: Int) in count == 1 ? "1 file" : "\(count) files" }
        let newFiles = { (count: Int) in count == 1 ? "1 new file" : "\(count) new files" }
        var done: [String] = []
        if result.restored > 0 { done.append("put back \(files(result.restored))") }
        if result.deleted > 0 { done.append("removed \(newFiles(result.deleted))") }
        var sentences: [String] = []
        if !done.isEmpty {
            let joined = done.joined(separator: " and ")
            sentences.append(joined.prefix(1).uppercased() + joined.dropFirst() + ".")
        }
        if result.failed > 0 {
            sentences.append("Left \(files(result.failed)) as it is: it changed after the edit.")
        }
        return sentences.isEmpty ? "Nothing to undo." : sentences.joined(separator: " ")
    }

    private static func kind(_ stop: InstantStop) -> String {
        switch stop {
        case .tooBig: return "too big"
        case .notUI: return "not UI"
        case .needsProject: return "which project"
        case .unavailable: return "unavailable"
        }
    }

    // MARK: The real thing

    /// The screen, LocalFlow's memory of the user's projects (plus any set up in
    /// Settings, and the project folders found on the Mac), and the sweep.
    static func live(request: String, project: InstantProject?, displayID: UInt32, recent: [String],
                     onStage: (InstantStage) -> Void) async -> InstantOutcome {
        let memory = FlowMemory()
        let pipeline = InstantPipeline(
            capture: { (try? await ScreenCapturer.capturePNG(displayID: displayID))?.base64EncodedString() },
            sweep: InstantSweep(), memoryPaths: [noteFile(memory)])
        // Finding the Mac's project folders takes a moment, so it runs while the screen is seen.
        let scan = Task.detached(priority: .utility) { project == nil ? InstantCatalog.text() : "" }
        let known = {
            projectMemory(memory.read().memory, listed: InstantProjects.shared.paths, found: await scan.value)
        }
        return await pipeline.run(request: request, project: project, memory: known, recent: recent, onStage: onStage)
    }

    /// Adds the project's line to flow-memory.md unless the memory has its folder already;
    /// the memory logs why, if it can't.
    static func liveRemember(_ project: InstantProject) {
        let memory = FlowMemory()
        guard let line = memoryLine(for: project, memory: memory.read().memory) else { return }
        memory.remember([(section: .projects, text: line)])
    }

    /// "Northwind | folder: ~/code/northwind | repo: Acme/northwind", in the memory's own
    /// format, or nil when the memory already names the project's folder.
    static func memoryLine(for project: InstantProject, memory: String,
                           home: String = NSHomeDirectory()) -> String? {
        let realHome = InstantPaths.realPath(home) ?? home
        let inHome = InstantPaths.isInside(project.path, realHome)
        let folder = inHome ? "~/" + InstantPaths.relative(project.path, to: realHome) : project.path
        let spellings = [folder, project.path, home + "/" + InstantPaths.relative(project.path, to: realHome)]
        guard !spellings.contains(where: { mentions(memory, folder: $0) }) else { return nil }
        let cleaned = InstantCatalog.field(project.name)
        let name = cleaned.isEmpty ? URL(fileURLWithPath: project.path).lastPathComponent : cleaned
        let parts = [name, "folder: " + folder, InstantCatalog.repo(in: project.path).map { "repo: " + $0 }]
        return parts.compactMap { $0 }.joined(separator: " | ")
    }

    /// Whether `memory` has `folder` as a whole path, in any case: "~/app" isn't in
    /// "~/app-site", nor in "~/app/web", a folder inside it.
    private static func mentions(_ memory: String, folder: String) -> Bool {
        let pathCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~"))
        let isPathCharacter = { (character: Character?) in
            character.map { $0.unicodeScalars.allSatisfy(pathCharacters.contains) } ?? false
        }
        var searched = memory.startIndex..<memory.endIndex
        while let found = memory.range(of: folder, options: .caseInsensitive, range: searched) {
            let before = found.lowerBound == memory.startIndex ? nil : memory[memory.index(before: found.lowerBound)]
            let after = found.upperBound == memory.endIndex ? nil : memory[found.upperBound]
            let inside = after == "/" && memory[found.upperBound...].dropFirst().first.map {
                $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_"
            } == true
            if !isPathCharacter(before), before != "/", !isPathCharacter(after), !inside { return true }
            searched = found.upperBound..<memory.endIndex
        }
        return false
    }

    static func liveGuard(_ plan: InstantPlan) -> InstantGuard {
        InstantGuard(projects: [plan.project.path], memoryPaths: [noteFile(FlowMemory())])
    }

    /// Instant may note a project it found in flow-memory.md; the standing instructions
    /// in localflow.md are only ever the user's to change.
    private static func noteFile(_ memory: FlowMemory) -> String {
        memory.memoryURL.standardizedFileURL.path
    }

    /// The memory file, then the project folders listed in Settings, then those found on the Mac.
    static func projectMemory(_ memory: String, listed: [String], found: String) -> String {
        let settings = listed.isEmpty ? ""
            : "## Projects set up for Instant Edits in Settings\n" + listed.map { "- folder: \($0)" }.joined(separator: "\n")
        return ([memory] + [settings, found].filter { !$0.isEmpty }).joined(separator: "\n\n")
    }
}
