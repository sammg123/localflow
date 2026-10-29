import Foundation

/// The project folders the user listed in Settings for Instant Edits, as real absolute
/// paths. Saved in UserDefaults.
@MainActor
final class InstantProjects: ObservableObject {
    static let shared = InstantProjects()
    static let defaultsKey = "instantProjects"

    @Published private(set) var paths: [String]
    private let defaults: UserDefaults
    private let home: String

    init(defaults: UserDefaults = .standard, home: String = NSHomeDirectory()) {
        self.defaults = defaults
        self.home = home
        paths = defaults.stringArray(forKey: Self.defaultsKey) ?? []
    }

    /// Adds the folder, or says in a sentence why it can't be one.
    func add(_ url: URL) -> String? {
        if let problem = InstantFolders.problem(with: url.path, home: home) { return problem }
        guard let folder = InstantFolders.resolved(url.path, home: home) else { return "That isn't a folder." }
        if let problem = overlap(folder) { return problem }
        save(paths + [folder])
        return nil
    }

    func remove(_ path: String) {
        save(paths.filter { $0 != path })
    }

    /// The same folder, one inside a listed one, or one around a listed one.
    private func overlap(_ folder: String) -> String? {
        for listed in paths {
            let name = URL(fileURLWithPath: listed).lastPathComponent
            if folder.lowercased() == listed.lowercased() { return "That project is already on the list." }
            if InstantPaths.isInside(folder, listed) {
                return "That folder is inside \(name), which is already on the list."
            }
            if InstantPaths.isInside(listed, folder) {
                return "That folder has \(name) inside it, which is already on the list."
            }
        }
        return nil
    }

    private func save(_ updated: [String]) {
        paths = updated
        defaults.set(updated, forKey: Self.defaultsKey)
    }
}
