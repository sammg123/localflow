import Testing
@testable import LocalFlow

@Suite("Agent: naming what a click lands on")
struct AgentClickTargetTests {
    typealias Info = ClickTarget.ElementInfo

    @Test("a button's own title names it")
    func buttonTitle() {
        #expect(ClickTarget.label(for: [Info(role: "AXButton", title: "Send")]) == "Send")
    }

    @Test("text inside a button names it through the text's value")
    func textInButton() {
        let chain = [Info(role: "AXStaticText", value: "Place order"), Info(role: "AXButton")]
        #expect(ClickTarget.label(for: chain) == "Place order")
    }

    @Test("an icon button is named by its description")
    func iconButton() {
        #expect(ClickTarget.label(for: [Info(role: "AXButton", description: "Delete")]) == "Delete")
    }

    @Test("a plain spot names nothing, and a window's title doesn't count")
    func nothing() {
        #expect(ClickTarget.label(for: []) == nil)
        #expect(ClickTarget.label(for: [Info(role: "AXGroup"), Info(role: "AXWindow", title: "Inbox")]) == nil)
    }

    @Test("a text field's typed contents never name it")
    func textFieldValue() {
        let chain = [Info(role: "AXTextField", value: "my password"), Info(role: "AXGroup")]
        #expect(ClickTarget.label(for: chain) == nil)
    }

    @Test("a long label is cut and squeezed to one line")
    func longLabel() {
        let label = ClickTarget.label(for: [Info(role: "AXButton", title: "  Send\n\n" + String(repeating: "x", count: 200))])
        #expect(label?.hasPrefix("Send x") == true)
        #expect((label?.count ?? 0) <= ClickTarget.maxLength)
    }
}
