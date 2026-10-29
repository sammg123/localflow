import Foundation

/// What Claude Code is told when Instant Edits refuses a tool: one or two sentences to the
/// model, saying what to do instead.
enum InstantRefusal {
    static let stopLine = "That changes what the app does, not just how it looks. Turn off Instant mode to run it."
    static let noRun = "No Instant Edits run is under way, so nothing can be changed."

    static let outside = "That's outside the project Instant Edits is changing. Use an absolute path inside the project folder named in your instructions."
    static let plainPath = "Use the file's full absolute path, without '..'."
    static let searchPath = "Give Grep or Glob a path inside the project folder named in your instructions."
    static let notAFile = "That isn't a file. Use the full path of a file inside the project."
    static let generated = "That's generated, downloaded or git's own. Change the project's own source files instead."
    static let readGenerated = "That's generated, downloaded or git's own. Read the project's own source files instead."
    static let bigRead = "That file is over 1 MB. Instant Edits only needs the code that draws that part of the screen."
    static let lockfile = "Instant Edits doesn't change lockfiles. Change the project's own source files instead."
    static let secret = "Instant Edits doesn't touch .env, key, certificate or secret files."
    static let binary = "That's a binary file; Instant Edits only edits text files."
    static let missingFile = "That file doesn't exist. Check the path; Write is only for a small new file."
    static let hardLink = "That file is hard-linked to another place, so Instant Edits leaves it alone."
    static let tooLargeFile = "That file is over 1 MB, too big for Instant Edits to change safely."
    static let editFields = "Edit needs file_path, old_string and new_string."
    static let emptyOld = "old_string can't be empty: copy the exact text to replace from the file."
    static let sameText = "old_string and new_string are the same, so there's nothing to change."
    static let writeFields = "Write needs file_path and content."
    static let writeExisting = "Use Edit to change part of an existing file; Instant Edits never rewrites whole files."
    static let newFolder = "Put a new file in a folder that already exists in the project."
    static let budget = "Instant Edits limit reached (small changes only). Stop here and tell the user to turn off Instant mode for bigger changes."
    static let bash = "Instant Edits can only read with the terminal (ls, cat, grep, git diff…) inside the project; search with the Grep tool. It can't run builds, tests, installs, git changes or deploys."
    static let toolSettings = "Instant Edits doesn't change agent, editor or git-hook settings (.claude, .vscode, CLAUDE.md…). Change the project's own source files instead."
    static let screen = "Instant Edits only changes code: it can look at the screen but not click, type or open apps. Make the change in the project's files."
    static let notebook = "Instant Edits doesn't edit notebooks. Use Edit on the project's code files."
    static let subagent = "Instant Edits works alone, without subagents. Find the file with Grep or Glob and change it with Edit."
    static let web = "Instant Edits doesn't use the web. Work from the screenshot and the project's own files."

    static func longEdit(_ limit: Int) -> String {
        "That edit is over \(limit.formatted()) characters, too long for Instant Edits. Make a smaller, targeted change, or stop and tell the user to turn off Instant mode."
    }

    static func longWrite(_ limit: Int) -> String {
        "That new file is over \(limit.formatted()) characters, too long for Instant Edits. Keep to a small change, or stop and tell the user to turn off Instant mode."
    }

    static func replaceAll(_ count: Int, limit: Int) -> String {
        "replace_all would change \(count) places, more than Instant Edits allows (\(limit)). Change only the places the request is about."
    }

    static func notUI(_ kind: String) -> String {
        "That file looks like \(kind), not UI. Stop and reply: \"\(stopLine)\""
    }

    static func behavior(_ kind: String) -> String {
        "That edit adds or changes \(kind), which changes what the app does. Keep to how it looks, or stop and reply: \"\(stopLine)\""
    }

    static func otherTool(_ name: String) -> String {
        "Instant Edits can't use \(name.prefix(60)). Use Read, Grep, Glob and Edit inside the project."
    }
}
