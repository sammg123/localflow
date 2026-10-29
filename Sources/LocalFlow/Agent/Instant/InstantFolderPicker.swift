import AppKit

/// Choose Folder on the project question: a folder picker over the agent's window,
/// starting in home. Nil when the user cancels.
@MainActor
enum InstantFolderPicker {
    static func choose() async -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the project's top folder (the one with .git or package.json in it)."
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        // The agent's window floats at screen-saver level: the picker goes above it.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        NSApp.activate(ignoringOtherApps: true)
        let response = await withCheckedContinuation { continuation in
            panel.begin { continuation.resume(returning: $0) }
        }
        return response == .OK ? panel.url?.path : nil
    }
}
