import AppKit
import Foundation
import Testing
@testable import LocalFlow

@MainActor
@Suite("Agent: Instant Edits runs", .serialized)
struct AgentInstantTests {
    let surface = FakeAgentSurface()
    let sandbox: InstantSandbox
    let root: String

    private final class Made {
        var sessions: [FakeAgentSession] = []
        var models: [String] = []
        var options: [AgentRunOptions] = []
        var prepared: [String] = []
        var projects: [InstantProject?] = []
        var picks = 0
    }
    private let made = Made()
    private var session: FakeAgentSession { made.sessions.last! }

    init() throws {
        sandbox = try InstantSandbox()
        root = try sandbox.project()
    }

    private var plan: InstantPlan {
        InstantPlan(request: "make the save button round", screenshotPNGBase64: "c2NyZWVu",
                    project: InstantProject(name: "Northwind", path: root),
                    profile: InstantDesignProfile(text: "## DESIGN.md\nPills.", files: ["DESIGN.md"]),
                    change: "Making the Save button round instead of square", instructions: "edit the button")
    }

    private func makeController(_ outcome: InstantOutcome? = nil, chosen: String? = nil,
                                picker: (@MainActor () async -> String?)? = nil) -> AgentController {
        let ready = outcome ?? .ready(plan)
        let instant = InstantRuns(
            prepare: { [made] request, project, _, _, onStage in
                made.prepared.append(request)
                made.projects.append(project)
                onStage(.viewingScreen)
                onStage(.locatingProject)
                guard case .ready(let plan) = ready else { return ready }
                onStage(.projectFound(plan.project.name))
                onStage(.readingDesignProfile)
                onStage(.makingChange(plan.change))
                return ready
            },
            makeGuard: { [sandbox] plan in
                InstantGuard(projects: [plan.project.path], home: sandbox.home, backupFolder: sandbox.backups)
            },
            remember: { _ in },
            home: sandbox.home)
        return AgentController(
            surface: surface,
            indicator: FakeIndicator(),
            makeSession: { [made] model, _, options in
                let session = FakeAgentSession()
                made.sessions.append(session)
                made.models.append(model)
                made.options.append(options)
                return session
            },
            displayID: { _ in 1 },
            mapping: { _ in ScreenMapping(displayBounds: CGRect(x: 0, y: 0, width: 1280, height: 800)) },
            lookUp: { _ in .unnamed },
            frontApp: { nil },
            alwaysAllow: { false },
            memory: { "" },
            instant: instant,
            chooseFolder: picker ?? { chosen },
            chime: {},
            finished: { _ in }
        )
    }

