import Foundation
import Testing
@testable import LocalFlow

@MainActor
@Suite("Instant Edits: only what the user sees")
struct InstantUIOnlyTests {
    // MARK: Files that are clearly not UI

    @Test("server, API, data, build config and test files are refused", arguments: [
        "server/index.ts", "src/api/users.ts", "backend/app.py", "db/migrations/001_init.sql", "schema.sql",
        "prisma/schema.prisma", "src/services/auth.ts", "src/redux/cart.ts", "src/reducers/cart.js",
        "middleware/auth.js", "supabase/functions/x/index.ts", "package.json", "Package.swift", "Podfile",
        "Cargo.toml", "go.mod", "requirements.txt", "pyproject.toml", "Dockerfile", "docker-compose.yml",
        "Makefile", "vercel.json", "App.xcodeproj/project.pbxproj", ".github/workflows/ci.yml",
        "app/api/hello/route.ts", "app/middleware.ts", "src/routes/+page.server.ts", "src/routes/api/+server.ts",
        "app/routes/login.server.ts", "Tests/AppTests/ViewTests.swift", "src/Button.test.tsx", "src/Button.spec.ts",
        "__tests__/a.js", "scripts/deploy.sh", "vite.config.ts", "next.config.js", "next.config.mjs",
        "webpack.config.js", "babel.config.js", "metro.config.js", "eslint.config.js", ".eslintrc.js", "jest.config.ts",
        "vitest.config.ts", "playwright.config.ts", "astro.config.mjs", "svelte.config.js", "nuxt.config.ts",
        "postcss.config.js",
    ])
    func nonUIPaths(relative: String) {
        #expect(InstantUIOnly.nonUIReason(relativePath: relative) != nil, "\(relative)")
    }

    @Test("view, style and copy files are fine, including mixed ones", arguments: [
        "src/components/Button.tsx", "Sources/App/Views/SettingsView.swift", "styles/main.css", "src/app.scss",
        "tailwind.config.js", "src/routes/+page.svelte", "app/page.tsx", "app/layout.tsx", "Models/Tab.swift",
        "Controllers/SettingsViewController.swift", "src/store/StoreView.swift", "public/index.html",
        "src/locales/en.json", "Resources/Localizable.xcstrings", "Assets.xcassets/Accent.colorset/Contents.json",
        "src/App.vue", "README.md", "Info.plist", "src/icons/trash.svg",
    ])
    func uiPaths(relative: String) {
        #expect(InstantUIOnly.nonUIReason(relativePath: relative) == nil, "\(relative)")
    }

    @Test("the guard refuses an edit to a non-UI file and says why")
    func guardRefusesNonUI() throws {
        let box = try InstantSandbox()
        defer { box.cleanUp() }
        let app = try box.project()
        let file = try box.write("export const limit = 10\n", to: app + "/server/config.ts")
        let guarded = InstantGuard(projects: [app], home: box.home, backupFolder: box.backups)
        let decision = guarded.review(toolName: "Edit", input: InstantInput.edit(file, "10", "20"))
        #expect(decision.message?.contains("Turn off Instant mode") == true)
    }

    // MARK: Edits that change what the app does

