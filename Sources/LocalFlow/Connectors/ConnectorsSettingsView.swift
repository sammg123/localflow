import SwiftUI

/// The Connectors tab in Settings: the MCP servers the agent gets each time it starts,
/// each with an on/off switch, and a form to add GitHub, a server by URL, or a command.
struct ConnectorsSettingsView: View {
    @ObservedObject var store: ConnectorStore

    /// Nil means the app's own store.
    @MainActor init(store: ConnectorStore? = nil) {
        self.store = store ?? .shared
    }

    var body: some View {
        Form {
            ConnectorCaption(text: "Connectors give the agent more tools, like Claude's connectors: GitHub, your own servers. They're used the next time the agent starts. Tokens stay in your Mac's keychain.")
            if store.connectors.isEmpty {
                Text("No connectors yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(store.connectors) { connector in
                ConnectorRow(connector: connector, store: store)
            }

            Divider()

            ConnectorAddForm(store: store)
        }
        .padding(.vertical, 8)
    }
}

/// One connector: on or off, its name and where it is, and a remove button that asks first.
private struct ConnectorRow: View {
    let connector: Connector
    let store: ConnectorStore
    @State private var confirmingRemove = false

    var body: some View {
        HStack(spacing: 10) {
            Toggle("Use \(connector.name)", isOn: enabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                Text(connector.name)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button(role: .destructive) {
                confirmingRemove = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove \(connector.name)")
            .accessibilityLabel("Remove \(connector.name)")
        }
        .confirmationDialog("Remove \(connector.name)?", isPresented: $confirmingRemove) {
            Button("Remove", role: .destructive) { store.remove(connector.id) }
        } message: {
            Text(connector.auth.isStored ? "Its token is deleted from the keychain too." : "The agent won't get its tools anymore.")
        }
    }

    private var enabled: Binding<Bool> {
        Binding(get: { connector.isEnabled }, set: { store.setEnabled($0, for: connector.id) })
    }

    /// Where it is, and how it signs in.
    private var detail: String {
        switch connector.auth {
        case .noSecret: return connector.detail
        case .bearerToken: return connector.detail + " · token in keychain"
        case .environment(let name): return connector.detail + " · secret in $" + name
        case .gitHubCLI: return connector.detail + " · GitHub CLI sign-in"
        }
    }
}