    private func until(_ condition: () -> Bool) async {
        for _ in 0..<400 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("an Instant run shows its stages, then edits with the Instant model, tools and the screenshot")
    func runs() async {
        defer { sandbox.cleanUp() }
        let agent = makeController()

        agent.run("make the save button round", on: nil, instant: true)
        await until { !made.sessions.isEmpty }

        #expect(surface.model.isInstant)
        #expect(surface.model.steps.map(\.title) == ["Viewing screen", "Northwind", "Reading design profile",
                                                    "Making the Save button round instead of square"])
        #expect(made.models == [InstantPrompt.model])
        #expect(made.options.first?.tools == InstantPrompt.tools)
        #expect(made.options.first?.appendPrompt == "edit the button")
        #expect(session.started == ["make the save button round"])
        #expect(session.startedImages == ["c2NyZWVu"])
    }

    @Test("its tool calls don't become steps, and the guard answers them with no card")
    func guarded() async throws {
        defer { sandbox.cleanUp() }
        let file = try sandbox.write("<button class=\"rounded-none\">Save</button>\n", to: root + "/Save.html")
        let agent = makeController()
        agent.run("make the save button round", on: nil, instant: true)
        await until { !made.sessions.isEmpty }

        session.emit(.toolStarted(id: "t1", name: "Edit", input: InstantInput.edit(file, "rounded-none", "rounded-full")))
        session.emit(.permissionRequest(requestID: "r1", toolName: "Edit",
                                        input: InstantInput.edit(file, "rounded-none", "rounded-full"),
                                        description: nil, toolUseID: "t1"))
        session.emit(.permissionRequest(requestID: "r2", toolName: "Edit",
                                        input: InstantInput.edit("/etc/hosts", "a", "b"), description: nil,
                                        toolUseID: "t2"))
        await until { session.answers.count == 2 }

        #expect(session.answers.map(\.allow) == [true, false])
        #expect(session.messages.last??.isEmpty == false)
        #expect(surface.model.approvals.isEmpty)
        #expect(surface.model.steps.count == 4)
    }

    @Test("when the edit's done, Undo is offered and puts the file back")
    func undo() async throws {
        defer { sandbox.cleanUp() }
        let original = "<button class=\"rounded-none\">Save</button>\n"
        let file = try sandbox.write(original, to: root + "/Save.html")
        let agent = makeController()
        agent.run("make the save button round", on: nil, instant: true)
        await until { !made.sessions.isEmpty }
        session.emit(.permissionRequest(requestID: "r1", toolName: "Edit",
                                        input: InstantInput.edit(file, "rounded-none", "rounded-full"),
                                        description: nil, toolUseID: "t1"))
        await until { session.answers.count == 1 }
        try sandbox.write("<button class=\"rounded-full\">Save</button>\n", to: file)

        session.emit(.turnFinished(failure: nil, finalText: "Rounded the Save button."))
        await until { surface.model.status == .done }
        #expect(surface.model.canUndo)
        #expect(surface.model.steps.allSatisfy { $0.state == .done })

        surface.onUndo?()

        #expect(sandbox.read(file) == original)
        #expect(!surface.model.canUndo)
    }

    @Test("too big for Instant: no session starts, and the panel says to turn Instant off")
    func tooBig() async {
        defer { sandbox.cleanUp() }
        let agent = makeController(.stopped(.tooBig("That redoes a whole screen.")))

        agent.run("make the calendar look like Google Calendar", on: nil, instant: true)
        await until { surface.model.status == .stopped }

        #expect(made.sessions.isEmpty)
        #expect(surface.model.reply.contains("Turn off Instant"))
    }

    @Test("after it asks which project, the answer runs with the first request")
    func whichProject() async {
        defer { sandbox.cleanUp() }
        let agent = makeController(.stopped(.needsProject(InstantStop.whichProject)))
        agent.run("make the save button round", on: nil, instant: true)
        await until { surface.model.status == .stopped }
        #expect(surface.model.reply == InstantStop.whichProject)

        agent.run("the one in ~/northwind", on: nil, instant: true)
        await until { made.prepared.count == 2 }

        #expect(made.prepared.last?.hasPrefix("make the save button round") == true)
        #expect(made.prepared.last?.contains("the one in ~/northwind") == true)
    }

    @Test("Choose Folder after it asks which project runs the first request in that folder")
    func chooseFolder() async throws {
        defer { sandbox.cleanUp() }
        let folder = try sandbox.homeProject("northwind")
        let agent = makeController(.stopped(.needsProject(InstantStop.whichProject)), chosen: folder)
        agent.run("make the save button round", on: nil, instant: true)
        await until { surface.model.status == .stopped }
        #expect(surface.model.canChooseProject)

        surface.onChooseProject?()
        await until { made.prepared.count == 2 }

        #expect(made.prepared.last == "make the save button round")
        #expect(made.projects.last??.path == InstantFolders.projectRoot(folder, home: sandbox.home))
        #expect(surface.model.task == "make the save button round")
    }

    @Test("a second click while the folder picker is open doesn't open another")
    func chooseOnce() async throws {
        defer { sandbox.cleanUp() }
        let folder = try sandbox.homeProject("northwind")
        let agent = makeController(.stopped(.needsProject(InstantStop.whichProject)), picker: { [made] in
            made.picks += 1
            try? await Task.sleep(for: .milliseconds(50))
            return folder
        })
        agent.run("make the save button round", on: nil, instant: true)
        await until { surface.model.status == .stopped }

        surface.onChooseProject?()
        surface.onChooseProject?()
        await until { made.prepared.count == 2 }
        try? await Task.sleep(for: .milliseconds(150))

        #expect(made.picks == 1)
        #expect(made.prepared.count == 2)
    }

    @Test("Choose Folder closed without a folder leaves the question up")
    func chooseNothing() async {
        defer { sandbox.cleanUp() }
        let agent = makeController(.stopped(.needsProject(InstantStop.whichProject)))
        agent.run("make the save button round", on: nil, instant: true)
        await until { surface.model.status == .stopped }

        surface.onChooseProject?()
        try? await Task.sleep(for: .milliseconds(50))

        #expect(made.prepared.count == 1)
        #expect(surface.model.canChooseProject)
        #expect(surface.model.reply == InstantStop.whichProject)
    }

    @Test("a normal task after an Instant run starts its own session, with the full agent")
    func normalAfterInstant() async {
        defer { sandbox.cleanUp() }
        let agent = makeController()
        agent.run("make the save button round", on: nil, instant: true)
        await until { !made.sessions.isEmpty }
        session.emit(.turnFinished(failure: nil, finalText: "Done."))
        await until { surface.model.status == .done }

        agent.run("now open a pull request", on: nil)

        #expect(made.sessions.count == 2)
        #expect(made.sessions.first?.closes == 1)
        #expect(made.options.last?.tools == AgentInvocation.tools)
        #expect(!surface.model.isInstant)
    }

    @Test("a stage that lands after Stop doesn't touch the stopped panel")
    func lateStage() async {
        defer { sandbox.cleanUp() }
        let instant = InstantRuns(prepare: { _, _, _, _, onStage in
            onStage(.viewingScreen)
            try? await Task.sleep(for: .milliseconds(40))
            onStage(.locatingProject)
            return .stopped(.unavailable("late"))
        }, makeGuard: { InstantGuard(projects: [$0.project.path]) }, remember: { _ in }, home: sandbox.home)
        let agent = AgentController(surface: surface, indicator: FakeIndicator(),
                                    makeSession: { _, _, _ in FakeAgentSession() }, displayID: { _ in 1 },
                                    memory: { "" }, instant: instant, chime: {}, finished: { _ in })
        agent.run("make the save button round", on: nil, instant: true)
        await until { !surface.model.steps.isEmpty }

        agent.stop()
        try? await Task.sleep(for: .milliseconds(100))

        #expect(surface.model.status == .stopped)
        #expect(!surface.model.steps.contains { $0.state == .running })
        #expect(surface.model.steps.count == 1)
    }

    @Test("Stop while it's getting ready: nothing starts")
    func stopWhileReady() async {
        defer { sandbox.cleanUp() }
        let agent = makeController(.stopped(.unavailable("never")))
        agent.run("make the save button round", on: nil, instant: true)

        agent.stop()
        try? await Task.sleep(for: .milliseconds(50))

        #expect(made.sessions.isEmpty)
        #expect(surface.model.status == .stopped)
    }
}
