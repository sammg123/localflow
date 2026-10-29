import AppKit
import SwiftUI
import Testing
@testable import LocalFlow

@Suite("Connectors: the Settings tab draws")
@MainActor
final class ConnectorsSettingsRenderTests {
    private let suiteName = "LocalFlowTests.connectors.render." + UUID().uuidString
    private let defaults: UserDefaults

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suiteName))
    }

    deinit {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    private func makeStore() -> ConnectorStore {
        ConnectorStore(defaults: defaults, secrets: FakeConnectorSecrets(), gitHubCLIToken: { nil },
                       isExecutable: { _ in true }, log: { _ in })
    }

    private func render(_ view: some View) throws -> NSImage {
        let renderer = ImageRenderer(content: view.frame(width: 480))
        return try #require(renderer.nsImage)
    }

    @Test("an empty list and every kind of connector draw at the window's width")
    func list() throws {
        let store = makeStore()
        #expect(try render(ConnectorsSettingsView(store: store)).size.width == 480)
        try store.add(GitHubConnector.draft(token: nil))
        try store.add(ConnectorDraft(name: "Notes", transport: .remote(url: "https://n.example.com/mcp"),
                                     secret: .token("tok_test")))
        try store.add(ConnectorDraft(name: "Docs", transport: .remote(url: "https://d.example.com"), secret: .noSecret))
        let files = try store.add(ConnectorDraft(name: "Files", transport: .local(command: "npx", arguments: ["-y", "x"]),
                                                 secret: .environment(name: "API_KEY", value: "sk_test")))
        store.setEnabled(false, for: files.id)
        #expect(try render(ConnectorsSettingsView(store: store)).size.width == 480)
    }

    @Test("each add form draws", arguments: [
        ConnectorFields(kind: .gitHub), ConnectorFields(kind: .gitHub, usesGitHubCLI: false),
        ConnectorFields(kind: .url), ConnectorFields(kind: .command),
    ])
    func addForms(fields: ConnectorFields) throws {
        let form = Form { ConnectorAddForm(store: makeStore(), fields: fields) }
        #expect(try render(form).size.width == 480)
    }
}
