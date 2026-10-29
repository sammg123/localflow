import Darwin
import Foundation

/// The project folders on this Mac, found without asking: home's own folders and those
/// in its usual code folders. Each line has the folder, its GitHub repo and its README
/// title, so the sweep can tell which project is on screen before LocalFlow's memory
/// knows any. Only folders that could be an Instant project count.
enum InstantCatalog {
    static let heading = "## Project folders found on this Mac (folder | GitHub repo | README title)"
    static let limit = 80
    static let lineLimit = 200
    /// Folders in home that hold projects, besides home itself.
    static let codeFolders = ["Desktop", "Documents", "Developer", "Dev", "Projects", "code", "src", "repos",
                              "GitHub", "Sites"]
    /// Home's own folders that hold no code: looking in some brings up a privacy prompt.
    private static let skippedHomeFolders: Set<String> = ["Applications", "Downloads", "Library", "Movies", "Music",
                                                          "Pictures", "Public"]
    /// Enough of a README for its title and first line, of a git config for its remotes.
    private static let readmeBytes = 4096
    private static let configBytes = 16_384
    private static let pointerBytes = 1024
    private static let worktreesFolder = "/.git/worktrees/"
    private static let readmeNames = ["README.md", "readme.md", "Readme.md", "README"]

    /// For the sweep: the heading and one line per project, or nothing when there are none.
    static func text(home: String = NSHomeDirectory()) -> String {
        let found = lines(home: home)
        guard !found.isEmpty else { return "" }
        return heading + "\n" + found.map { "- " + $0 }.joined(separator: "\n")
    }

    /// Newest first: "~/code/northwind | repo: Acme/northwind | readme: Northwind: The storefront".
    static func lines(home: String = NSHomeDirectory()) -> [String] {
        guard let realHome = InstantPaths.realPath(home) else { return [] }
        let homeFolders = children(of: realHome).filter {
            !skippedHomeFolders.contains(URL(fileURLWithPath: $0).lastPathComponent)
        }
        let candidates = homeFolders + codeFolders.flatMap { children(of: realHome + "/" + $0) }
        let found: [(String, Date)] = candidates.compactMap { project(for: $0, home: home) }
        let dated: [String: Date] = Dictionary(found) { first, second in max(first, second) }
        let newestFirst = dated.sorted { first, second in
            first.value == second.value ? first.key < second.key : first.value > second.value
        }
        return newestFirst.prefix(limit).map { line(for: $0.key, home: realHome) }
    }

    /// One line's text, kept to one line with no `|` of its own, so it can't add a column.
    static func field(_ text: String) -> String {
        InstantSweepPrompt.oneLine(text.replacingOccurrences(of: "|", with: "/"))
    }

