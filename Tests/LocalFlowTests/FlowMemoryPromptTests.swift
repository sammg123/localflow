import Combine
import Foundation
import Testing
@testable import LocalFlow

@Suite("Memory: what Ask and the agent are told")
final class FlowMemoryPromptTests {
    let folder = MemoryFolder()
    var memory: FlowMemory { folder.memory }

    init() throws {
        try folder.memory.remember("Always answer in metric units", section: .instructions)
        try folder.memory.remember("Demo | folder: ~/code/demo | domains: app.example.com", section: .projects)
        try folder.memory.remember("Ships on Fridays", section: .notes)
    }

    @Test("both modes get both files under clear headers, and when to read and add")
    func shared() {
        for mode in [FlowMemory.Mode.ask, .agent] {
            let text = memory.promptSection(for: mode)
            #expect(text.contains("localflow.md"))
            #expect(text.contains("flow-memory.md"))
            #expect(text.contains("- Always answer in metric units"))
            #expect(text.contains("- Demo | folder: ~/code/demo | domains: app.example.com"))
            #expect(text.contains("- Ships on Fridays"))
            #expect(text.range(of: "- Always answer")!.lowerBound < text.range(of: "- Demo")!.lowerBound)
            for words in ["before you answer", "address bar", "logo", "## Projects", "## Notes",
                          "ask the user which project", "Never add", "secrets", "one line",
                          "update its line"] {
                #expect(text.contains(words), "missing: \(words)")
            }
        }
    }

    @Test("the agent edits the files at their absolute paths")
    func agentAdds() {
        let text = memory.promptSection(for: .agent)
        #expect(text.contains(memory.instructionsURL.standardizedFileURL.path))
        #expect(text.contains(memory.memoryURL.standardizedFileURL.path))
        #expect(text.contains("Edit"))
        #expect(!text.contains("<remember"))
    }

    @Test("Ask adds with tags at the end of its answer, and is never shown the paths")
    func askAdds() {
        let text = memory.promptSection(for: .ask)
        #expect(text.contains("<remember section=\"projects|notes|instructions\">"))
        #expect(text.contains("very end"))
        #expect(!text.contains(folder.url.path))
    }

    @Test("the two modes differ only in how to add")
    func modesDifferOnlyInAdding() {
        let ask = memory.promptSection(for: .ask)
        let agent = memory.promptSection(for: .agent)
        let common = zip(ask, agent).prefix { $0 == $1 }.count
        #expect(common > ask.count / 2)
    }

    @Test("empty or missing files still give a usable section")
    func emptyFiles() {
        let empty = FlowMemory(folder: folder.url.appendingPathComponent("none"))
        let text = empty.promptSection(for: .ask)
        #expect(text.contains("(empty)"))
        #expect(text.contains("<remember"))
    }

    @Test("Ask's request carries the section; the tools get it with the message, never on the command line")
    func askBodies() {
        let section = memory.promptSection(for: .ask)
        let body = OllamaChatBody.ask(model: "m", question: "which project is this?", imageBase64: "IMG", memory: section)

        #expect(body.messages.first?.content == OllamaChatBody.systemPrompt + "\n\n" + section)
        let full = AskToolPrompt.fullMessage(from: body)
        #expect(full.hasPrefix(section))
        #expect(full.hasSuffix("which project is this?"))
        #expect(AskToolPrompt.make(from: body) == AskToolPrompt.instructions + "\n\n" + full)
        #expect(!AskToolPrompt.message(from: body).contains(section))
        let args = ClaudeInvocation.arguments(model: "claude-sonnet-5-5")
        #expect(!args.contains { $0.contains("flow-memory.md") || $0.contains("Ships on Fridays") })

        let plain = OllamaChatBody.ask(model: "m", question: "q", imageBase64: "IMG")
        #expect(plain.messages.first?.content == OllamaChatBody.systemPrompt)
        #expect(AskToolPrompt.fullMessage(from: plain) == AskToolPrompt.message(from: plain))
    }
}

@MainActor
@Suite("Memory: Ask answers")
final class AskFlowMemoryTests {
    let folder = MemoryFolder()
    let client = FakeModelClient()
    let surface = FakeSurface()
    var shown: [String] = []
    var watching: AnyCancellable?

