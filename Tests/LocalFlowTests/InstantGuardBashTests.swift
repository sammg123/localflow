import Foundation
import Testing
@testable import LocalFlow

/// The terminal in Instant Edits: reading only, and only inside the projects. `P` in a
/// command stands for the project's folder.
@MainActor
@Suite("Instant Edits: the terminal only reads")
struct InstantGuardBashTests {
    private func review(_ command: String) throws -> InstantDecision {
        let box = try InstantSandbox()
        defer { box.cleanUp() }
        let app = try box.project()
        try box.write("Save\n", to: app + "/src/a.ts")
        let guarded = InstantGuard(projects: [app], home: box.home, backupFolder: box.backups)
        return guarded.review(toolName: "Bash", input: InstantInput.bash(command.replacingOccurrences(of: "P", with: app)))
    }

    @Test("reading commands run, alone or piped", arguments: [
        "ls", "pwd", "ls -la P", "ls P/src 2>/dev/null", "cat P/src/a.ts", "head -n 20 P/src/a.ts", "tail -n 5 P/src/a.ts",
        "wc -l P/src/a.ts", "file P/src/a.ts", "grep -rn Save P/src", "egrep -n 'a|b' P/src/a.ts",
        "grep -e Save -n P/src/a.ts", "rg -e Save P", "grep -rn secret P/src", "grep -rn process.env P/src",
        "cat src/a.ts", "grep -r Save src",
        "rg -n Save P", "rg --files P", "find P -name '*.tsx'", "find P -type f -name a.ts -print",
        "git -C P status", "git -C P diff", "git -C P diff --stat", "git -C P log --oneline -5", "git -C P show HEAD --stat",
        "git -C P ls-files", "git -C P grep -n Save", "git -C P rev-parse HEAD", "git -C P blame src/a.ts",
        "git -C P branch", "git -C P branch -a", "git -C P branch --show-current", "git -C P branch -vv",
        "git --no-pager -C P log -3", "git status", "git log --oneline -3", "git diff -- src",
        "git -C P log | head -5", "cat P/src/a.ts | grep Save | wc -l", "git -C P diff 2>&1 | head -40",
        "cd P && git status", "cd P && git diff && git status", "cd P; ls src", "ls P || pwd",
        "grep -c Save P/src/a.ts <<< x",
    ])
    func allowed(command: String) throws {
        #expect(try review(command) == .allow, "\(command)")
    }

    @Test("anything that writes, runs or reaches outside the projects is refused", arguments: [
        "cat P/src/a.ts > P/src/b.ts", "cat x > y", "cat x >> y", "ls | tee out.txt", "ls > /dev/stdout2",
        "git commit -m x", "git -C P commit -am x", "git push", "git -C P checkout main", "git -C P branch new-feature",
        "git -C P branch -D old", "git -C P branch -m a b", "git stash", "git -C P add .", "git -C P restore src",
        "npm test", "npm install", "npx prettier --write .", "swift build", "make", "yarn dev",
        "find . -delete", #"find . -exec rm {} \;"#, #"find . -execdir ls \;"#, #"find . -ok rm {} \;"#,
        "find . -fprint out.txt", "ls; rm -rf ~", "ls && rm -rf ~", "ls || rm x", "ls & rm x", "ls\nrm x",
        "$(rm x)", "echo $(rm x)", "cat `rm x`", "cat <(rm x)", "ls > >(sh)", "FOO=1 ls", "env ls", "sudo ls",
        "command ls", "/tmp/ls", "./ls", #"\rm x"#, #""rm" x"#, "rm -rf build", "mv a b", "cp a b", "sed -i s/a/b/ x",
        "echo hi", "cat /etc/passwd", "cat ~/.ssh/id_rsa", "cat P/../../etc/passwd", "ls ..", "cat ../x",
        "grep -r x /", "find / -name x", "git -C /tmp status", "git -c core.pager=sh log", "git --git-dir=/x log",
        "git -C P diff --output=/tmp/x", "git -C P log --output=x", "git -C P grep -Ocat Save", "rg --pre=sh x P",
        "rg --pre sh x P", "tail -f P/src/a.ts", "tail -F x", "cat $HOME/.zshrc", "cat ${HOME}/.zshrc", "ls {P,/etc}",
        "ls ~root", "file -C -m x", "cd /tmp && ls", "cd", "cd .. && ls", "open P", "curl https://example.com",
        "osascript -e x", "sh -c ls", "bash", "python3 -c 'print(1)'", "xargs rm", "",
        // A pattern given inside an option leaves the first plain word a file to read.
        "rg --regexp=x /etc/passwd", "grep -ex ~/.zsh_history", "grep -nex /etc/passwd", "rg x -g -e /etc/passwd",
        "grep -rn '/api/' P/src", "rg --hostname-bin x P",
        // Reads stay cheap and away from secrets, like Read.
        "cat P/.env", "grep KEY P/.env.local", "head P/certs/server.pem", "cat .env", "cat P/node_modules/x/index.js",
        "ls P/.git", "find P -name '*.pem'",
        // Following links could leave the project.
        "grep -R Save P/src", "grep -Rn Save P/src", "grep --dereference-recursive x P", "rg -L x P", "rg --follow x P",
        "find -L P -name x", "find P -follow",
    ])
    func denied(command: String) throws {
        let decision = try review(command)
        #expect(!decision.isAllowed, "\(command)")
    }

    @Test("the refusal tells the model the terminal only reads")
    func refusalWording() throws {
        let message = try review("npm run build").message
        #expect(message?.contains("can only read") == true)
        #expect(message?.contains("Grep") == true)
    }

    @Test("a relative path through a link to outside the project is refused, also after cd")
    func linksOut() throws {
        let box = try InstantSandbox()
        defer { box.cleanUp() }
        let app = try box.project()
        try box.write("Save\n", to: app + "/src/a.ts")
        let outside = box.root.appendingPathComponent("outside").path
        try box.write("private\n", to: outside + "/notes.txt")
        try FileManager.default.createSymbolicLink(atPath: app + "/assets", withDestinationPath: outside)
        try FileManager.default.createSymbolicLink(atPath: app + "/src/deep", withDestinationPath: outside)
        let guarded = InstantGuard(projects: [app], home: box.home, backupFolder: box.backups)
        let run = { (command: String) in
            guarded.review(toolName: "Bash", input: InstantInput.bash(command.replacingOccurrences(of: "P", with: app)))
        }
        for command in ["cat assets/notes.txt", "cd P && cat assets/notes.txt", "grep -r x assets", "ls assets/",
                        "cat assets/*", "head -n 3 assets/notes.txt", "cd P/src && cat deep/notes.txt"] {
            #expect(!run(command).isAllowed, "\(command)")
        }
        #expect(run("cat src/a.ts") == .allow)
        #expect(run("cd P/src") == .allow)
        #expect(!run("cat deep/notes.txt").isAllowed, "a later command runs in the folder cd left it in")
        #expect(run("cat a.ts") == .allow)
    }

    @Test("a command that isn't text is refused")
    func noCommand() throws {
        let box = try InstantSandbox()
        defer { box.cleanUp() }
        let guarded = InstantGuard(projects: [try box.project()], home: box.home, backupFolder: box.backups)
        #expect(!guarded.review(toolName: "Bash", input: ["command": 3]).isAllowed)
        #expect(!guarded.review(toolName: "Bash", input: [:]).isAllowed)
    }
}
