import AppKit
import Testing
@testable import LocalFlow

@MainActor
@Suite("Main menu")
struct MainMenuTests {
    @Test("the Edit and Window shortcuts work in LocalFlow's windows")
    func shortcuts() throws {
        let menu = MainMenu.make()
        let items = menu.items.compactMap(\.submenu).flatMap(\.items)
        func item(_ key: String, _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem? {
            items.first { $0.keyEquivalent == key && $0.keyEquivalentModifierMask == modifiers }
        }

        #expect(item("x")?.action == #selector(NSText.cut(_:)))
        #expect(item("c")?.action == #selector(NSText.copy(_:)))
        #expect(item("v")?.action == #selector(NSText.paste(_:)))
        #expect(item("a")?.action == #selector(NSText.selectAll(_:)))
        #expect(item("z")?.action == Selector(("undo:")))
        #expect(item("z", [.command, .shift])?.action == Selector(("redo:")))
        #expect(item("w")?.action == #selector(NSWindow.performClose(_:)))
        // No Quit here: Cmd+Q in a LocalFlow window must not quit the menu-bar app.
        #expect(item("q") == nil)
    }
}
