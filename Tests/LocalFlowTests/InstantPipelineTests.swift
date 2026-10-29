import Foundation
import Testing
@testable import LocalFlow

/// The five stages before an Instant run starts editing, with fakes for the screen
/// capture, the sweep and the design profile.
@MainActor
@Suite("Instant Edits: the pipeline")
struct InstantPipelineTests {
    private static let request = "make the save button round"

    private struct FakeSweep: InstantSweeping {
        let result: InstantSweepResult
        let seen: Seen

        func check(_ input: InstantSweepInput) async -> InstantSweepResult {
            seen.input = input
            return result
        }
    }

    private final class Seen: @unchecked Sendable {
        var input: InstantSweepInput?
        var profileRoot: String?
    }

    private func pipeline(_ box: InstantSandbox, _ result: InstantSweepResult, seen: Seen = Seen(),
                          screenshot: String? = "iVBORw0K") -> InstantPipeline {
        InstantPipeline(capture: { screenshot }, sweep: FakeSweep(result: result, seen: seen),
                        readProfile: { root in
                            seen.profileRoot = root
                            return InstantDesignProfile(text: "Buttons are pill-shaped.", files: ["DESIGN.md"])
                        },
                        home: box.home)
    }

    private func small(_ path: String?, name: String = "Sundial") -> InstantSweepResult {
        InstantSweepResult(verdict: .small, project: path.map { InstantProject(name: name, path: $0) },
                           change: "Making the Save button round instead of square")
    }

    private func run(_ pipeline: InstantPipeline) async -> (InstantOutcome, [InstantStage]) {
        var stages: [InstantStage] = []
        let outcome = await pipeline.run(request: Self.request, memory: "Sundial: ~/code/app",
                                         recent: ["Sundial: made the header bold"]) { stages.append($0) }
        return (outcome, stages)
    }

    @Test("a small UI edit in a known project goes through all five stages")
    func ready() async throws {
        let box = try InstantSandbox()
        defer { box.cleanUp() }
        let app = try box.homeProject()
        let seen = Seen()
        let (outcome, stages) = await run(pipeline(box, small(app), seen: seen))
        #expect(stages == [.viewingScreen, .locatingProject, .projectFound("Sundial"), .readingDesignProfile,
                           .makingChange("Making the Save button round instead of square")])
        guard case .ready(let plan) = outcome else {
            Issue.record("not ready: \(outcome)")
            return
        }
        let root = try #require(InstantFolders.resolved(app))
        #expect(plan.project == InstantProject(name: "Sundial", path: root))
        #expect(plan.screenshotPNGBase64 == "iVBORw0K")
        #expect(plan.request == Self.request)
        #expect(plan.profile.files == ["DESIGN.md"])
        #expect(plan.change == "Making the Save button round instead of square")
        #expect(plan.instructions.contains(root))
        #expect(plan.instructions.contains("Buttons are pill-shaped."))
        #expect(seen.profileRoot == root)
        #expect(seen.input == InstantSweepInput(request: Self.request, screenshotPNGBase64: "iVBORw0K",
                                                memory: "Sundial: ~/code/app",
                                                recent: ["Sundial: made the header bold"]))
    }

    @Test("a folder written from home, or found by its package file, works too")
    func tildeAndManifest() async throws {
        let box = try InstantSandbox()
        defer { box.cleanUp() }
        try box.homeProject("site", marker: "package.json")
        let (outcome, _) = await run(pipeline(box, small("~/code/site")))
        guard case .ready(let plan) = outcome else {
            Issue.record("not ready: \(outcome)")
            return
        }
        #expect(plan.project.path.hasSuffix("/code/site"))
    }

    @Test("too big, not UI and unavailable stop after locating, with the user's message")
    func stops() async throws {
        let box = try InstantSandbox()
        defer { box.cleanUp() }
        let app = try box.homeProject()
        let cases: [(InstantVerdict, InstantStop)] = [
            (.tooBig("It rebuilds the whole calendar."), .tooBig("It rebuilds the whole calendar.")),
            (.notUI("It changes what Send does."), .notUI("It changes what Send does.")),
            (.unavailable("Couldn't check."), .unavailable("Couldn't check.")),
        ]
        for (verdict, stop) in cases {
            let result = InstantSweepResult(verdict: verdict, project: InstantProject(name: "Sundial", path: app), change: "")
            let (outcome, stages) = await run(pipeline(box, result))
            #expect(outcome == .stopped(stop))
            #expect(stages == [.viewingScreen, .locatingProject])
        }
        #expect(InstantStop.tooBig("It rebuilds the whole calendar.").message
                == "It rebuilds the whole calendar. Turn off Instant (⌘I) to run it as a normal agent task.")
        #expect(InstantStop.notUI(InstantSweepPrompt.notUIReason).message.components(separatedBy: "Turn off Instant").count == 2)
        #expect(InstantStop.unavailable("Couldn't check.").message == "Couldn't check.")
    }

    @Test("with no project named, nothing is edited and LocalFlow asks which one")
    func needsProject() async throws {
        let box = try InstantSandbox()
        defer { box.cleanUp() }
        let (outcome, stages) = await run(pipeline(box, small(nil)))
        #expect(outcome == .stopped(.needsProject(InstantStop.whichProject)))
        #expect(InstantStop.whichProject == "Which project is this? Tell me its folder or name and I'll remember it.")
        #expect(stages == [.viewingScreen, .locatingProject])
    }

    @Test("a folder that isn't a project under home counts as unknown")
    func badFolders() async throws {
        let box = try InstantSandbox()
        defer { box.cleanUp() }
        let outside = try box.project("outside")
        let plain = box.home + "/code/plain"
        try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
        let file = try box.write("x", to: box.home + "/code/file.txt")
        try FileManager.default.createDirectory(atPath: box.home + "/Library/Stuff/.git", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: box.home + "/.claude/.git", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: box.home + "/.git", withIntermediateDirectories: true)
        let paths = [outside, plain, file, box.home + "/code/missing", box.home, box.home + "/Library/Stuff",
                     box.home + "/.claude", "relative/path", "", "/etc", "/"]
        for path in paths {
            let (outcome, _) = await run(pipeline(box, small(path)))
            guard case .stopped(.needsProject(let message)) = outcome else {
                Issue.record("\(path): \(outcome)")
                continue
            }
            #expect(message.contains("Sundial"), "\(path)")
        }
    }

    @Test("no screenshot stops at the first stage")
    func noScreen() async throws {
        let box = try InstantSandbox()
        defer { box.cleanUp() }
        let app = try box.homeProject()
        let (outcome, stages) = await run(pipeline(box, small(app), screenshot: nil))
        #expect(outcome == .stopped(.unavailable(InstantStop.noScreen)))
        #expect(stages == [.viewingScreen])
    }

    @Test("the project's name falls back to its folder's name")
    func nameFallback() async throws {
        let box = try InstantSandbox()
        defer { box.cleanUp() }
        let app = try box.homeProject("invoices")
        let (_, stages) = await run(pipeline(box, small(app, name: " ")))
        #expect(stages.contains(.projectFound("invoices")))
    }
}
