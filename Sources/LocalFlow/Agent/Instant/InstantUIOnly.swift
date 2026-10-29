import Foundation

/// A backstop for "Instant Edits only changes how things look". The sweep and the prompt
/// do the real work; this only catches what is clearly not UI, and lets mixed files
/// (a .tsx or SwiftUI view with handlers in it) through.
enum InstantUIOnly {
    /// Folders that hold server, data, state, CI or test code, never what the user sees.
    private static let folders: [String: String] = Dictionary(uniqueKeysWithValues: [
        (["server", "servers", "backend", "api", "apis", "middleware", "middlewares", "lambda", "lambdas", "supabase",
          "services"], "server or API code"),
        (["migrations", "migration", "db", "database", "prisma"], "database code"),
        (["reducers", "redux"], "app state code"),
        ([".github", ".circleci", ".gitlab", "terraform", "infra", "infrastructure", "fastlane"], "build or deploy setup"),
        (["tests", "test", "__tests__", "spec", "specs", "e2e", "uitests", "cypress", "playwright"], "a test"),
    ].flatMap { names, kind in names.map { ($0, kind) } })
    /// Dependency, build and deploy files.
    private static let setupNames: Set<String> = [
        "package.json", "package.swift", "podfile", "gemfile", "cargo.toml", "go.mod", "go.sum", "requirements.txt",
        "pyproject.toml", "setup.py", "setup.cfg", "build.gradle", "build.gradle.kts", "settings.gradle", "pom.xml",
        "composer.json", "project.pbxproj", "project.yml", "dockerfile", "docker-compose.yml", "docker-compose.yaml",
        "compose.yml", "compose.yaml", "makefile", "procfile", "vercel.json", "netlify.toml", "firebase.json",
        "wrangler.toml", "fly.toml", "render.yaml", ".gitignore", ".gitattributes",
    ]
    /// Build and tool configs that run as code (`vite.config.ts`, `.eslintrc.js`). Tailwind's
    /// config is left out: its theme is how things look.
    private static let configStems: [String] = [
        "vite", "next", "webpack", "babel", "metro", "rollup", "esbuild", "rspack", "eslint", "prettier", "jest",
        "vitest", "playwright", "cypress", "karma", "astro", "svelte", "nuxt", "remix", "postcss", "craco", "turbo",
    ]
    private static let configPrefixes: [String] = [".eslintrc", ".babelrc", ".prettierrc", ".swcrc"]
    /// Server-only modules in Next.js, Remix and SvelteKit.
    private static let serverNames: Set<String> = ["route.ts", "route.js", "middleware.ts", "middleware.js"]
    private static let extensions: [String: String] = [
        "sql": "database code", "prisma": "database code", "graphql": "API code", "gql": "API code",
        "proto": "API code", "tf": "build or deploy setup", "tfvars": "build or deploy setup", "sh": "a script",
        "bash": "a script", "zsh": "a script", "fish": "a script", "ps1": "a script",
        "entitlements": "app capabilities", "xcconfig": "build or project setup",
    ]

    /// What kind of non-UI file `relativePath` (from the project's top) clearly is, or nil.
    static func nonUIReason(relativePath: String) -> String? {
        let parts = relativePath.lowercased().split(separator: "/").map(String.init)
        guard let name = parts.last else { return nil }
        if let kind = parts.dropLast().lazy.compactMap({ folders[$0] }).first { return kind }
        if setupNames.contains(name) || configStems.contains(where: { name.hasPrefix($0 + ".config.") })
            || configPrefixes.contains(where: name.hasPrefix) {
            return "build or project setup"
        }
        if serverNames.contains(name) || name.contains(".server.") || name.hasPrefix("+server.") {
            return "server code"
        }
        if name.contains(".test.") || name.contains(".spec.") || name.hasSuffix("tests.swift")
            || name.hasSuffix("test.swift") || name.hasPrefix("test_") {
            return "a test"
        }
        return extensions[InstantPaths.fileExtension(name)]
    }

    /// What behavior `new` adds or changes compared with `old`, or nil when it only
    /// changes how things look.
    ///
    /// The heuristic: find each behavior-shaped piece (an event handler with its value, an
    /// action, a gesture or task with its closure, a network, storage or async call with its
    /// arguments, and for edits a function declaration), with whitespace taken out. Every
    /// piece in `new` must already be in `old`. So restyling a line that has an `onClick`
    /// passes, removing a button (hiding it) passes, and adding or changing a handler,
    /// call or function doesn't. A new file may declare components, so declarations only
    /// count for edits.
    static func addedBehavior(old: String, new: String, isNewFile: Bool) -> String? {
        let before = InstantBehavior.pieces(in: old, declarations: !isNewFile)
        let after = InstantBehavior.pieces(in: new, declarations: !isNewFile)
        var remaining = Dictionary(before.map { ($0.text, 1) }, uniquingKeysWith: +)
        for piece in after {
            let left = remaining[piece.text, default: 0]
            guard left > 0 else { return piece.kind }
            remaining[piece.text] = left - 1
        }
        return nil
    }

    /// The whole lines an edit changes in `text`, before and after it, so a change made
    /// from inside a handler (`save}` to `wipe}` in `onClick={save}`) is seen with its
    /// handler. Nil when `old` isn't in the text; the edit will fail anyway.
    static func editedLines(of text: String, old: String, new: String, all: Bool) -> (before: String, after: String)? {
        guard let first = text.range(of: old) else { return nil }
        let edited = all ? text.replacingOccurrences(of: old, with: new) : text.replacingCharacters(in: first, with: new)
        let before = text.split(separator: "\n", omittingEmptySubsequences: false)
        let after = edited.split(separator: "\n", omittingEmptySubsequences: false)
        let shorter = min(before.count, after.count)
        var head = 0
        while head < shorter, before[head] == after[head] { head += 1 }
        var tail = 0
        while tail < shorter - head, before[before.count - 1 - tail] == after[after.count - 1 - tail] { tail += 1 }
        return (before[head..<(before.count - tail)].joined(separator: "\n"),
                after[head..<(after.count - tail)].joined(separator: "\n"))
    }
}
