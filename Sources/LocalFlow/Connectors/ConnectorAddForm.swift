import SwiftUI

/// What's typed in the Connectors tab's add form.
struct ConnectorFields: Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case gitHub, url, command

        var id: String { rawValue }

        var label: String {
            switch self {
            case .gitHub: return "GitHub"
            case .url: return "By URL"
            case .command: return "A command"
            }
        }

        var addTitle: String {
            switch self {
            case .gitHub: return "Add GitHub"
            case .url: return "Add by URL"
            case .command: return "Add a command"
            }
        }
    }

    var kind = Kind.gitHub
    var usesGitHubCLI = true
    var name = ""
    var url = ""
    var command = ""
    var arguments = ""
    var secret = ""
    var variable = ""

    /// A blank token or secret means none; the store checks the rest.
    func draft() throws -> ConnectorDraft {
        switch kind {
        case .gitHub:
            return GitHubConnector.draft(token: usesGitHubCLI ? nil : secret)
        case .url:
            return ConnectorDraft(name: name, transport: .remote(url: url),
                                  secret: isBlank(secret) ? .noSecret : .token(secret))
        case .command:
            guard let words = ConnectorRules.arguments(from: arguments) else { throw ConnectorProblem.badArguments }
            let given = !isBlank(secret) || !isBlank(variable)
            return ConnectorDraft(name: name, transport: .local(command: command, arguments: words),
                                  secret: given ? .environment(name: variable, value: secret) : .noSecret)
        }
    }

    private func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Adding a connector: GitHub (with the GitHub CLI's sign-in or a token), a server by
/// URL, or a command that runs on this Mac. Problems show in orange under the fields.
struct ConnectorAddForm: View {
    @ObservedObject var store: ConnectorStore
    @State private var fields: ConnectorFields
    @State private var problem: String?
    @State private var hasGitHubCLI = true

    init(store: ConnectorStore, fields: ConnectorFields = ConnectorFields()) {
        self.store = store
        _fields = State(initialValue: fields)
    }

    var body: some View {
        Picker("Add:", selection: $fields.kind) {
            ForEach(ConnectorFields.Kind.allCases) { kind in
                Text(kind.label).tag(kind)
            }
        }
        .pickerStyle(.segmented)
        .onChange(of: fields.kind) { _, _ in
            fields.secret = ""
            problem = nil
        }
        .task { hasGitHubCLI = GitHubCLI.locate() != nil }
        switch fields.kind {
        case .gitHub: gitHubFields
        case .url: urlFields
        case .command: commandFields
        }
        if let problem {
            ConnectorCaption(text: problem, color: .orange)
        }
        HStack {
            Spacer()
            Button(fields.kind.addTitle, action: add)
        }
    }

    @ViewBuilder private var gitHubFields: some View {
        Picker("Sign in with:", selection: $fields.usesGitHubCLI) {
            Text("My GitHub CLI sign-in").tag(true)
            Text("A personal access token").tag(false)
        }
        .pickerStyle(.radioGroup)
        .onChange(of: fields.usesGitHubCLI) { _, _ in fields.secret = "" }
        if fields.usesGitHubCLI {
            ConnectorCaption(text: "Uses the account you signed in to with “gh auth login”. LocalFlow asks gh for it each time the agent starts and doesn't keep it.")
            if !hasGitHubCLI {
                ConnectorCaption(text: "The GitHub CLI isn't installed. Install it with “brew install gh”, or use a token.",
                                 color: .orange)
            }
        } else {
            SecureField("Token:", text: $fields.secret, prompt: Text("github_pat_…"))
            ConnectorCaption(text: "Make a fine-grained token at github.com/settings/personal-access-tokens with access to the repositories the agent may change.")
        }
    }

    @ViewBuilder private var urlFields: some View {
        TextField("Name:", text: $fields.name, prompt: Text("Notes"))
        TextField("URL:", text: $fields.url, prompt: Text("https://mcp.example.com/mcp"))
        SecureField("Token:", text: $fields.secret, prompt: Text("Optional"))
        ConnectorCaption(text: "A token is sent as “Authorization: Bearer …”. Leave it empty if the server doesn't need one.")
    }

    @ViewBuilder private var commandFields: some View {
        TextField("Name:", text: $fields.name, prompt: Text("Files"))
        TextField("Command:", text: $fields.command, prompt: Text("npx"))
        TextField("Arguments:", text: $fields.arguments, prompt: Text("-y @scope/server"))
        SecureField("Secret:", text: $fields.secret, prompt: Text("Optional"))
        TextField("In variable:", text: $fields.variable, prompt: Text("API_KEY"))
        ConnectorCaption(text: "Runs on this Mac each time the agent starts. A secret reaches the program as that environment variable.")
    }

    /// Adds it, then clears the form. The secret never stays in the form.
    private func add() {
        do {
            try store.add(fields.draft())
            fields = ConnectorFields(kind: fields.kind, usesGitHubCLI: fields.usesGitHubCLI)
            problem = nil
        } catch {
            fields.secret = ""
            problem = error.localizedDescription
        }
    }
}

/// A caption under Settings fields, wrapping to the field column's width rather than
/// widening the form.
struct ConnectorCaption: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
