import Foundation

/// Apps where a key press or opening the app does more than it looks: mail and chat
/// apps, where Return sends, and apps that run commands or change system settings.
enum AgentApps {
    /// Bundle ids, lowercased.
    static let messengers: Set<String> = [
        "com.apple.mobilesms", "com.apple.mail", "com.tinyspeck.slackmacgap", "com.hnc.discord", "net.whatsapp.whatsapp",
        "desktop.whatsapp", "ru.keepcoder.telegram", "org.telegram.desktop", "com.microsoft.teams", "com.microsoft.teams2",
        "com.microsoft.outlook", "com.facebook.archon", "org.whispersystems.signal-desktop", "com.readdle.smartemail-mac",
        "com.superhuman.electron", "us.zoom.xos", "com.google.chat",
    ]
    /// Names and bundle ids, lowercased, without ".app".
    static let runners: Set<String> = [
        "terminal", "com.apple.terminal", "iterm", "iterm2", "com.googlecode.iterm2", "warp", "dev.warp.warp-stable",
        "ghostty", "com.mitchellh.ghostty", "alacritty", "org.alacritty", "kitty", "net.kovidgoyal.kitty", "wezterm",
        "com.github.wez.wezterm", "hyper", "co.zeit.hyper", "script editor", "com.apple.scripteditor2", "automator",
        "com.apple.automator", "automator application stub", "shortcuts", "com.apple.shortcuts", "system settings",
        "system preferences", "com.apple.systempreferences", "keychain access", "com.apple.keychainaccess", "installer",
        "com.apple.installer", "disk utility", "com.apple.diskutility",
    ]
    /// Files `open` runs or installs rather than shows.
    static let programExtensions: Set<String> = [
        "app", "command", "tool", "terminal", "sh", "zsh", "bash", "scpt", "scptd", "applescript", "workflow", "action",
        "shortcut", "pkg", "mpkg", "mobileconfig", "prefpane", "kext", "jar",
    ]

    static func isMessenger(_ bundleID: String?) -> Bool {
        bundleID.map { messengers.contains($0.lowercased()) } ?? false
    }

    /// `name` as the screen tools or `open -a` take it: a name, a path, "Name.app" or a bundle id.
    static func isRunner(_ name: String) -> Bool {
        runners.contains(normalized(name))
    }

    static func normalized(_ name: String) -> String {
        let last = (name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() as NSString).lastPathComponent
        return last.hasSuffix(".app") ? String(last.dropLast(4)) : last
    }

    /// Links that run shortcuts, open settings panes or open local files.
    static let programSchemes: Set<String> = ["shortcuts", "workflow", "x-apple.systempreferences", "file"]

    /// `open` arguments that run something: a script, app or installer (or a file with no
    /// extension, which may be a program), an app that runs commands, a link that runs a
    /// shortcut, or arguments and settings passed into the app it starts. Relative paths
    /// are from `directory`, nil when a `cd` made it unknowable.
    static func opensProgram(_ args: [String], directory: String?, home: String) -> Bool {
        guard let first = args.first else { return false }
        let rest = Array(args.dropFirst())
        let next = { opensProgram($0, directory: directory, home: home) }
        switch first {
        case "--args", "--env":
            return true
        case "-u":
            return rest.first.map { isProgramLink($0) == true } == true || next(Array(rest.dropFirst()))
        case "-s", "--stdin", "--stdout", "--stderr", "--arch":
            return next(Array(rest.dropFirst()))
        case _ where first.hasPrefix("-") && !first.hasPrefix("--") && (first.hasSuffix("a") || first.hasSuffix("b")):
            return rest.first.map(isRunner) == true || next(Array(rest.dropFirst()))
        case _ where first.hasPrefix("-"):
            return next(rest)
        default:
            return runsWhenOpened(first, directory: directory, home: home) || next(rest)
        }
    }

    private static func runsWhenOpened(_ file: String, directory: String?, home: String) -> Bool {
        if let link = isProgramLink(file) { return link }
        let trimmed = file.hasSuffix("/") ? String(file.dropLast()) : file
        let suffix = (trimmed as NSString).pathExtension.lowercased()
        if programExtensions.contains(suffix) || isRunner(trimmed) { return true }
        guard suffix.isEmpty else { return false }
        // No extension: a folder is fine; a file may be a program, and one that can't be found here may be too.
        guard let path = AgentPaths.shellPath(trimmed, home: home),
              path.hasPrefix("/") || path.hasPrefix("~") || directory != nil else { return true }
        let full = AgentPaths.absolute(path, home: home, workingDirectory: directory ?? home)
        var isFolder: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: full, isDirectory: &isFolder)
        return exists && !isFolder.boolValue
    }

    /// Whether a link runs something, or nil when `text` isn't a link.
    private static func isProgramLink(_ text: String) -> Bool? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let scheme = text[..<colon].lowercased()
        guard let head = scheme.first, head.isLetter,
              scheme.allSatisfy({ $0.isLetter || $0.isNumber || "+.-".contains($0) }) else { return nil }
        return programSchemes.contains(scheme)
    }
}

/// Text from the model, a web page or a button, made safe to show in the panel:
/// characters that hide or reorder text show as �, so a card reads as what will run.
enum ShownText {
    private static let hidden = Set<UInt32>([0x061C, 0x180E, 0x200B, 0x200C, 0x200E, 0x200F, 0xFEFF])
        .union(0x202A...0x202E).union(0x2060...0x2064).union(0x2066...0x2069)

    static func visible(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { hidden.contains($0.value) ? "\u{FFFD}" : $0 }))
    }
}
