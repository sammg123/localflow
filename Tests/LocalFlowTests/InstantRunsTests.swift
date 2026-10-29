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

    private func runs(_ sandbox: InstantSandbox, outcome: InstantOutcome = .stopped(.unavailable("x"))) -> InstantRuns {
        InstantRuns(prepare: { _, _, _, _ in outcome },
                    makeGuard: { plan in
                        InstantGuard(projects: [plan.project.path], home: sandbox.home,
                                     backupFolder: sandbox.backups)
                    })
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
