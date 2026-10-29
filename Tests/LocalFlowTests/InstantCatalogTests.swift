import Foundation
import Testing
@testable import LocalFlow

/// The project folders Instant finds on the Mac by itself, so it can tell which project
/// is on screen before anything is in LocalFlow's memory.
@Suite("Instant Edits: the project folders on this Mac")
struct InstantCatalogTests {
    @Test("finds projects in home and its code folders, with their GitHub repo and README title")
    func finds() throws {
        let box = try InstantSandbox()
        defer { box.cleanUp() }
        let northwind = try box.homeProject("northwind")
        try box.write("[core]\n\tbare = false\n[remote \"origin\"]\n\turl = git@github.com:Acme/northwind.git\n",
                      to: northwind + "/.git/config")
        try box.write("# Northwind\n\n![badge](x.svg)\n\nThe storefront for Acme.\n", to: northwind + "/README.md")
        let sundial = box.home + "/Desktop/sundial"
        try box.write("{}\n", to: sundial + "/package.json")
        try box.write("# Sundial\n", to: sundial + "/README.md")
        try FileManager.default.createDirectory(atPath: box.home + "/orbit/.git", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: box.home + "/code/plain", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: box.home + "/.hidden/.git", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: box.home + "/Library/Stuff/.git", withIntermediateDirectories: true)

        let lines = InstantCatalog.lines(home: box.home)

        #expect(lines.count == 3)
        let line = try #require(lines.first { $0.contains("~/code/northwind") })
        #expect(line.contains("repo: Acme/northwind"))
        #expect(line.contains("readme: Northwind: The storefront for Acme."))
        #expect(lines.contains { $0.contains("~/Desktop/sundial") && $0.contains("readme: Sundial") })
        #expect(lines.contains { $0.hasSuffix("~/orbit") })
        #expect(!lines.contains { $0.contains("plain") || $0.contains("hidden") || $0.contains("Library") })
    }

    @Test("a git worktree is listed as its main checkout, once, so copies don't crowd the list")
    func worktrees() throws {
        let box = try InstantSandbox()
        defer { box.cleanUp() }
        let northwind = try box.homeProject("northwind")
        for name in ["northwind-fix", "northwind-try"] {
            try box.write("gitdir: \(northwind)/.git/worktrees/\(name)\n", to: box.home + "/" + name + "/.git")
        }
        try box.write("gitdir: ../northwind/.git/worktrees/rel\n", to: box.home + "/code/rel/.git")
        try box.write("gitdir: /nowhere/.git/worktrees/gone\n", to: box.home + "/gone/.git")

        let folders = InstantCatalog.lines(home: box.home).map { $0.components(separatedBy: " | ")[0] }

        #expect(folders.sorted() == ["~/code/northwind", "~/gone"])
    }

    @Test("reads the repo from an ssh or https remote, origin first, and nothing that isn't GitHub")
    func repo() {
        #expect(InstantCatalog.repo(fromGitConfig: "[remote \"origin\"]\n\turl = https://github.com/Acme/site.git\n")
                == "Acme/site")
        #expect(InstantCatalog.repo(fromGitConfig: "[remote \"origin\"]\n\turl = git@github.com:Acme/app\n") == "Acme/app")
        let both = "[remote \"upstream\"]\n\turl = https://github.com/Other/app.git\n"
            + "[remote \"origin\"]\n\turl = https://github.com/Acme/app.git\n"
        #expect(InstantCatalog.repo(fromGitConfig: both) == "Acme/app")
        #expect(InstantCatalog.repo(fromGitConfig: "[core]\n\tbare = false\n") == nil)
        #expect(InstantCatalog.repo(fromGitConfig: "[remote \"origin\"]\n\turl = https://gitlab.com/a/b.git\n") == nil)
        #expect(InstantCatalog.repo(fromGitConfig: "[remote \"origin\"]\n\turl = https://github.com.evil.com/a/b\n")
                == nil)
        #expect(InstantCatalog.repo(fromGitConfig: "[remote \"origin\"]\n\turl = https://notgithub.com/a/b\n") == nil)
    }

    @Test("reads only real files inside the project: a linked README or git config is skipped")
    func linkedFiles() throws {
        let box = try InstantSandbox()
        defer { box.cleanUp() }
        let secret = try box.write("aws_access_key_id = SECRET\n[remote \"origin\"]\n\turl = git@github.com:Acme/secret\n",
                                   to: box.root.path + "/secret.txt")
        let northwind = try box.homeProject("northwind")
        try FileManager.default.createSymbolicLink(atPath: northwind + "/README.md", withDestinationPath: secret)
        try FileManager.default.createSymbolicLink(atPath: northwind + "/.git/config", withDestinationPath: secret)
        let sundial = try box.homeProject("sundial")
        try box.write("# Sundial\n", to: sundial + "/docs/README.md")
        try FileManager.default.createSymbolicLink(atPath: sundial + "/README.md", withDestinationPath: "docs/README.md")

        let lines = InstantCatalog.lines(home: box.home)

        #expect(lines.sorted() == ["~/code/northwind", "~/code/sundial | readme: Sundial"])
    }

    @Test("leaves alone the home folders that hold no code, such as Downloads and Pictures")
    func skipsMediaFolders() throws {
        let box = try InstantSandbox()
        defer { box.cleanUp() }
        for name in ["Downloads", "Movies", "Music", "Pictures", "Public", "Applications"] {
            try FileManager.default.createDirectory(atPath: box.home + "/" + name + "/.git", withIntermediateDirectories: true)
        }

        #expect(InstantCatalog.lines(home: box.home).isEmpty)
    }

    @Test("a README's own | can't add a column")
    func pipes() throws {
        let box = try InstantSandbox()
        defer { box.cleanUp() }
        let northwind = try box.homeProject("northwind")
        try box.write("# North | wind\n", to: northwind + "/README.md")

        #expect(InstantCatalog.lines(home: box.home) == ["~/code/northwind | readme: North / wind"])
    }

    @Test("newest by git activity first, not by the folder's own date")
    func newestByGit() throws {
        let box = try InstantSandbox()
        defer { box.cleanUp() }
        let older = try box.homeProject("older")
        let busy = try box.homeProject("busy")
        try box.write("index", to: busy + "/.git/index")
        let now = Date()
        let dates = [(older, now.addingTimeInterval(-100)), (busy, now.addingTimeInterval(-1000)),
                     (busy + "/.git/index", now)]
        for (path, date) in dates {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
        }

        #expect(InstantCatalog.lines(home: box.home) == ["~/code/busy", "~/code/older"])
    }

    @Test("keeps the list and each line short")
    func caps() throws {
        let box = try InstantSandbox()
        defer { box.cleanUp() }
        for index in 0..<(InstantCatalog.limit + 5) {
            try box.homeProject("app\(index)")
        }
        let long = try box.homeProject("long")
        try box.write("# " + String(repeating: "Long title ", count: 40) + "\n", to: long + "/README.md")

        let lines = InstantCatalog.lines(home: box.home)

        #expect(lines.count == InstantCatalog.limit)
        #expect(lines.allSatisfy { $0.count <= InstantCatalog.lineLimit })
    }

    @Test("the sweep's text has a heading, and is empty when there are no projects")
    func text() throws {
        let box = try InstantSandbox()
        defer { box.cleanUp() }
        #expect(InstantCatalog.text(home: box.home).isEmpty)
        try box.homeProject("northwind")

        let text = InstantCatalog.text(home: box.home)

        #expect(text.hasPrefix(InstantCatalog.heading + "\n"))
        #expect(text.contains("- ~/code/northwind"))
    }
}
