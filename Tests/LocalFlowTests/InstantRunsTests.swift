import Foundation
import Testing
@testable import LocalFlow

@MainActor
@Suite("Instant Edits in the agent's window: stages, the project question, Undo")
struct InstantRunsTests {
    private func plan(_ root: String, profile: InstantDesignProfile = InstantDesignProfile(text: "## DESIGN.md\nPills.",
                                                                                         files: ["DESIGN.md"]))
        -> InstantPlan {
        InstantPlan(request: "make the save button round", screenshotPNGBase64: "png",
                    project: InstantProject(name: "Northwind", path: root), profile: profile,
                    change: "Making the Save button round instead of square", instructions: "edit the button")
    }

    private final class Remembered {
        var projects: [InstantProject] = []
    }

    private func runs(_ sandbox: InstantSandbox, outcome: InstantOutcome = .stopped(.unavailable("x")),
                      remembered: Remembered = Remembered()) -> InstantRuns {
        InstantRuns(prepare: { _, _, _, _, _ in outcome },
                    makeGuard: { plan in
                        InstantGuard(projects: [plan.project.path], home: sandbox.home,
                                     backupFolder: sandbox.backups)
                    },
                    remember: { remembered.projects.append($0) },
                    home: sandbox.home)
    }

    @Test("each stage shows as a step: screen, project (renamed to its name), design profile, the change")
    func stages() {
        let model = AgentModel()
        model.start(task: "make the save button round", instant: true)

        InstantRuns.show(.viewingScreen, on: model)
        InstantRuns.show(.locatingProject, on: model)
        #expect(model.steps.map(\.title) == ["Viewing screen", "Locating project"])
        #expect(model.steps.map(\.state) == [.done, .running])

        InstantRuns.show(.projectFound("Northwind"), on: model)
        InstantRuns.show(.readingDesignProfile, on: model)
        InstantRuns.show(.makingChange("Making the Save button round instead of square"), on: model)

        #expect(model.steps.map(\.title) == ["Viewing screen", "Northwind", "Reading design profile",
                                            "Making the Save button round instead of square"])
        #expect(model.steps.map(\.state) == [.done, .done, .done, .running])
    }

    @Test("a stop says why in the reply; Instant being unable to run is a failure")
    func stops() throws {
        let sandbox = try InstantSandbox()
        defer { sandbox.cleanUp() }
        let instant = runs(sandbox)
        let model = AgentModel()
        model.start(task: "rebuild the calendar like Google's", instant: true)
        InstantRuns.show(.viewingScreen, on: model)
        InstantRuns.show(.locatingProject, on: model)

        instant.stopped(.tooBig("That's a whole screen."), request: "rebuild the calendar", on: model)

        #expect(model.status == .stopped)
        #expect(model.reply.contains("Turn off Instant"))
        #expect(!model.steps.contains { $0.state == .running })

        instant.stopped(.unavailable("Couldn't check the size of that edit. Try again."), request: "x", on: model)
        #expect(model.status == .failed("Couldn't check the size of that edit. Try again."))
    }

    @Test("after LocalFlow asks which project, the answer joins the request it asked about, once")
    func projectAnswer() throws {
        let sandbox = try InstantSandbox()
        defer { sandbox.cleanUp() }
        let instant = runs(sandbox)
        let model = AgentModel()

        instant.stopped(.needsProject(InstantStop.whichProject), request: "make the save button round", on: model)
        let joined = instant.request(for: "it's the site in ~/northwind")

        #expect(joined.hasPrefix("make the save button round"))
        #expect(joined.contains("it's the site in ~/northwind"))
        #expect(instant.request(for: "make the title bigger") == "make the title bigger")
    }

    @Test("a project question left unanswered when the window closes doesn't join a later request")
    func questionDropped() throws {
        let sandbox = try InstantSandbox()
        defer { sandbox.cleanUp() }
        let instant = runs(sandbox)
        instant.stopped(.needsProject(InstantStop.whichProject), request: "make the save button round",
                        on: AgentModel())

        instant.finish()

        #expect(instant.request(for: "make the footer gray") == "make the footer gray")
    }

    @Test("after the project question, Choose Folder hands back the request in that folder, and remembers it")
    func choose() throws {
        let sandbox = try InstantSandbox()
        defer { sandbox.cleanUp() }
        let folder = try sandbox.homeProject("northwind")
        let plain = sandbox.home + "/code/plain"
        try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
        let remembered = Remembered()
        let instant = runs(sandbox, remembered: remembered)
        let model = AgentModel()
        model.start(task: "make the save button round", instant: true)

        instant.stopped(.needsProject(InstantStop.whichProject), request: "make the save button round", on: model)
        #expect(model.canChooseProject)
        #expect(instant.chose(plain, on: model) == nil)
        #expect(model.reply == InstantRuns.notAProject)
        #expect(model.canChooseProject)
        let chosen = try #require(instant.chose(folder, on: model))

        #expect(chosen.request == "make the save button round")
        #expect(chosen.project == InstantProject(name: "northwind",
                                                 path: try #require(InstantFolders.projectRoot(folder, home: sandbox.home))))
        #expect(remembered.projects == [chosen.project])
        #expect(instant.request(for: "make the title bigger") == "make the title bigger")
        #expect(instant.chose(folder, on: model) == nil)
    }

    @Test("Choose Folder after a typed answer hands back the first request, without the answer")
    func chooseAfterAnswer() throws {
        let sandbox = try InstantSandbox()
        defer { sandbox.cleanUp() }
        let folder = try sandbox.homeProject("northwind")
        let instant = runs(sandbox)
        let model = AgentModel()
        instant.stopped(.needsProject(InstantStop.whichProject), request: "make the save button round", on: model)
        let merged = instant.request(for: "its called Northwind")
        instant.stopped(.needsProject(InstantStop.whichProject), request: merged, on: model)

        let chosen = try #require(instant.chose(folder, on: model))

        #expect(chosen.request == "make the save button round")
    }

    @Test("Choose Folder is only offered for the project question")
    func chooseOnlyForProject() throws {
        let sandbox = try InstantSandbox()
        defer { sandbox.cleanUp() }
        let instant = runs(sandbox)
        let model = AgentModel()
        instant.stopped(.needsProject(InstantStop.whichProject), request: "make it round", on: model)
        #expect(model.canChooseProject)

        instant.stopped(.tooBig("It rebuilds the whole calendar."), request: "redo the calendar", on: model)
        #expect(!model.canChooseProject)
        instant.stopped(.needsProject(InstantStop.whichProject), request: "make it round", on: model)
        model.start(task: "make it round", instant: true)
        #expect(!model.canChooseProject)
    }

    @Test("a ready run's project is remembered; a stopped run remembers nothing")
    func remembers() async throws {
        let sandbox = try InstantSandbox()
        defer { sandbox.cleanUp() }
        let root = try sandbox.project()
        let remembered = Remembered()
        let ready = runs(sandbox, outcome: .ready(plan(root)), remembered: remembered)
        let stopped = runs(sandbox, outcome: .stopped(.needsProject(InstantStop.whichProject)), remembered: remembered)

        _ = await ready.prepare("make the save button round", project: nil, displayID: 1) { _ in }
        _ = await stopped.prepare("make the save button round", project: nil, displayID: 1) { _ in }

        #expect(remembered.projects == [InstantProject(name: "Northwind", path: root)])
    }

    @Test("a project's memory line has its name, folder and repo, unless the memory has that folder already")
    func memoryLine() throws {
        let box = try InstantSandbox()
        defer { box.cleanUp() }
        let folder = try box.homeProject("northwind")
        try box.write("[remote \"origin\"]\n\turl = git@github.com:Acme/northwind.git\n", to: folder + "/.git/config")
        let root = try #require(InstantFolders.projectRoot(folder, home: box.home))
        let project = InstantProject(name: "Northwind", path: root)

        #expect(InstantRuns.memoryLine(for: project, memory: "- Sundial | folder: ~/code/northwind-site", home: box.home)
                == "Northwind | folder: ~/code/northwind | repo: Acme/northwind")
        #expect(InstantRuns.memoryLine(for: project, memory: "- Northwind | folder: ~/code/northwind | cues: logo",
                                       home: box.home) == nil)
        #expect(InstantRuns.memoryLine(for: project, memory: "- NW lives in " + root + "/.", home: box.home) == nil)
        #expect(InstantRuns.memoryLine(for: project, memory: "- Northwind | folder: ~/Code/Northwind", home: box.home)
                == nil)
        #expect(InstantRuns.memoryLine(for: project, memory: "- Web | folder: ~/code/northwind/web", home: box.home)
                == "Northwind | folder: ~/code/northwind | repo: Acme/northwind")
        let odd = InstantProject(name: "North | wind", path: root)
        #expect(InstantRuns.memoryLine(for: odd, memory: "", home: box.home)?.hasPrefix("North / wind | folder: ") == true)
    }

    @Test("the sweep reads the memory, then the Settings folders, then the folders found on the Mac")
    func sweepMemory() throws {
        let found = InstantCatalog.heading + "\n- ~/code/orbit"
        let text = InstantRuns.projectMemory("## Projects\n- Sundial", listed: ["/Users/someone/code/sundial"],
                                             found: found)
        let memory = try #require(text.range(of: "- Sundial"))
        let listed = try #require(text.range(of: "- folder: /Users/someone/code/sundial"))
        let folders = try #require(text.range(of: "- ~/code/orbit"))
        #expect(memory.lowerBound < listed.lowerBound)
        #expect(listed.lowerBound < folders.lowerBound)
        #expect(InstantRuns.projectMemory("m", listed: [], found: "") == "m")
    }

    @Test("a run gets the Instant model's tools and instructions, and no connectors")
    func options() throws {
        let sandbox = try InstantSandbox()
        defer { sandbox.cleanUp() }
        let root = try sandbox.project()
        let instant = runs(sandbox)

        let options = instant.began(plan(root))

        #expect(options.tools == InstantPrompt.tools)
        #expect(options.appendPrompt == "edit the button")
        #expect(options.servers.isEmpty)
        #expect(options.effort == InstantRuns.effort)
    }

    @Test("edits go through the guard: inside the project yes, outside no, with a reason for the model")
    func review() throws {
        let sandbox = try InstantSandbox()
        defer { sandbox.cleanUp() }
        let root = try sandbox.project()
        let file = try sandbox.write("<button class=\"rounded-none\">Save</button>\n", to: root + "/Save.html")
        let outside = try sandbox.write("x\n", to: sandbox.home + "/other.txt")
        let instant = runs(sandbox)

        _ = instant.began(plan(root))
        #expect(instant.review(toolName: "Edit", input: InstantInput.edit(file, "rounded-none", "rounded-full")) == .allow)
        #expect(instant.review(toolName: "Edit", input: InstantInput.edit(outside, "x", "y")).message != nil)
    }

    @Test("with no run under way, nothing is allowed")
    func noRun() throws {
        let sandbox = try InstantSandbox()
        defer { sandbox.cleanUp() }
        #expect(runs(sandbox).review(toolName: "Read", input: InstantInput.read("/tmp/x")).message != nil)
    }

    @Test("when the turn ends, a changed file offers Undo, and Undo puts it back")
    func undo() throws {
        let sandbox = try InstantSandbox()
        defer { sandbox.cleanUp() }
        let root = try sandbox.project()
        let original = "<button class=\"rounded-none\">Save</button>\n"
        let file = try sandbox.write(original, to: root + "/Save.html")
        let instant = runs(sandbox)
        let model = AgentModel()
        model.start(task: "round it", instant: true)
        _ = instant.began(plan(root))

        #expect(instant.review(toolName: "Edit", input: InstantInput.edit(file, "rounded-none", "rounded-full")) == .allow)
        try sandbox.write("<button class=\"rounded-full\">Save</button>\n", to: file)
        instant.turnEnded(on: model)

        #expect(model.canUndo)
        #expect(instant.recent == ["Northwind: Making the Save button round instead of square"])

        instant.undo(on: model)

        #expect(sandbox.read(file) == original)
        #expect(!model.canUndo)
        #expect(model.reply == "Put back 1 file.")
    }

    @Test("a run that changed nothing offers no Undo")
    func nothingChanged() throws {
        let sandbox = try InstantSandbox()
        defer { sandbox.cleanUp() }
        let root = try sandbox.project()
        let instant = runs(sandbox)
        let model = AgentModel()
        _ = instant.began(plan(root))

        instant.turnEnded(on: model)

        #expect(!model.canUndo)
    }

    @Test("with no design profile, the step says it's matching the app's own styles")
    func noProfile() throws {
        let sandbox = try InstantSandbox()
        defer { sandbox.cleanUp() }
        let root = try sandbox.project()
        let model = AgentModel()
        InstantRuns.show(.readingDesignProfile, on: model)

        InstantRuns.ready(plan(root, profile: InstantDesignProfile(text: "", files: [])), on: model)

        #expect(model.steps.first?.title == InstantRuns.noProfile)
    }

    @Test("Undo's words", arguments: [
        (InstantUndoResult(restored: 2, deleted: 0, failed: 0), "Put back 2 files."),
        (InstantUndoResult(restored: 1, deleted: 1, failed: 0), "Put back 1 file and removed 1 new file."),
        (InstantUndoResult(restored: 0, deleted: 0, failed: 1),
         "Left 1 file as it is: it changed after the edit."),
        (InstantUndoResult(restored: 0, deleted: 0, failed: 0), "Nothing to undo."),
    ])
    func undoWords(result: InstantUndoResult, words: String) {
        #expect(InstantRuns.undoMessage(result) == words)
    }
}