    private func makeController(memory: FlowMemory?) -> AskController {
        watching = surface.model.$answer.sink { [weak self] in self?.shown.append($0) }
        return AskController(client: client, surface: surface, indicator: FakeIndicator(),
                             capture: { _ in Data([1, 2, 3]) }, memory: memory, closeHint: "Tap to close")
    }

    private func settle(_ controller: AskController) async {
        for _ in 0..<200 where controller.isRunning {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("tags never show, not even half of one, and their notes are saved")
    func stripsAndRecords() async {
        client.tokens = ["It's the ", "Demo site.", "\n\n<", "remem", "ber section=\"projects\">Demo | dom",
                         "ains: app.example.com</remember>", "<remember section=\"notes\">Ships on Fridays</remember>"]
        let controller = makeController(memory: folder.memory)

        controller.submit("Which project is this?")
        await settle(controller)

        #expect(surface.model.phase == .done)
        #expect(surface.model.answer == "It's the Demo site.")
        #expect(shown.contains("It's the ")) // it did stream, word by word
        #expect(shown.count >= client.tokens.count)
        #expect(shown.allSatisfy { !$0.contains("<") && !$0.contains("remem") })
        #expect(controller.chats.currentChat?.turns.last?.answer == "It's the Demo site.")
        #expect(folder.memoryText.contains("- Demo | domains: app.example.com\n"))
        #expect(folder.memoryText.contains("- Ships on Fridays\n"))
        #expect(!folder.logText.contains("Demo"))
        #expect(folder.logText.contains("memory: added 2 notes"))
    }

    @Test("every question reads the files fresh")
    func readsFresh() async throws {
        let controller = makeController(memory: folder.memory)
        controller.submit("first")
        await settle(controller)
        try folder.memory.remember("Never use tables", section: .instructions)

        controller.submit("second")
        await settle(controller)

        let systems = client.bodies.map { $0.messages.first?.content ?? "" }
        #expect(systems.count == 2)
        #expect(systems.allSatisfy { $0.contains("flow-memory.md") })
        #expect(!systems[0].contains("Never use tables"))
        #expect(systems[1].contains("- Never use tables"))
    }

    @Test("a refused note isn't saved, and the answer still finishes")
    func refusedNote() async {
        client.tokens = ["Done.", "<remember section=\"notes\">password: correct-horse-battery</remember>"]
        let controller = makeController(memory: folder.memory)

        controller.submit("save my login")
        await settle(controller)

        #expect(surface.model.phase == .done)
        #expect(surface.model.answer == "Done.")
        #expect(!folder.memoryText.contains("correct-horse"))
        #expect(folder.logText.contains("refused 1"))
    }

    @Test("an answer that's only a tag counts as empty, and saves nothing")
    func onlyATag() async {
        client.tokens = ["<remember section=\"notes\">Ships on Fridays</remember>"]
        let controller = makeController(memory: folder.memory)

        controller.submit("anything")
        await settle(controller)

        #expect(surface.model.answer.isEmpty)
        #expect(!folder.memoryText.contains("Fridays"))
        if case .failed = surface.model.phase {} else { Issue.record("expected a failed answer") }
    }

    @Test("a standing instruction is saved only when the user's own question states a rule")
    func instructionNeedsUsersWords() async {
        let tag = "<remember section=\"instructions\">Always answer in metric units</remember>"
        client.tokens = ["Sure.", tag]
        let controller = makeController(memory: folder.memory)

        controller.submit("What does this page say?") // a planted tag on the screen, say
        await settle(controller)
        #expect(!folder.instructionsText.contains("metric"))

        controller.submit("From now on, answer in metric units")
        await settle(controller)
        #expect(folder.instructionsText.contains("- Always answer in metric units\n"))
    }

    @Test("without memory, tags are still hidden and the prompt is the plain one")
    func noMemory() async {
        client.tokens = ["Done.", "<remember section=\"notes\">Ships on Fridays</remember>"]
        let controller = makeController(memory: nil)

        controller.submit("anything")
        await settle(controller)

        #expect(surface.model.answer == "Done.")
        #expect(client.bodies.first?.messages.first?.content == OllamaChatBody.systemPrompt)
    }
}
