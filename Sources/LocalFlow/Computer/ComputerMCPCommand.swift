import CoreGraphics
import Foundation

/// `LocalFlow --computer-mcp [--display <CGDirectDisplayID>]`: runs the computer-control
/// MCP server on stdin/stdout for agent mode, instead of the menu-bar app. Claude Code
/// starts it as a child of LocalFlow.app, which holds Accessibility and Screen Recording.
enum ComputerMCPCommand {
    static let flag = "--computer-mcp"
    static let displayFlag = "--display"

    static func isRequested(in arguments: [String]) -> Bool {
        arguments.contains(flag)
    }

    /// The display named by --display, or nil when none was given.
    static func requestedDisplay(in arguments: [String]) throws -> CGDirectDisplayID? {
        guard let index = arguments.firstIndex(of: displayFlag) else { return nil }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else {
            throw ToolInputError("\(displayFlag) needs a display id.")
        }
        guard let displayID = CGDirectDisplayID(arguments[valueIndex]) else {
            throw ToolInputError("\(displayFlag) must be a display id (a whole number), not \"\(arguments[valueIndex])\".")
        }
        return displayID
    }

    /// Serves until stdin closes, then exits. Never starts the menu-bar app.
    @MainActor
    static func run(arguments: [String]) -> Never {
        // A closed stdout should end the server quietly, not kill it with SIGPIPE.
        signal(SIGPIPE, SIG_IGN)
        guard ComputerLaunchGuard.isStartedByHost() else {
            FileHandle.standardError.write(Data("localflow \(flag): only LocalFlow's agent can start this.\n".utf8))
            exit(77) // EX_NOPERM
        }
        let displayID: CGDirectDisplayID
        do {
            displayID = try requestedDisplay(in: arguments) ?? ScreenMapping.displayUnderMouse()
        } catch let error as ToolInputError {
            exitWithUsageError(error.message)
        } catch {
            exitWithUsageError(error.localizedDescription)
        }
        guard ScreenMapping(displayID: displayID) != nil else {
            exitWithUsageError("display \(displayID) is not connected.")
        }

        let tools = ComputerTools(backend: LiveComputerBackend(displayID: displayID),
                                  mapping: { ScreenMapping(displayID: displayID) })
        let server = MCPServer(tools: tools)
        let lines = standardInputLines()
        Task { @MainActor in
            await server.serve(lines, write: writeLine)
            exit(0)
        }
        // The main run loop keeps NSWorkspace's app list current and runs the server task.
        RunLoop.main.run()
        exit(0)
    }

    /// Stdin as lines, read with blocking reads on a thread of its own, so end of input
    /// is seen for a pipe, a file or /dev/null alike.
    private static func standardInputLines() -> AsyncStream<String> {
        let (lines, continuation) = AsyncStream.makeStream(of: String.self)
        Thread.detachNewThread {
            while let line = readLine(strippingNewline: true) {
                continuation.yield(line)
            }
            continuation.finish()
        }
        return lines
    }

    private static func writeLine(_ line: String) throws {
        try FileHandle.standardOutput.write(contentsOf: Data((line + "\n").utf8))
    }

    private static func exitWithUsageError(_ message: String) -> Never {
        FileHandle.standardError.write(Data("localflow \(flag): \(message)\n".utf8))
        exit(64) // EX_USAGE
    }
}
