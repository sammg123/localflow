import Foundation

/// Which folders can be a project Instant Edits changes: the user's own code, never the
/// system's, their whole home, or a settings folder such as ~/Library or ~/.claude.
enum InstantFolders {
    /// Outside home, these and everything in them belong to the system.
    static let systemFolders = ["/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/etc", "/private/etc",
                                "/var", "/private/var", "/opt", "/cores", "/dev"]
    /// A file at a project's top that marks it as one, besides `.git`.
    static let manifests: Set<String> = [
        "package.json", "package.swift", "podfile", "cargo.toml", "go.mod", "pyproject.toml", "requirements.txt",
        "gemfile", "composer.json", "pubspec.yaml", "build.gradle", "build.gradle.kts", "pom.xml", "deno.json",
        "project.yml",
    ]

    /// The real path of an existing folder or file; `~` is home.
    static func resolved(_ path: String, home: String = NSHomeDirectory()) -> String? {
        let expanded = path == "~" ? home : path.hasPrefix("~/") ? home + path.dropFirst() : path
        guard expanded.hasPrefix("/") else { return nil }
        return InstantPaths.realPath(expanded)
    }

    /// Why `path` can't go on the Settings list of project folders, or nil when it can.
    /// It must be a git project's top folder (a `.git` folder, or file for a worktree).
    static func problem(with path: String, home: String) -> String? {
        guard let folder = resolved(path, home: home), isDirectory(folder) else {
            return "That isn't a folder."
        }
        if let problem = placeProblem(folder, home: home) { return problem }
        guard InstantPaths.exists(folder + "/.git") else {
            return "That folder isn't the top of a git project (it has no .git). Pick the project's top folder."
        }
        return nil
    }

    /// The real path of the project folder the sweep named, or nil when it isn't one: it
    /// must exist inside home, be a folder, and have `.git` or a package file at its top.
    static func projectRoot(_ path: String, home: String) -> String? {
        guard let folder = resolved(path, home: home), isDirectory(folder),
              let realHome = InstantPaths.realPath(home), folder.lowercased().hasPrefix(realHome.lowercased() + "/"),
              placeProblem(folder, home: home) == nil else { return nil }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).map { $0.lowercased() }
        let marked = names.contains(".git") || names.contains(where: manifests.contains)
            || names.contains { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }
        return marked ? folder : nil
    }

    /// Home itself, a folder around it, a system folder, or a settings folder in home.
    private static func placeProblem(_ folder: String, home: String) -> String? {
        let realHome = InstantPaths.realPath(home) ?? home
        if folder.lowercased() == realHome.lowercased() {
            return "Pick a project folder, not your whole home folder."
        }
        if InstantPaths.isInside(realHome, folder) {
            return "That folder holds your whole home folder. Pick a project folder inside it."
        }
        if InstantPaths.isInside(folder, realHome) {
            let first = InstantPaths.relative(folder, to: realHome).split(separator: "/").first.map(String.init) ?? ""
            return first.hasPrefix(".") || first.lowercased() == "library"
                ? "That's a settings folder, not a project. Pick one of your own project folders." : nil
        }
        let system = systemFolders.contains { InstantPaths.isInside(folder, $0) }
        return system ? "That's a system folder. Pick one of your own project folders." : nil
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isFolder: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) && isFolder.boolValue
    }
}
