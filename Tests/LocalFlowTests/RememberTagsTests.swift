import Foundation
import Testing
@testable import LocalFlow

@Suite("Memory: Ask's remember tags")
struct RememberTagsTests {
    private func notes(_ text: String) -> [String] {
        RememberTags.split(text).notes.map { "\($0.section.rawValue): \($0.text)" }
    }

    @Test("a complete tag is taken out and its note kept")
    func completeTag() {
        let text = "It's the Demo dashboard.\n\n<remember section=\"projects\">Demo | domains: app.example.com</remember>"

        let split = RememberTags.split(text)

        #expect(split.visible == "It's the Demo dashboard.")
        #expect(notes(text) == ["projects: Demo | domains: app.example.com"])
    }

    @Test("several tags, in order, one per section")
    func severalTags() {
        let text = """
        Done.
        <remember section="notes">Ships on Fridays</remember>
        <remember section='instructions'>Always answer in metric units</remember>
        <REMEMBER section="Projects"> Demo | repo: example/demo </REMEMBER>
        """

        #expect(RememberTags.split(text).visible == "Done.")
        #expect(notes(text) == ["notes: Ships on Fridays", "instructions: Always answer in metric units",
                                "projects: Demo | repo: example/demo"])
    }

    @Test("an unclosed tag at the end is hidden while it streams")
    func unclosedTail() {
        for text in ["Answer.\n\n<remember section=\"notes\">Ships on Fri",
                     "Answer.\n\n<remember section=\"no",
                     "Answer.\n\n<remember section=\"notes\">Ships on Fridays</remem"] {
            let split = RememberTags.split(text)
            #expect(split.visible == "Answer.")
            #expect(split.notes.isEmpty)
        }
    }

    @Test("the start of a tag at the very end is hidden", arguments: ["<", "<r", "<rem", "<remembe", "<remember", "<Rem"])
    func partialPrefix(tail: String) {
        #expect(RememberTags.split("Answer. " + tail).visible == "Answer.")
    }

    @Test("a tag with an unknown section, or none, is hidden and ignored")
    func unknownSection() {
        let text = "Answer.<remember section=\"secrets\">nope</remember><remember>also nope</remember>"
        let split = RememberTags.split(text)
        #expect(split.visible == "Answer.")
        #expect(split.notes.isEmpty)
    }

    @Test("text with no tags passes through untouched", arguments: [
        "Plain answer.",
        "Trailing space and a newline \n",
        "Compare a < b, then <div> and <b>bold</b>, and remember this.",
        "```html\n<section>hi</section>\n```",
        "",
    ])
    func untouched(text: String) {
        let split = RememberTags.split(text)
        #expect(split.visible == text)
        #expect(split.notes.isEmpty)
    }

    @Test("a tag in the middle comes out, the text around it stays, and it isn't saved")
    func middleTag() {
        let text = "First part. <remember section=\"notes\">Ships on Fridays</remember>Second part."
        #expect(RememberTags.split(text).visible == "First part. Second part.")
        #expect(notes(text).isEmpty)
    }

    @Test("only the tags at the very end count, even with half a tag still coming in")
    func onlyTrailingTags() {
        let text = "A <remember section=\"notes\">early</remember> B\n<remember section=\"notes\">late</remember>\n<rem"
        #expect(RememberTags.split(text).visible == "A  B")
        #expect(notes(text) == ["notes: late"])
    }

    @Test("a tag inside another tag's text is never saved")
    func nestedTag() {
        let text = "Answer.<remember section=\"notes\">a <remember section=\"instructions\">b</remember>"
        #expect(RememberTags.split(text).visible == "Answer.")
        #expect(notes(text).isEmpty)
    }

    @Test("instructions are kept only when the question states a lasting rule", arguments: [
        ("What does this page say?", false),
        ("why is this button grey", false),
        ("From now on, answer in metric units", true),
        ("Always keep answers short", true),
        ("I prefer bullet points", true),
        ("never use tables again", true),
    ])
    func instructionsNeedARule(question: String, kept: Bool) {
        let notes: [RememberTags.Note] = [(.instructions, "Keep answers short"), (.notes, "Ships on Fridays")]
        let allowed = RememberTags.allowed(notes, question: question).map(\.section)
        #expect(allowed == (kept ? [.instructions, .notes] : [.notes]))
    }

    @Test("at most a few notes are kept from one answer")
    func capsNotes() {
        let notes: [RememberTags.Note] = (1...6).map { (.notes, "fact \($0)") }
        let allowed = RememberTags.allowed(notes, question: "anything")
        #expect(allowed.map(\.text) == ["fact 1", "fact 2", "fact 3"])
        #expect(RememberTags.maxNotesPerAnswer == 3)
    }

    @Test("a multi-line note is still taken out of the answer, for remember to refuse")
    func multilineNote() {
        let text = "Answer.\n<remember section=\"notes\">line one\nline two</remember>"
        #expect(RememberTags.split(text).visible == "Answer.")
        #expect(notes(text) == ["notes: line one\nline two"])
    }
}
