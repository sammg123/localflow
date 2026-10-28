import Carbon.HIToolbox
import CoreGraphics
import AppKit
import Testing
@testable import LocalFlow

@Suite("Computer: tool argument checks")
struct ComputerToolArgumentTests {
    private func parse(_ tool: String, _ arguments: JSONValue = [:]) throws -> ComputerCommand {
        try ComputerCommand.parse(tool: tool, arguments: arguments.objectValue ?? [:])
    }

    private func failure(_ tool: String, _ arguments: JSONValue) -> String? {
        do {
            _ = try parse(tool, arguments)
            return nil
        } catch let error as ToolInputError {
            return error.message
        } catch {
            return "unexpected \(error)"
        }
    }

    @Test("a full click is read with every option")
    func fullClick() throws {
        let command = try parse("click", ["x": 10, "y": 20, "button": "middle", "clicks": 3,
                                          "modifiers": ["cmd", "Shift", "alt"], "irreversible": true])

        #expect(command == .click(Pixel(x: 10, y: 20), button: .middle, clicks: 3,
                                  modifiers: [.command, .shift, .option]))
    }

    @Test("a bare click is a single left click, and whole-number decimals count as whole")
    func clickDefaults() throws {
        #expect(try parse("click", ["x": 10, "y": 20]) == .click(Pixel(x: 10, y: 20), button: .left, clicks: 1, modifiers: []))
        #expect(try parse("click", ["x": 10.0, "y": 20]) == .click(Pixel(x: 10, y: 20), button: .left, clicks: 1, modifiers: []))
    }

    private static let badClicks: [(arguments: JSONValue, named: String)] = [
        (["y": 5], "x"),
        (["x": "10", "y": 5], "x"),
        (["x": 10.5, "y": 5], "x"),
        (["x": -1, "y": 5], "x"),
        (["x": 1, "y": JSONValue.null], "y"),
        (["x": 1, "y": 1, "button": "side"], "button"),
        (["x": 1, "y": 1, "clicks": 4], "clicks"),
        (["x": 1, "y": 1, "clicks": 0], "clicks"),
        (["x": 1, "y": 1, "modifiers": "cmd"], "modifiers"),
        (["x": 1, "y": 1, "modifiers": ["hyper"]], "hyper"),
        (["x": 1, "y": 1, "irreversible": "yes"], "irreversible"),
    ]

    @Test("bad click arguments are named in the error", arguments: badClicks)
    func badClick(arguments: JSONValue, named: String) throws {
        let message = try #require(failure("click", arguments))
        #expect(message.contains(named), "\(message)")
    }

    @Test("move and drag need every coordinate")
    func moveAndDrag() throws {
        #expect(try parse("move", ["x": 3, "y": 4]) == .move(Pixel(x: 3, y: 4)))
        #expect(try parse("drag", ["from_x": 1, "from_y": 2, "to_x": 3, "to_y": 4])
            == .drag(from: Pixel(x: 1, y: 2), to: Pixel(x: 3, y: 4)))
        #expect(failure("drag", ["from_x": 1, "from_y": 2, "to_x": 3])?.contains("to_y") == true)
        #expect(failure("move", ["x": 3])?.contains("y") == true)
    }

    @Test("type needs non-empty text of a sensible length")
    func typeText() throws {
        #expect(try parse("type", ["text": "hello\nthere", "irreversible": false]) == .type("hello\nthere"))
        #expect(failure("type", [:])?.contains("text") == true)
        #expect(failure("type", ["text": ""])?.contains("text") == true)
        #expect(failure("type", ["text": 42])?.contains("text") == true)
        let tooLong = String(repeating: "a", count: ComputerCommand.maxTypedCharacters + 1)
        #expect(failure("type", ["text": .string(tooLong)])?.contains("long") == true)
    }

    @Test("key reads the combo and names an unknown key")
    func key() throws {
        let combo = try #require(KeyCombo.parse("cmd+shift+t"))
        #expect(try parse("key", ["keys": "cmd+shift+t"]) == .key(combo, keys: "cmd+shift+t"))
        #expect(failure("key", ["keys": "cmd+warp"])?.contains("warp") == true)
        #expect(failure("key", [:])?.contains("keys") == true)
    }

    @Test("scroll defaults to 3 notches and limits the amount and direction")
    func scroll() throws {
        #expect(try parse("scroll", ["x": 1, "y": 2, "direction": "up"])
            == .scroll(Pixel(x: 1, y: 2), direction: .up, amount: 3))
        #expect(try parse("scroll", ["x": 1, "y": 2, "direction": "left", "amount": 20])
            == .scroll(Pixel(x: 1, y: 2), direction: .left, amount: 20))
        #expect(failure("scroll", ["x": 1, "y": 2, "direction": "up", "amount": 0])?.contains("amount") == true)
        #expect(failure("scroll", ["x": 1, "y": 2, "direction": "up", "amount": 21])?.contains("amount") == true)
        #expect(failure("scroll", ["x": 1, "y": 2, "direction": "sideways"])?.contains("direction") == true)
        #expect(failure("scroll", ["x": 1, "y": 2])?.contains("direction") == true)
    }

    @Test("open_app takes an app name or bundle id but never a path")
    func openApp() throws {
        #expect(try parse("open_app", ["name": "Safari"]) == .openApp("Safari"))
        #expect(try parse("open_app", ["name": " com.apple.Safari "]) == .openApp("com.apple.Safari"))
        #expect(failure("open_app", ["name": ""]) != nil)
        #expect(failure("open_app", ["name": "../../bin/sh"]) != nil)
        #expect(failure("open_app", ["name": "/Applications/Safari.app"]) != nil)
        #expect(failure("open_app", [:])?.contains("name") == true)
    }

    @Test("wait takes up to 10 seconds")
    func wait() throws {
        #expect(try parse("wait", ["seconds": 2]) == .wait(seconds: 2))
        #expect(try parse("wait", ["seconds": 0.5]) == .wait(seconds: 0.5))
        #expect(failure("wait", ["seconds": 10.5])?.contains("seconds") == true)
        #expect(failure("wait", ["seconds": -1])?.contains("seconds") == true)
        #expect(failure("wait", ["seconds": "2"])?.contains("seconds") == true)
    }

    @Test("screenshot and list_apps take no arguments; an unknown tool is named")
    func noArguments() throws {
        #expect(try parse("screenshot") == .screenshot)
        #expect(try parse("list_apps") == .listApps)
        #expect(failure("teleport", [:])?.contains("teleport") == true)
    }
}