    /// The `owner/name` of the GitHub repo in a `.git/config`: origin's, else the first remote's.
    static func repo(fromGitConfig config: String) -> String? {
        var urls: [(remote: String, url: String)] = []
        var remote: String?
        for raw in config.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                remote = line.hasPrefix("[remote \"") ? String(line.dropFirst(9).prefix { $0 != "\"" }) : nil
            } else if let remote, line.hasPrefix("url") {
                let value = line.drop { $0 != "=" }.dropFirst().trimmingCharacters(in: .whitespaces)
                urls.append((remote, value))
            }
        }
        let url = urls.first { $0.remote == "origin" }?.url ?? urls.first?.url
        return url.flatMap(githubRepo)
    }

    /// The repo for a project folder, when its `.git` is a folder with a GitHub remote.
    static func repo(in folder: String) -> String? {
        head(of: folder + "/.git/config", in: folder, bytes: configBytes).flatMap(repo(fromGitConfig:))
    }

    // MARK: Which project a folder is

    /// The project a folder in home stands for, and when it was last worked on. A git
    /// worktree stands for its main checkout, so one project with many worktrees is one line.
    private static func project(for folder: String, home: String) -> (String, Date)? {
        guard let own = InstantFolders.projectRoot(folder, home: home) else { return nil }
        let git = gitDirectory(of: own)
        let main = git.range(of: worktreesFolder).flatMap { InstantFolders.projectRoot(String(git[..<$0.lowerBound]),
                                                                                       home: home) }
        return (main ?? own, changed(own, git: git))
    }

    /// The folder's git data: its `.git` folder, or the one a worktree's `.git` file points to.
    private static func gitDirectory(of folder: String) -> String {
        let dotGit = folder + "/.git"
        guard let pointer = head(of: dotGit, in: folder, bytes: pointerBytes), pointer.hasPrefix("gitdir:") else {
            return dotGit
        }
        let path = pointer.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/") ? path : folder + "/" + path
    }

    /// Git touches its index and HEAD as the project is worked on; the folder's own date
    /// only changes when something is added at its top.
    private static func changed(_ folder: String, git: String) -> Date {
        let dates = [folder, git + "/index", git + "/HEAD"].compactMap { path in
            (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        }
        return dates.max() ?? .distantPast
    }

    // MARK: One project's line

    private static func line(for folder: String, home: String) -> String {
        let tilde = "~/" + InstantPaths.relative(folder, to: home)
        let parts = [tilde, repo(in: folder).map { "repo: " + $0 }, readmeTitle(in: folder).map { "readme: " + $0 }]
        let joined = parts.compactMap { $0 }.joined(separator: " | ")
        return joined.count <= lineLimit ? joined : String(joined.prefix(lineLimit - 1)) + "…"
    }

    /// The README's first heading, then its first line of plain text: "Northwind: The storefront".
    private static func readmeTitle(in folder: String) -> String? {
        let heads = readmeNames.lazy.compactMap { head(of: folder + "/" + $0, in: folder, bytes: readmeBytes) }
        guard let text = heads.first else { return nil }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let title = lines.first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)) }
        let blurb = lines.first { line in
            guard let first = line.first else { return false }
            return first.isLetter || first.isNumber
        }
        let parts = [title, blurb == title ? nil : blurb].compactMap { $0 }.map(field)
        return parts.isEmpty ? nil : parts.joined(separator: ": ")
    }

    /// The start of a regular file that is really inside `root`. A link out of the project
    /// (to a key file, say), a folder, or a pipe that would never end reads as nothing.
    private static func head(of path: String, in root: String, bytes: Int) -> String? {
        guard let real = InstantPaths.realPath(path), let realRoot = InstantPaths.realPath(root),
              InstantPaths.isInside(real, realRoot) else { return nil }
        let descriptor = open(real, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard let data = try? handle.read(upToCount: bytes) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// `git@github.com:Acme/app.git` or `https://github.com/Acme/app.git` is "Acme/app".
    /// Only github.com itself counts, not a host that starts or ends with it.
    private static func githubRepo(_ url: String) -> String? {
        let afterScheme = url.range(of: "://").map { url[$0.upperBound...] } ?? Substring(url)
        let authority = afterScheme.prefix { $0 != "/" }
        let afterUser = authority.lastIndex(of: "@").map { afterScheme[afterScheme.index(after: $0)...] } ?? afterScheme
        let host = afterUser.prefix { $0 != ":" && $0 != "/" }
        guard host.lowercased() == "github.com" else { return nil }
        let path = afterUser.dropFirst(host.count).drop { $0 == ":" || $0 == "/" }
        let parts = path.split(separator: "/").prefix(2).map(String.init)
        guard parts.count == 2 else { return nil }
        let name = parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : parts[1]
        let slug = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard !name.isEmpty, (parts[0] + name).unicodeScalars.allSatisfy(slug.contains) else { return nil }
        return parts[0] + "/" + name
    }

    private static func children(of folder: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return names.filter { !$0.hasPrefix(".") }.map { folder + "/" + $0 }
    }
}
