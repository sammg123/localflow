import Darwin
import Foundation

/// The screen server runs with LocalFlow's Accessibility and Screen Recording. Started
/// from LocalFlow (through Claude Code) it's the agent's; started any other way, such as
/// `open -a LocalFlow --args --computer-mcp`, it would lend those permissions to whoever
/// asked. So it serves only when a LocalFlow process is a near ancestor.
enum ComputerLaunchGuard {
    /// LocalFlow → Claude Code → (a wrapper or two) → this server.
    static let maxDepth = 4

    static func isStartedByHost(ancestors: [String], own: String) -> Bool {
        let own = resolved(own)
        return ancestors.prefix(maxDepth).contains { resolved($0) == own }
    }

    /// Whether this process was started by LocalFlow.
    static func isStartedByHost() -> Bool {
        guard let own = path(of: getpid()) else { return false }
        return isStartedByHost(ancestors: ancestorPaths(of: getpid(), limit: maxDepth), own: own)
    }

    /// Executable paths of the parent, grandparent and so on, nearest first.
    static func ancestorPaths(of pid: pid_t, limit: Int) -> [String] {
        var paths: [String] = []
        var current = pid
        while paths.count < limit, let next = parent(of: current), next > 0, next != current {
            guard let path = path(of: next) else { break }
            paths.append(path)
            current = next
        }
        return paths
    }

    private static func parent(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    private static func path(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }
}
