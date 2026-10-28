import AppKit

// LocalFlow — a private, fully local Wispr Flow-style dictation app.
// Hold a modifier key, speak, release: text lands in the focused app.
// Everything (ASR, AI cleanup) runs on this Mac. No network calls.

MainActor.assumeIsolated {
    // Agent mode starts this binary as an MCP server; that never starts the app.
    if ComputerMCPCommand.isRequested(in: CommandLine.arguments) {
        ComputerMCPCommand.run(arguments: CommandLine.arguments)
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory) // menu-bar only; also LSUIElement in Info.plist
    app.run()
    withExtendedLifetime(delegate) {}
}
