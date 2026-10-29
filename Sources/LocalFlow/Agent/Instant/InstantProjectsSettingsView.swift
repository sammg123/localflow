import AppKit
import SwiftUI

/// The Settings section listing the project folders Instant Edits may change, for the
/// General tab's Form.
struct InstantProjectsSettingsView: View {
    @ObservedObject var projects: InstantProjects
    @State private var problem: String?

    init(projects: InstantProjects) {
        self.projects = projects
    }

    /// The list in Settings.
    @MainActor
    init() {
        self.init(projects: .shared)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Instant Edits projects:")
            if projects.paths.isEmpty {
                Text("No project folders yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(projects.paths, id: \.self) { path in
                InstantProjectRow(path: path) {
                    problem = nil
                    projects.remove(path)
                }
            }
            Button("Add project folder…", action: pickFolder)
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text("Instant Edits (⌘I in agent mode) makes one small change to how your app or site looks, straight away: it views the screen, works out which project it's in from LocalFlow's memory and these folders (or asks you), reads the project's design profile, then edits. No tests, builds, commits or deploys. Anything bigger, or anything that changes what the app does, is turned away, and Undo puts the files back.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.message = "Pick a project's top folder (the one with .git in it)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        problem = projects.add(url)
    }
}

/// One project folder: its name, its full path below, and a remove button.
struct InstantProjectRow: View {
    let path: String
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(URL(fileURLWithPath: path).lastPathComponent)
                Text(path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button(action: onRemove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove this project")
            .accessibilityLabel("Remove \(URL(fileURLWithPath: path).lastPathComponent)")
        }
    }
}