    @Test("style, layout and copy edits pass", arguments: [
        (#"<button onClick={handleSave} className="bg-red-500 px-4">Save</button>"#,
         #"<button onClick={handleSave} className="bg-blue-500 px-4">Save</button>"#),
        (#"<button className="p-2" onClick={() => save(item)}>"#, #"<button onClick={() => save(item)} className="p-4">"#),
        (#"<Button onPress={submit}>Save</Button>"#, #"<div className="mt-2"><Button onPress={submit}>Submit</Button></div>"#),
        (#"<button onClick={remove}>Delete</button>"#, ""),
        ("Button(action: save) {\n    Text(\"Save\")\n}\n.foregroundStyle(.red)",
         "Button(action: save) {\n    Text(\"Save\")\n}\n.foregroundStyle(.blue)\n.padding(8)"),
        ("Button(\"Save\") { save() }\n.buttonStyle(.bordered)", "Button(\"Submit\") { save() }\n.buttonStyle(.borderedProminent)"),
        ("Image(systemName: \"trash\")\n.onTapGesture { remove() }", "Image(systemName: \"archivebox\")\n.onTapGesture { remove() }"),
        ("Image(systemName: \"trash\")\n.onTapGesture {\n    remove()\n}",
         "Image(systemName: \"trash\")\n    .font(.title2)\n    .onTapGesture { remove() }"),
        (".save { color: red; padding: 4px; }", ".save { color: blue; padding: 8px; }"),
        ("<p>Thanks for writing.</p>", "<p>We await your reply.</p>"),
        ("Text(\"Step 1\")", "Text(\"Step 1)\")"),
        (#"<a @click="open" class="red">"#, #"<a @click="open" class="blue">"#),
        ("const label = 'Save'", "const label = 'Submit'"),
        ("<p>Evaluate your plan</p>", "<p>Evaluate your plan today</p>"),
        ("<p>Import contacts</p>", "<p>Import your contacts (CSV)</p>"),
        ("<p>Then press Save.</p>", "<p>Then (once ready) press Save.</p>"),
        ("Text(\"Location\")", "Text(\"Your location\")"),
        ("theme: { colors: { brand: '#f00' } }", "theme: { colors: { brand: '#00f' } }"),
    ])
    func styleEdits(old: String, new: String) {
        #expect(InstantUIOnly.addedBehavior(old: old, new: new, isNewFile: false) == nil, "\(new)")
    }

    @Test("edits that add or change behavior are refused", arguments: [
        (#"<button onClick={handleSave}>Save</button>"#, #"<button onClick={handleUpload}>Save</button>"#),
        (#"<button className="p-2">Save</button>"#, #"<button className="p-2" onClick={save}>Save</button>"#),
        (#"<Button title="Go" />"#, #"<Button title="Go" onPress={() => go()} />"#),
        ("<div>", "<div onclick=\"track()\">"),
        (#"<a class="red">"#, #"<a @click="open" class="red">"#),
        ("Button(action: save) {", "Button(action: upload) {"),
        ("Image(systemName: \"trash\")", "Image(systemName: \"trash\")\n.onTapGesture { remove() }"),
        ("Text(title)", "Text(title)\n.task { await load() }"),
        ("const items = []", "const items = await fetch('/api/items')"),
        ("useState(0)", "useState(0)\nuseEffect(() => { refresh() }, [])"),
        ("let x = 1", "let x = 1\nfunc upload() {}"),
        ("return null", "return null\n}\nfunction submitForm(data) {"),
        ("@State var name = \"\"", "@AppStorage(\"name\") var name = \"\""),
        ("el.style.color = 'red'", "el.addEventListener('click', go)"),
        ("Text(\"Hi\")", "Text(\"Hi\")\nlet data = try await api.load()"),
        ("const a = 1", "const a = eval(code)"),
        ("const a = 1", "const a = new Function('x', body)"),
        ("const Page = Home", "const Page = lazy(() => import('./Admin'))"),
        ("module.exports = { theme: {} }", "const { execSync } = require('child_process')\nmodule.exports = { theme: {} }"),
        ("export default {}", "import fs from 'node:fs'\nexport default {}"),
        ("Text(\"Hi\")", "Text(\"Hi\")\nlet p = Process()"),
        ("<p>Hi</p>", "<p>Hi</p>\n<script src=\"https://x.example/a.js\"></script>"),
        ("<div>{text}</div>", "<div dangerouslySetInnerHTML={{ __html: text }} />"),
        ("el.textContent = t", "el.innerHTML = t"),
        ("const a = 1", "navigator.sendBeacon('/t', data)"),
        ("const a = 1", "window.location.href = next"),
        ("const a = 1", "load().then(show)"),
        ("const a = 1", "document.cookie = 'a=1'"),
        ("x = 1", "subprocess.run(['ls'])"),
    ])
    func behaviorEdits(old: String, new: String) {
        #expect(InstantUIOnly.addedBehavior(old: old, new: new, isNewFile: false) != nil, "\(new)")
    }

    @Test("a new file may declare a component, but not reach the network")
    func newFiles() {
        let component = "export function Badge() {\n  return <span className=\"badge\">New</span>\n}\n"
        #expect(InstantUIOnly.addedBehavior(old: "", new: component, isNewFile: true) == nil)
        let fetching = "export function Badge() {\n  fetch('/api/hit')\n  return null\n}\n"
        #expect(InstantUIOnly.addedBehavior(old: "", new: fetching, isNewFile: true) != nil)
    }

    @Test("the guard refuses a behavior edit and tells the model to stop")
    func guardRefusesBehavior() throws {
        let box = try InstantSandbox()
        defer { box.cleanUp() }
        let app = try box.project()
        let file = try box.write("<button onClick={save}>Save</button>\n", to: app + "/src/Save.tsx")
        let guarded = InstantGuard(projects: [app], home: box.home, backupFolder: box.backups)
        let changed = guarded.review(toolName: "Edit", input: InstantInput.edit(file, "onClick={save}", "onClick={upload}"))
        #expect(changed.message?.contains("changes what the app does") == true)
        let styled = guarded.review(toolName: "Edit", input: InstantInput.edit(file, "<button onClick={save}>",
                                                                               "<button onClick={save} className=\"blue\">"))
        #expect(styled == .allow)
    }

    @Test("the check reads the whole lines an edit lands on, not just its text")
    func editInContext() throws {
        let box = try InstantSandbox()
        defer { box.cleanUp() }
        let app = try box.project()
        let tsx = try box.write("<button className=\"red\" onClick={save}>Save</button>\n", to: app + "/src/Save.tsx")
        let twice = try box.write("<a onClick={go}>go</a>\n<b onClick={go}>go</b>\n", to: app + "/src/Links.tsx")
        let swift = try box.write("Text(\"Row\")\n    .contextMenu {\n        Button(\"Delete\") { remove() }\n    }\n",
                                  to: app + "/Sources/Row.swift")
        let guarded = InstantGuard(projects: [app], home: box.home, backupFolder: box.backups)
        let edit = { (path: String, old: String, new: String, all: Bool?) in
            guarded.review(toolName: "Edit", input: InstantInput.edit(path, old, new, replaceAll: all))
        }
        #expect(!edit(tsx, "save}", "wipeAll}", nil).isAllowed, "a handler's value changed from inside it")
        #expect(!edit(twice, "go}", "stop}", true).isAllowed)
        #expect(edit(tsx, "\"red\"", "\"blue\"", nil) == .allow)
        #expect(edit(twice, ">go<", ">Go<", true) == .allow)
        #expect(edit(swift, "Button(\"Delete\")", "Button(\"Remove\")", nil) == .allow, "copy inside a menu")
    }
}
