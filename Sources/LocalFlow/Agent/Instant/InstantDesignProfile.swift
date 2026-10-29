import Foundation

/// A project's design profile, read by LocalFlow itself before an Instant run so the model
/// only has to find the file to change: its design and product docs and style guides, or
/// the README when there are none, up to `byteLimit` in all.
struct InstantDesignProfile: Equatable, Sendable {
    static let byteLimit = 24_576

    /// The docs, each under a `## name` heading; empty when there are none.
    let text: String
    /// The docs read, from the project's top folder, in order.
    let files: [String]

    var isEmpty: Bool { files.isEmpty }

    /// Looks in the project's top folder and its docs folder. Only regular text files that
    /// really are inside the project are read, so a link can't pull in anything else.
    static func find(in root: String) -> InstantDesignProfile {
        guard let real = InstantPaths.realPath(root) else { return InstantDesignProfile(text: "", files: []) }
        let found = candidates(in: real)
        let profile = read(found.filter(isDesignDoc), root: real)
        return profile.isEmpty ? read(found.filter(isReadme), root: real) : profile
    }

    /// Files at the top and in docs/, top first, each folder in name order.
    private static func candidates(in root: String) -> [String] {
        ["", "docs/"].flatMap { folder in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: root + "/" + folder)) ?? []
            return names.sorted { rank($0) == rank($1) ? $0 < $1 : rank($0) < rank($1) }.map { folder + $0 }
        }
    }

    /// DESIGN.md first, then PRODUCT.md, then the rest.
    private static func rank(_ name: String) -> Int {
        ["design.md", "product.md"].firstIndex(of: name.lowercased()) ?? 2
    }

    private static func isDesignDoc(_ relative: String) -> Bool {
        let name = relative.lowercased().split(separator: "/").last.map(String.init) ?? ""
        guard name.hasSuffix(".md") else { return false }
        if relative.lowercased().hasPrefix("docs/") {
            return ["design", "style", "brand", "ui"].contains { name.hasPrefix($0) }
        }
        return name == "design.md" || name == "product.md" || name.hasPrefix("design-profile")
            || name.hasPrefix("design-system") || ["styleguide.md", "style-guide.md", "style_guide.md", "brand.md"].contains(name)
    }

    private static func isReadme(_ relative: String) -> Bool {
        !relative.hasPrefix("docs/") && relative.lowercased() == "readme.md"
    }

    private static func read(_ relatives: [String], root: String) -> InstantDesignProfile {
        var budget = byteLimit
        var parts: [String] = []
        var files: [String] = []
        for relative in relatives where budget > 0 {
            guard let text = safeText(root + "/" + relative, root: root) else { continue }
            let (kept, wasCut) = cut(text, to: budget)
            parts.append("## \(relative)\n" + kept + (wasCut ? "\n[…cut short]" : ""))
            files.append(relative)
            budget -= kept.utf8.count
        }
        return InstantDesignProfile(text: parts.joined(separator: "\n\n"), files: files)
    }

    /// The start of the file's text, a little over the cap at most, if it's a regular UTF-8
    /// file whose real place is inside the project. A huge file is never read whole.
    private static func safeText(_ path: String, root: String) -> String? {
        guard let real = InstantPaths.realPath(path), InstantPaths.isInside(real, root),
              (try? FileManager.default.attributesOfItem(atPath: real)[.type]) as? FileAttributeType == .typeRegular,
              let handle = FileHandle(forReadingAtPath: real) else { return nil }
        defer { try? handle.close() }
        // A few bytes over the cap, so a cut still shows as one.
        guard let read = try? handle.read(upToCount: byteLimit + 4) else { return nil }
        let data = wholeCharacters(read)
        guard InstantPaths.isText(data) else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `data` without a character cut in half at its end.
    private static func wholeCharacters(_ data: Data) -> Data {
        for drop in 0...min(3, data.count) where String(data: data.dropLast(drop), encoding: .utf8) != nil {
            return Data(data.dropLast(drop))
        }
        return data
    }

    /// At most `limit` bytes, ending at a line where it can, and never inside a character.
    private static func cut(_ text: String, to limit: Int) -> (String, Bool) {
        guard text.utf8.count > limit else { return (text, false) }
        var kept = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard kept.utf8.count + line.utf8.count + 1 <= limit else { break }
            kept += line + "\n"
        }
        guard kept.isEmpty else { return (kept, true) }
        return (String(decoding: wholeCharacters(Data(text.utf8.prefix(limit))), as: UTF8.self), true)
    }
}
