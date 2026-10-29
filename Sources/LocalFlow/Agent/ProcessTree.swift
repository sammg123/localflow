import Darwin
import Foundation

/// What a session left running, so ending the session ends it too: Claude Code's
/// children and theirs, anything still in a process group one of them leads, and jobs
/// that left both (Claude Code runs each command in a shell of its own, so a `nohup … &`
/// ends up with no parent and a group nobody leads), found by macOS holding LocalFlow
/// responsible for them. Never LocalFlow, its own group, or its other helpers.
enum ProcessTree {
    struct Entry: Equatable, Sendable {
        let pid: pid_t
        let parent: pid_t
        let group: pid_t
        var isZombie = false
        /// Seconds since 1970.
        var started: TimeInterval?
    }

    /// Everything under `root` (not `root` itself) and in the groups they or `root` lead.
    static func targets(under root: pid_t, in table: [Entry], ownGroup: pid_t = getpgrp(),
                        me: pid_t = getpid()) -> [pid_t] {
        guard root > 1 else { return [] }
        let children = Dictionary(grouping: table.filter { $0.pid != $0.parent }, by: \.parent)
        let family = descendants(of: root, children: children, seen: [root])
        let leaders = Set(family + [root]).subtracting([ownGroup])
        let grouped = table.filter { leaders.contains($0.group) }.map(\.pid)
        return Array(Set(family + grouped).subtracting([root, me, 0, 1]))
    }

    private static func descendants(of pid: pid_t, children: [pid_t: [Entry]], seen: Set<pid_t>) -> [pid_t] {
        let next = (children[pid] ?? []).map(\.pid).filter { !seen.contains($0) }
        let seenNow = seen.union(next)
        return next + next.flatMap { descendants(of: $0, children: children, seen: seenNow) }
    }

    /// Asks everything `root` left running to stop now, and stops whatever's still there
    /// after `grace`. Returns at once.
    static func endDescendants(of root: pid_t, grace: Duration = .seconds(2)) {
        let marked = askToStop(under: root)
        guard !marked.isEmpty else { return }
        Task.detached {
            try? await Task.sleep(for: grace)
            stopForGood(marked)
        }
    }

    /// The same, waiting here up to `wait` before stopping what's left: for quitting,
    /// when nothing would be around later to do it.
    static func endDescendantsNow(of root: pid_t, wait: Duration = .milliseconds(300)) {
        let marked = askToStop(under: root)
        guard !marked.isEmpty else { return }
        let end = ContinuousClock.now + wait
        while ContinuousClock.now < end, !living(marked).isEmpty {
            usleep(20_000)
        }
        stopForGood(marked)
    }

    /// A process as first seen, so a pid freed in the meantime and reused by something
    /// else is never stopped.
    private struct Pair: Hashable {
        let pid: pid_t
        let group: pid_t
    }

    private static func askToStop(under root: pid_t) -> Set<Pair> {
        let table = snapshot()
        let targets = Set(targets(under: root, in: table)).union(adopted(under: root, in: table))
        let marked = Set(table.filter { targets.contains($0.pid) }.map { Pair(pid: $0.pid, group: $0.group) })
        marked.forEach { kill($0.pid, SIGTERM) }
        return marked
    }

    private static func living(_ marked: Set<Pair>) -> [Entry] {
        snapshot().filter { !$0.isZombie && marked.contains(Pair(pid: $0.pid, group: $0.group)) }
    }

    private static func stopForGood(_ marked: Set<Pair>) {
        living(marked).forEach { kill($0.pid, SIGKILL) }
    }

    /// Processes macOS holds LocalFlow (`owner`) responsible for, started since `root`,
    /// that aren't an app's or the system's helpers (which also work on LocalFlow's behalf)
    /// and aren't under another of LocalFlow's children (an Ask answer, say).
    static func adopted(under root: pid_t, in table: [Entry], owner: pid_t = getpid(),
                        responsible: (pid_t) -> pid_t? = responsiblePID,
                        path: (pid_t) -> String? = executablePath) -> [pid_t] {
        guard let since = table.first(where: { $0.pid == root })?.started else { return [] }
        let parents = Dictionary(table.map { ($0.pid, $0.parent) }) { first, _ in first }
        let others = Set(table.filter { $0.parent == owner && $0.pid != root }.map(\.pid))
        return table.filter { entry in
            guard ![owner, root, 0, 1].contains(entry.pid), !entry.isZombie, let started = entry.started,
                  started >= since, responsible(entry.pid) == owner else { return false }
            return !isUnder(others, entry.pid, parents: parents, owner: owner) && !isHelper(path(entry.pid))
        }.map(\.pid)
    }

    private static func isUnder(_ others: Set<pid_t>, _ pid: pid_t, parents: [pid_t: pid_t], owner: pid_t,
                                depth: Int = 0) -> Bool {
        if others.contains(pid) { return true }
        guard depth < 64, let parent = parents[pid], parent != owner, parent > 1 else { return false }
        return isUnder(others, parent, parents: parents, owner: owner, depth: depth + 1)
    }

    /// No path counts as a helper: when in doubt, leave it alone.
    private static func isHelper(_ path: String?) -> Bool {
        guard let path else { return true }
        return path.contains(".xpc/") || ["/System/", "/usr/libexec/", "/Library/Apple/"].contains(where: path.hasPrefix)
    }

    private typealias ResponsibleFunction = @convention(c) (pid_t) -> pid_t

    /// macOS's own record of which app a process works for (what privacy permissions are
    /// checked against). Not public API, so looked up when needed; nil if it's gone.
    private static let responsibleFunction: ResponsibleFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                                 "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: ResponsibleFunction.self)
    }()

    static func responsiblePID(_ pid: pid_t) -> pid_t? {
        guard let function = responsibleFunction else { return nil }
        let responsible = function(pid)
        return responsible > 0 ? responsible : nil
    }

    static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Every process on the Mac, with its parent and group. Tries again with more room
    /// when processes start faster than it can read them.
    static func snapshot(attempts: Int = 4) -> [Entry] {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard attempts > 0, sysctl(&name, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        // Room for processes started between the two calls.
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / stride * 5 / 4 + 64)
        var filled = processes.count * stride
        guard sysctl(&name, 3, &processes, &filled, nil, 0) == 0 else {
            return errno == ENOMEM ? snapshot(attempts: attempts - 1) : []
        }
        return processes.prefix(filled / stride).map { info in
            Entry(pid: info.kp_proc.p_pid, parent: info.kp_eproc.e_ppid, group: info.kp_eproc.e_pgid,
                  isZombie: info.kp_proc.p_stat == SZOMB,
                  started: TimeInterval(info.kp_proc.p_starttime.tv_sec)
                    + TimeInterval(info.kp_proc.p_starttime.tv_usec) / 1_000_000)
        }
    }
}
