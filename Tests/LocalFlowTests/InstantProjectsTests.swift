import Foundation
import Testing
@testable import LocalFlow

@MainActor
@Suite("Instant Edits: the project folders list")
struct InstantProjectsTests {
    @MainActor
    private struct Fixture {
        let box: InstantSandbox
        let suite: String
        let defaults: UserDefaults
        let projects: InstantProjects

        init() throws {
            box = try InstantSandbox()
            suite = "instant-projects-test-\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: suite))
            projects = InstantProjects(defaults: defaults, home: box.home)
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: suite)
            box.cleanUp()
        }
    }

    private func url(_ path: String) -> URL {
        URL(fileURLWithPath: path)
    }

    @Test("a git project's top folder is added and saved")
    func adds() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let app = try fixture.box.homeProject()
        #expect(fixture.projects.add(url(app)) == nil)
        let saved = try #require(InstantFolders.resolved(app))
        #expect(fixture.projects.paths == [saved])
        #expect(fixture.defaults.stringArray(forKey: InstantProjects.defaultsKey) == [saved])
        let reloaded = InstantProjects(defaults: fixture.defaults, home: fixture.box.home)
        #expect(reloaded.paths == [saved])
    }

    @Test("a worktree, whose .git is a file, counts as a project")
    func worktree() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let tree = fixture.box.home + "/code/tree"
        try fixture.box.write("gitdir: /elsewhere\n", to: tree + "/.git")
        #expect(fixture.projects.add(url(tree)) == nil)
    }

    @Test("folders that aren't a project's top folder are refused, each with a reason")
    func refuses() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let box = fixture.box
        let plain = box.home + "/code/plain"
        try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
        let file = try box.write("x", to: box.home + "/code/notes.txt")
        try FileManager.default.createDirectory(atPath: box.home + "/.git", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: box.home + "/Library/Thing/.git", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: box.home + "/.claude/.git", withIntermediateDirectories: true)
        let refused = [plain, file, box.home + "/code/missing", box.home, box.home + "/Library/Thing", box.home + "/.claude",
                       "/", "/System", "/usr", "/Applications", "/Library", "/etc"]
        for path in refused {
            let message = fixture.projects.add(url(path))
            #expect(message?.isEmpty == false, "\(path)")
        }
        #expect(fixture.projects.add(url("/usr"))?.contains("system") == true)
        #expect(fixture.projects.add(url(box.home))?.contains("home folder") == true)
        #expect(fixture.projects.paths.isEmpty)
    }

    @Test("the same project, one inside another, or one around another is refused")
    func overlaps() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let outer = try fixture.box.homeProject("outer")
        let inner = outer + "/packages/web"
        try FileManager.default.createDirectory(atPath: inner + "/.git", withIntermediateDirectories: true)
        #expect(fixture.projects.add(url(inner)) == nil)
        #expect(fixture.projects.add(url(inner))?.contains("already") == true)
        #expect(fixture.projects.add(url(inner + "/../web"))?.contains("already") == true)
        #expect(fixture.projects.add(url(outer))?.contains("inside it") == true)
        let deeper = inner + "/apps/site"
        try FileManager.default.createDirectory(atPath: deeper + "/.git", withIntermediateDirectories: true)
        #expect(fixture.projects.add(url(deeper))?.contains("inside") == true)
        #expect(fixture.projects.paths.count == 1)
    }

    @Test("a project can be removed")
    func removes() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let one = try fixture.box.homeProject("one")
        let two = try fixture.box.homeProject("two")
        #expect(fixture.projects.add(url(one)) == nil)
        #expect(fixture.projects.add(url(two)) == nil)
        let first = try #require(fixture.projects.paths.first)
        fixture.projects.remove(first)
        #expect(fixture.projects.paths.count == 1)
        #expect(fixture.defaults.stringArray(forKey: InstantProjects.defaultsKey)?.count == 1)
    }
}
