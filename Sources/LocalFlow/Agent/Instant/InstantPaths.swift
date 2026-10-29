import Foundation

/// Where a path really points, and which files in a project Instant Edits leaves alone.
enum InstantPaths {
    /// Folders of generated or downloaded files, and git's own.
    static let generatedFolders: Set<String> = [
        ".git", "node_modules", "build", "dist", ".build", "deriveddata", ".next", "pods", "vendor", ".swiftpm",
        ".venv", "venv", "__pycache__", ".turbo", ".nuxt", ".svelte-kit", ".expo", ".gradle", "xcuserdata", ".output",
    ]
    static let lockfiles: Set<String> = [
        "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb", "bun.lock", "package.resolved", "podfile.lock",
        "cargo.lock", "gemfile.lock", "poetry.lock", "composer.lock", "pipfile.lock", "uv.lock",
    ]
    /// Agent, editor and git-hook settings: they run code (hooks, tasks, MCP servers) or
    /// steer agents the next time someone opens the project.
    private static let toolFolders: Set<String> = [
        ".claude", ".vscode", ".idea", ".husky", ".cursor", ".windsurf", ".devcontainer", ".zed", ".fleet",
    ]
    private static let toolNames: Set<String> = [
        ".mcp.json", "claude.md", "claude.local.md", "agents.md", "gemini.md", ".cursorrules", ".windsurfrules",
        ".clinerules", ".pre-commit-config.yaml", "lefthook.yml", "lefthook.yaml", ".lefthook.yml", ".lintstagedrc",
    ]
    private static let secretExtensions: Set<String> = [
        "pem", "key", "p12", "pfx", "cer", "crt", "der", "p8", "keystore", "jks", "mobileprovision", "gpg", "asc", "ppk",
    ]
    private static let secretNames: Set<String> = [
        "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", ".npmrc", ".pypirc", ".netrc", ".htpasswd",
    ]
    /// A name's part before its first dot that marks a secrets file (`secrets.json`).
    private static let secretStems: Set<String> = ["secret", "secrets", "credential", "credentials", "service-account"]
    static let binaryExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "ico", "icns", "bmp", "tiff", "pdf", "psd", "ai", "sketch", "fig",
        "zip", "gz", "tgz", "tar", "bz2", "xz", "7z", "rar", "dmg", "pkg", "exe", "dll", "dylib", "so", "a", "o",
        "class", "jar", "wasm", "mp3", "mp4", "mov", "m4a", "wav", "aac", "avi", "mkv", "ttf", "otf", "woff", "woff2",
        "eot", "sqlite", "sqlite3", "db", "realm", "car", "nib", "bin",
    ]

    /// `path` made absolute (`~` is home), with links followed as far as it exists. Nil
    /// for a relative path, one with `..` in it (Claude Code sends plain absolute paths;
    /// `..` through a link reads two ways), or one that ends in a link to nowhere.
    static func resolve(_ path: String, home: String) -> String? {
        let expanded = path == "~" ? home : path.hasPrefix("~/") ? home + path.dropFirst() : path
        guard expanded.hasPrefix("/"), !expanded.split(separator: "/").contains("..") else { return nil }
        var head = URL(fileURLWithPath: expanded).standardized.path
        var tail: [String] = []
        while true {
            if let real = realPath(head) {
                // The first missing part must really be missing, not a link to nowhere.
                if let next = tail.last, exists(real + "/" + next) { return nil }
                return ([real == "/" ? "" : real] + tail.reversed()).joined(separator: "/")
            }
            guard head != "/" else { return nil }
            let url = URL(fileURLWithPath: head)
            tail.append(url.lastPathComponent)
            head = url.deletingLastPathComponent().path
        }
    }

    /// The real path of something that exists.
    static func realPath(_ path: String) -> String? {
        guard let pointer = realpath(path, nil) else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    /// Whether anything, even a broken link, is at `path`.
    static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    /// `path` is `folder` or under it. macOS names don't care about case, so neither does this.
    static func isInside(_ path: String, _ folder: String) -> Bool {
        let path = path.lowercased()
        let folder = folder.lowercased()
        return path == folder || path.hasPrefix(folder == "/" ? "/" : folder + "/")
    }

    /// The root among `roots` that holds `path`.
    static func root(of path: String, in roots: [String]) -> String? {
        roots.first { isInside(path, $0) }
    }

    /// `path` from inside `root`, such as `src/App.tsx`.
    static func relative(_ path: String, to root: String) -> String {
        path.count > root.count ? String(path.dropFirst(root.count + 1)) : ""
    }

    /// Why Instant Edits won't change the file at `relative` (from the project's top
    /// folder), or nil: generated or downloaded files, lockfiles, secrets, binaries.
    static func refusal(relative: String) -> String? {
        let parts = relative.lowercased().split(separator: "/").map(String.init)
        guard let name = parts.last else { return InstantRefusal.notAFile }
        if isGenerated(relative: relative) { return InstantRefusal.generated }
        if parts.contains(where: toolFolders.contains) || toolNames.contains(name) { return InstantRefusal.toolSettings }
        if lockfiles.contains(name) { return InstantRefusal.lockfile }
        if isSecret(name) { return InstantRefusal.secret }
        if binaryExtensions.contains(fileExtension(name)) { return InstantRefusal.binary }
        return nil
    }

    /// In (or is) a folder of generated or downloaded files, or git's own.
    static func isGenerated(relative: String) -> Bool {
        relative.lowercased().split(separator: "/").contains { generatedFolders.contains(String($0)) }
    }

    static func isSecret(_ name: String) -> Bool {
        let stem = name.split(separator: ".", omittingEmptySubsequences: false).first.map(String.init) ?? name
        return name.hasPrefix(".env") || secretNames.contains(name) || secretExtensions.contains(fileExtension(name))
            || secretStems.contains(stem)
    }

    /// The part after the last dot, lowercased; empty when there's none.
    static func fileExtension(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[name.index(after: dot)...]).lowercased()
    }

    /// Text: UTF-8 with no NUL bytes.
    static func isText(_ data: Data) -> Bool {
        !data.contains(0) && String(data: data, encoding: .utf8) != nil
    }
}
