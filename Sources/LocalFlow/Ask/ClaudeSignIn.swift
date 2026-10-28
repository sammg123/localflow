import AppKit
import SwiftUI

/// Which account LocalFlow's own Claude sign-in is on.
enum ClaudeAccount: Equatable {
    case signedIn(email: String?, plan: String?)
    case signedOut

    /// From `claude auth status`. Nil when it isn't the JSON that command prints.
    static func parse(status: Data) -> ClaudeAccount? {
        guard let object = try? JSONSerialization.jsonObject(with: status) as? [String: Any],
              let loggedIn = object["loggedIn"] as? Bool else { return nil }
        guard loggedIn else { return .signedOut }
        return .signedIn(email: object["email"] as? String, plan: object["subscriptionType"] as? String)
    }

    var summary: String {
        switch self {
        case .signedOut:
            return "Not signed in"
        case .signedIn(let email, let plan):
            let who = email.map { "Signed in as \($0)" } ?? "Signed in"
            return plan.map { "\(who) (\($0.capitalized) plan)" } ?? who
        }
    }
}

/// Signing LocalFlow's Claude in, in a Terminal window where Claude Code's own sign-in
/// runs, and reading back which account it's on.
enum ClaudeSignIn {
    static let statusTimeout: Duration = .seconds(15)
    /// Shell settings that could point the sign-in at another account or provider.
    static let redirectingVariables = [
        "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_OAUTH_TOKEN",
        "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
    ]

    /// A script that runs Claude Code's sign-in against LocalFlow's folder only.
    static func script(executable: String, configDirectory: String) -> String {
        """
        #!/bin/sh
        unset \(redirectingVariables.joined(separator: " "))
        export CLAUDE_CONFIG_DIR=\(quoted(configDirectory))
        echo "Signing LocalFlow's Ask in to Claude. Pick the account Ask should use."
        echo
        \(quoted(executable)) auth login --claudeai
        echo
        echo "Done. You can close this window."

        """
    }

    /// Writes the script next to LocalFlow's Claude folder and opens it in Terminal.
    static func open(executable: String, configDirectory: String) throws {
        let files = FileManager.default
        try files.createDirectory(atPath: configDirectory, withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: configDirectory)
        let url = URL(fileURLWithPath: configDirectory).deletingLastPathComponent()
            .appendingPathComponent("Sign in to Claude.command")
        try? files.removeItem(at: url)
        let contents = Data(script(executable: executable, configDirectory: configDirectory).utf8)
        guard files.createFile(atPath: url.path, contents: contents, attributes: [.posixPermissions: 0o700]) else {
            throw AskError.claude("couldn't write the sign-in script")
        }
        guard NSWorkspace.shared.open(url) else {
            throw AskError.claude("couldn't open Terminal for the sign-in")
        }
    }

    /// Asks Claude Code which account LocalFlow's folder is signed in to. Nil when it
    /// can't tell.
    static func status(executable: String, configDirectory: String) async -> ClaudeAccount? {
        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["auth", "status"]
        process.environment = ClaudeInvocation.environment(tmp: FileManager.default.temporaryDirectory.path,
                                                           configDirectory: configDirectory,
                                                           toolFolder: ClaudeInvocation.folder(of: executable))
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let reader = ToolOutputLines(reading: output.fileHandleForReading)
        defer { reader.finish() }
        var lines: [String] = []
        _ = try? await AskTool.run(process, timeout: statusTimeout, launchFailure: { .claude($0) },
                                   onExit: { reader.toolExited() }) {
            for await line in reader.lines { lines.append(line) }
        }
        if Task.isCancelled { return nil }
        return ClaudeAccount.parse(status: Data(lines.joined(separator: "\n").utf8))
    }

    private static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// The Settings row for Ask's Claude sign-in: which account it's on, and a button that
/// signs in (or switches account) in Terminal.
struct ClaudeAccountRow: View {
    private enum Lookup: Equatable {
        case checking, missing, unknown
        case found(ClaudeAccount)
    }

    /// How often, and for how long, the row checks back after the sign-in opens.
    private static let pollInterval: Duration = .seconds(3)
    private static let pollCount = 60

    @State private var lookup = Lookup.checking
    @State private var watch: Task<Void, Never>?
    @State private var problem: String?

    private let executable = ClaudeInvocation.locate()
    private let configDirectory = ClaudeInvocation.configDirectory()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(isSignedIn ? "Switch account…" : "Sign in to Claude…", action: signIn)
                    .disabled(executable == nil)
            }
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .task { await refresh() }
        .onDisappear { watch?.cancel() }
    }

    private var summary: String {
        switch lookup {
        case .checking: return "Checking the Claude sign-in…"
        case .missing: return "Claude Code isn't on this Mac"
        case .unknown: return "Couldn't read the Claude sign-in"
        case .found(let account): return account.summary
        }
    }

    private var isSignedIn: Bool {
        if case .found(.signedIn) = lookup { return true }
        return false
    }

    /// While polling, a check that can't tell keeps what the row already shows.
    private func refresh(keepingOnFailure: Bool = false) async {
        guard let executable else {
            lookup = .missing
            return
        }
        let account = await ClaudeSignIn.status(executable: executable, configDirectory: configDirectory)
        if Task.isCancelled { return }
        if let account {
            lookup = .found(account)
        } else if !keepingOnFailure {
            lookup = .unknown
        }
    }

    /// Opens the sign-in, then checks back until the account changes.
    private func signIn() {
        guard let executable else { return }
        do {
            try ClaudeSignIn.open(executable: executable, configDirectory: configDirectory)
            problem = nil
        } catch {
            problem = "Couldn't open the sign-in: \(error.localizedDescription)"
            return
        }
        let before = lookup
        watch?.cancel()
        watch = Task {
            for _ in 0..<Self.pollCount {
                try? await Task.sleep(for: Self.pollInterval)
                if Task.isCancelled { return }
                await refresh(keepingOnFailure: true)
                if isSignedIn, lookup != before { return }
            }
        }
    }
}
