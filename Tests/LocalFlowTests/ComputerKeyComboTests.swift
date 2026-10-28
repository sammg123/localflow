import Carbon.HIToolbox
import CoreGraphics
import Testing
@testable import LocalFlow

@Suite("Computer: key combos")
struct ComputerKeyComboTests {
    @Test("a shortcut names the key and holds its modifiers")
    func shortcut() throws {
        let combo = try #require(KeyCombo.parse("cmd+shift+t"))

        #expect(combo.keyCode == CGKeyCode(kVK_ANSI_T))
        #expect(combo.modifiers == [.command, .shift])
        #expect(combo.flags.contains(.maskCommand))
        #expect(combo.flags.contains(.maskShift))
        #expect(!combo.flags.contains(.maskControl))
    }

    @Test("modifier and key names have aliases and ignore case", arguments: [
        ("command+c", "cmd+c"),
        ("CTRL+A", "control+a"),
        ("alt+left", "option+left"),
        ("opt+right", "option+right"),
        ("Enter", "return"),
        ("esc", "Escape"),
        ("backspace", "delete"),
        ("Page_Down", "pagedown"),
        (" cmd + shift + t ", "cmd+shift+t"),
    ])
    func aliases(alias: String, canonical: String) throws {
        let combo = try #require(KeyCombo.parse(alias))
        #expect(combo == KeyCombo.parse(canonical))
    }

    @Test("named keys map to their key codes", arguments: [
        ("return", kVK_Return), ("escape", kVK_Escape), ("tab", kVK_Tab), ("space", kVK_Space),
        ("delete", kVK_Delete), ("forwarddelete", kVK_ForwardDelete),
        ("up", kVK_UpArrow), ("down", kVK_DownArrow), ("left", kVK_LeftArrow), ("right", kVK_RightArrow),
        ("home", kVK_Home), ("end", kVK_End), ("pageup", kVK_PageUp), ("pagedown", kVK_PageDown),
        ("f1", kVK_F1), ("f5", kVK_F5), ("f12", kVK_F12),
        ("a", kVK_ANSI_A), ("z", kVK_ANSI_Z), ("0", kVK_ANSI_0), ("9", kVK_ANSI_9),
        (",", kVK_ANSI_Comma), ("/", kVK_ANSI_Slash), ("`", kVK_ANSI_Grave), ("-", kVK_ANSI_Minus),
    ])
    func namedKeys(name: String, code: Int) throws {
        let combo = try #require(KeyCombo.parse(name))
        #expect(combo.keyCode == CGKeyCode(code))
        #expect(combo.modifiers.isEmpty)
    }

    @Test("arrow keys carry the function and keypad flags a real keyboard sends")
    func arrowFlags() throws {
        let combo = try #require(KeyCombo.parse("option+left"))

        #expect(combo.flags.contains(.maskAlternate))
        #expect(combo.flags.contains(.maskSecondaryFn))
        #expect(combo.flags.contains(.maskNumericPad))
        #expect(KeyCombo.parse("a")?.flags == [])
    }

    @Test("shifted symbols press shift with their base key", arguments: [
        ("?", kVK_ANSI_Slash, [KeyCombo.Modifier.shift]),
        ("!", kVK_ANSI_1, [.shift]),
        ("cmd++", kVK_ANSI_Equal, [.command, .shift]),
        ("+", kVK_ANSI_Equal, [.shift]),
        ("cmd+=", kVK_ANSI_Equal, [.command]),
    ])
    func shiftedSymbols(text: String, code: Int, modifiers: [KeyCombo.Modifier]) throws {
        let combo = try #require(KeyCombo.parse(text))
        #expect(combo.keyCode == CGKeyCode(code))
        #expect(combo.modifiers == Set(modifiers))
    }

    @Test("an unknown key is named in the error", arguments: [
        ("hyper+x", "hyper"),
        ("cmd+fly", "fly"),
        ("f99", "f99"),
    ])
    func unknownKey(text: String, unknown: String) {
        #expect(KeyCombo.parse(text) == nil)
        #expect(KeyCombo.parseResult(text) == .failure(.unknownKey(unknown)))
        #expect(KeyComboError.unknownKey(unknown).message.contains("\"\(unknown)\""))
    }

    @Test("empty text, modifiers alone, or two keys are rejected", arguments: [
        ("", KeyComboError.empty),
        ("   ", .empty),
        ("cmd+shift", .missingKey),
        ("cmd+", .missingKey),
        ("a+b", .tooManyKeys),
    ])
    func rejected(text: String, error: KeyComboError) {
        #expect(KeyCombo.parseResult(text) == .failure(error))
        #expect(!error.message.isEmpty)
    }

    @Test("modifier names accept the same aliases on their own")
    func modifierNames() {
        #expect(KeyCombo.Modifier.named("Command") == .command)
        #expect(KeyCombo.Modifier.named("ctrl") == .control)
        #expect(KeyCombo.Modifier.named("alt") == .option)
        #expect(KeyCombo.Modifier.named("shift") == .shift)
        #expect(KeyCombo.Modifier.named("hyper") == nil)
    }
}

@Suite("Computer: typing chunks")
struct ComputerTypingChunksTests {
    @Test("short text is one chunk")
    func shortText() {
        #expect(TypingChunks.split("hello") == [.text("hello")])
        #expect(TypingChunks.split("").isEmpty)
    }

    @Test("long text splits into chunks of at most 20 UTF-16 units")
    func longText() {
        let chunks = TypingChunks.split(String(repeating: "a", count: 45))

        #expect(chunks == [
            .text(String(repeating: "a", count: 20)),
            .text(String(repeating: "a", count: 20)),
            .text(String(repeating: "a", count: 5)),
        ])
    }

    @Test("newlines become Return presses", arguments: [
        ("hi\nthere", [TypingChunk.text("hi"), .returnKey, .text("there")]),
        ("a\r\nb", [.text("a"), .returnKey, .text("b")]),
        ("\n\n", [.returnKey, .returnKey]),
    ])
    func newlines(text: String, expected: [TypingChunk]) {
        #expect(TypingChunks.split(text) == expected)
    }

    @Test("emoji are never split in the middle")
    func emoji() {
        let chunks = TypingChunks.split(String(repeating: "😀", count: 11))

        #expect(chunks == [.text(String(repeating: "😀", count: 10)), .text("😀")])
    }
}
