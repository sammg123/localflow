import Foundation

struct HistoryEntry: Codable, Identifiable {
    var id = UUID()
    var text: String
    var date: Date
    var appName: String
}

/// Recent dictations. In-memory by default; written to disk only if the user opts in.
@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var entries: [HistoryEntry] = []
    private let maxEntries = 50

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalFlow", isDirectory: true)
        return dir.appendingPathComponent("history.json")
    }

    init() {
        if Settings.shared.saveHistoryToDisk,
           let data = try? Data(contentsOf: Self.fileURL),
           let saved = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            entries = saved
        }
    }

    func add(text: String, appName: String) {
        entries.insert(HistoryEntry(text: text, date: Date(), appName: appName), at: 0)
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
        persistIfEnabled()
    }

    func clear() {
        entries.removeAll()
        try? FileManager.default.removeItem(at: Self.fileURL)
    }

    func persistIfEnabled() {
        guard Settings.shared.saveHistoryToDisk else {
            try? FileManager.default.removeItem(at: Self.fileURL)
            return
        }
        let dir = Self.fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }
}
