import Foundation
import Testing
@testable import LocalFlow

@Suite("Instant Edits: reading the design profile")
struct InstantDesignProfileTests {
    @Test("design and product docs are found and read, README only as a fallback")
    func finds() throws {
        let box = try InstantSandbox()
        defer { box.cleanUp() }
        let app = try box.homeProject()
        try box.write("# Design\nButtons are pill-shaped.\n", to: app + "/DESIGN.md")
        try box.write("# Product\nFor field crews.\n", to: app + "/PRODUCT.md")
        try box.write("Colors: navy.\n", to: app + "/design-profile-v2.md")
        try box.write("Spacing: 8pt grid.\n", to: app + "/docs/Design-System.md")
        try box.write("# App\nRun npm start.\n", to: app + "/README.md")
        try box.write("ignore me\n", to: app + "/src/DESIGN.md")
        let profile = InstantDesignProfile.find(in: app)
        #expect(profile.files == ["DESIGN.md", "PRODUCT.md", "design-profile-v2.md", "docs/Design-System.md"])
        #expect(profile.text.contains("Buttons are pill-shaped."))
        #expect(profile.text.contains("Spacing: 8pt grid."))
        #expect(profile.text.contains("DESIGN.md"))
        #expect(!profile.text.contains("Run npm start."))
        #expect(!profile.text.contains("ignore me"))
    }

    @Test("style guides count, in any case")
    func styleGuides() throws {
        let box = try InstantSandbox()
        defer { box.cleanUp() }
        let app = try box.homeProject()
        try box.write("Use the brand red.\n", to: app + "/STYLEGUIDE.md")
        try box.write("Tokens live in theme.ts.\n", to: app + "/docs/style-guide.md")
        let profile = InstantDesignProfile.find(in: app)
        #expect(profile.files == ["STYLEGUIDE.md", "docs/style-guide.md"])
    }

    @Test("README is read when there's nothing else")
    func readmeFallback() throws {
        let box = try InstantSandbox()
        defer { box.cleanUp() }
        let app = try box.homeProject()
        try box.write("# App\nUses Tailwind.\n", to: app + "/readme.md")
        let profile = InstantDesignProfile.find(in: app)
        #expect(profile.files == ["readme.md"])
        #expect(profile.text.contains("Uses Tailwind."))
    }

    @Test("a project with no docs has an empty profile")
    func empty() throws {
        let box = try InstantSandbox()
        defer { box.cleanUp() }
        let app = try box.homeProject()
        let profile = InstantDesignProfile.find(in: app)
        #expect(profile == InstantDesignProfile(text: "", files: []))
        #expect(profile.isEmpty)
    }

    @Test("all of it together stays under the size cap")
    func capped() throws {
        let box = try InstantSandbox()
        defer { box.cleanUp() }
        let app = try box.homeProject()
        let line = "Buttons use the primary token and 12 pt corner radius.\n"
        try box.write(String(repeating: line, count: 400), to: app + "/DESIGN.md")
        try box.write(String(repeating: line, count: 400), to: app + "/PRODUCT.md")
        let profile = InstantDesignProfile.find(in: app)
        #expect(profile.text.utf8.count <= InstantDesignProfile.byteLimit + 200)
        #expect(profile.files.first == "DESIGN.md")
        #expect(profile.text.contains("cut short"))
    }

    @Test("a huge doc is read only up to the cap, even when the cut lands inside a character")
    func hugeDoc() throws {
        let box = try InstantSandbox()
        defer { box.cleanUp() }
        let app = try box.homeProject()
        // One line of 3-byte characters after a 2-byte start, so the cap falls inside one.
        try box.write("# " + String(repeating: "設計", count: 300_000), to: app + "/DESIGN.md")
        let profile = InstantDesignProfile.find(in: app)
        #expect(profile.files == ["DESIGN.md"])
        #expect(profile.text.utf8.count <= InstantDesignProfile.byteLimit + 200)
        #expect(profile.text.contains("cut short"))
        #expect(!profile.text.contains("\u{FFFD}"))
    }

    @Test("a doc that links outside the project, or isn't text, is skipped")
    func unsafe() throws {
        let box = try InstantSandbox()
        defer { box.cleanUp() }
        let app = try box.homeProject()
        let secret = try box.write("private key\n", to: box.home + "/secret.md")
        try FileManager.default.createSymbolicLink(atPath: app + "/DESIGN.md", withDestinationPath: secret)
        try box.writeData(Data([0xFF, 0xFE, 0x00, 0x41]), to: app + "/PRODUCT.md")
        try box.write("Real notes.\n", to: app + "/README.md")
        let profile = InstantDesignProfile.find(in: app)
        #expect(!profile.text.contains("private key"))
        #expect(profile.files == ["README.md"])
    }
}