@Suite("Computer: apps")
struct ComputerAppsTests {
    private func makeFolder(apps: [String]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("localflow-apps-\(UUID().uuidString)")
        for app in apps {
            try FileManager.default.createDirectory(
                at: folder.appendingPathComponent(app + ".app"), withIntermediateDirectories: true)
        }
        try Data().write(to: folder.appendingPathComponent("Notes.txt"))
        return folder
    }

    @Test("an app is found by name in any case, with or without .app")
    func findsByName() throws {
        let folder = try makeFolder(apps: ["Foo Bar", "Other"])
        defer { try? FileManager.default.removeItem(at: folder) }

        let found = try #require(AppLocator.find("foo bar", in: [folder]))
        #expect(found.lastPathComponent == "Foo Bar.app")
        #expect(AppLocator.find("Foo Bar.app", in: [folder])?.lastPathComponent == "Foo Bar.app")
        #expect(AppLocator.find("Notes", in: [folder]) == nil)
        #expect(AppLocator.find("Nope", in: [folder]) == nil)
    }

    @Test("a near miss suggests apps whose names contain it")
    func suggestions() throws {
        let folder = try makeFolder(apps: ["Google Chrome", "Chrome Remote Desktop", "Safari"])
        defer { try? FileManager.default.removeItem(at: folder) }

        #expect(AppLocator.suggestions(for: "chrome", in: [folder]) == ["Chrome Remote Desktop", "Google Chrome"])
        #expect(AppLocator.suggestions(for: "zzz", in: [folder]).isEmpty)
    }

    @Test("bundle ids are told apart from app names")
    func bundleIDs() {
        #expect(AppLocator.looksLikeBundleID("com.apple.Safari"))
        #expect(!AppLocator.looksLikeBundleID("Safari"))
        #expect(!AppLocator.looksLikeBundleID("Visual Studio Code"))
        #expect(!AppLocator.looksLikeBundleID("Safari.app"))
    }

    @Test("the app list is sorted and marks the frontmost app")
    func appList() {
        let text = AppList.describe([
            RunningApp(name: "Safari", bundleID: "com.apple.Safari", isFrontmost: false),
            RunningApp(name: "Finder", bundleID: "com.apple.finder", isFrontmost: true),
            RunningApp(name: "Tool", bundleID: nil, isFrontmost: false),
        ])

        #expect(text == """
        Frontmost: Finder (com.apple.finder)
        Running apps:
        - Finder (com.apple.finder)
        - Safari (com.apple.Safari)
        - Tool
        """)
        #expect(AppList.describe([]).contains("No apps"))
    }
}

@Suite("Computer: launch arguments")
struct ComputerLaunchTests {
    @Test("the MCP flag is spotted anywhere in the arguments")
    func flag() {
        #expect(ComputerMCPCommand.isRequested(in: ["LocalFlow", "--computer-mcp", "--display", "1"]))
        #expect(!ComputerMCPCommand.isRequested(in: ["LocalFlow"]))
    }

    @Test("--display reads a display id, and no flag means the mouse's display")
    func display() throws {
        #expect(try ComputerMCPCommand.requestedDisplay(in: ["LocalFlow", "--computer-mcp", "--display", "69733378"]) == 69_733_378)
        #expect(try ComputerMCPCommand.requestedDisplay(in: ["LocalFlow", "--computer-mcp"]) == nil)
    }

    @Test("a missing or bad display id is refused", arguments: [
        ["LocalFlow", "--computer-mcp", "--display"],
        ["LocalFlow", "--computer-mcp", "--display", "abc"],
        ["LocalFlow", "--computer-mcp", "--display", "-1"],
    ])
    func badDisplay(arguments: [String]) {
        #expect(throws: ToolInputError.self) {
            try ComputerMCPCommand.requestedDisplay(in: arguments)
        }
    }

    @Test("a real screenshot is a JPEG of the mapped size",
          .enabled(if: ProcessInfo.processInfo.environment["LOCALFLOW_E2E"] == "1"))
    @MainActor
    func liveScreenshot() async throws {
        let displayID = CGMainDisplayID()
        let mapping = try #require(ScreenMapping(displayID: displayID))

        let jpeg = try await LiveComputerBackend(displayID: displayID).screenshot(size: mapping.imageSize)

        #expect(jpeg.prefix(2) == Data([0xFF, 0xD8]))
        let image = try #require(NSBitmapImageRep(data: jpeg))
        #expect(image.pixelsWide == mapping.imageWidth)
        #expect(image.pixelsHigh == mapping.imageHeight)
    }
}
