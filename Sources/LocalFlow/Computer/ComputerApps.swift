import AppKit

/// A running app as list_apps reports it.
struct RunningApp: Equatable, Sendable {
    let name: String
    let bundleID: String?
    let isFrontmost: Bool

    var label: String {
        bundleID.map { "\(name) (\($0))" } ?? name
    }
}

/// The text list_apps returns.
enum AppList {
    static func describe(_ apps: [RunningApp]) -> String {
        guard !apps.isEmpty else { return "No apps are running." }
        let sorted = apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let frontmost = sorted.first(where: \.isFrontmost).map { "Frontmost: \($0.label)" } ?? "No app is frontmost."
        return ([frontmost, "Running apps:"] + sorted.map { "- \($0.label)" }).joined(separator: "\n")
    }

    /// Regular (Dock) apps only; LocalFlow itself is a menu-bar app and isn't listed.
    @MainActor
    static func running(in workspace: NSWorkspace = .shared) -> [RunningApp] {
        let frontmost = workspace.frontmostApplication?.processIdentifier
        return workspace.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map { app in
                RunningApp(name: app.localizedName ?? app.bundleIdentifier ?? "Unknown app",
                           bundleID: app.bundleIdentifier,
                           isFrontmost: app.processIdentifier == frontmost)
            }
    }
}

/// Finds an app bundle by name in the usual Applications folders.
enum AppLocator {
    static let searchFolders: [URL] = [
        URL(fileURLWithPath: "/Applications"),
        URL(fileURLWithPath: "/Applications/Utilities"),
        URL(fileURLWithPath: "/System/Applications"),
        URL(fileURLWithPath: "/System/Applications/Utilities"),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
    ]

    /// A plain name or bundle id: never a path, never empty.
    static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.contains(":") && !name.hasPrefix(".")
            && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// "com.apple.Safari" rather than "Safari" or "Safari.app".
    static func looksLikeBundleID(_ name: String) -> Bool {
        name.contains(".") && !name.contains(" ") && !name.lowercased().hasSuffix(".app")
    }

    static func find(_ name: String, in folders: [URL] = searchFolders) -> URL? {
        let wanted = appName(name).lowercased()
        for folder in folders {
            if let match = apps(in: folder).first(where: { appName($0.lastPathComponent).lowercased() == wanted }) {
                return match
            }
        }
        return nil
    }

    /// Apps whose names contain the text, for a "did you mean" hint.
    static func suggestions(for name: String, in folders: [URL] = searchFolders, limit: Int = 5) -> [String] {
        let wanted = appName(name)
        let names = folders.flatMap(apps(in:)).map { appName($0.lastPathComponent) }
        let matches = Set(names.filter { $0.localizedCaseInsensitiveContains(wanted) })
        return Array(matches.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }.prefix(limit))
    }

    private static func apps(in folder: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return contents.filter { $0.pathExtension.lowercased() == "app" }
    }

    private static func appName(_ name: String) -> String {
        name.lowercased().hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}
