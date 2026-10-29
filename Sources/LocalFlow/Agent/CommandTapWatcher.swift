import AppKit
import Darwin

/// Listens, from any app, for ⌘ tapped on its own: the agent's window in its corner opens
/// its box for more. Watches at the hardware level, where shortcuts the system takes for
/// itself (⌘Tab, ⌘Space) still show the key that makes them shortcuts, and only listens:
/// no key is ever held up or swallowed. A tap that switched apps doesn't count, nor one
/// LocalFlow's own screen tools posted for the agent. Runs only while the window waits in
/// its corner.
@MainActor
final class CommandTapWatcher {
    var onTap: (() -> Void)?

    /// After the tap, how long to wait for an app switch it may have caused.
    static let settle: Duration = .milliseconds(200)

    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var monitors: [Any] = []
    private var tap = CommandTap(keys: [])
    /// The app in front when ⌘ went down.
    private var frontAtDown: pid_t?

    var isRunning: Bool { port != nil || !monitors.isEmpty }

    func start(keys: Set<UInt16>) {
        guard !isRunning else { return }
        tap = CommandTap(keys: keys)
        if !startEventTap() {
            FlowLog.shared.write("agent: no event tap for ⌘; listening with monitors")
            startMonitors()
        }
    }

    func stop() {
        if let port { CGEvent.tapEnable(tap: port, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let port { CFMachPortInvalidate(port) }
        port = nil
        source = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    private func startEventTap() -> Bool {
        let types: [CGEventType] = [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, info in
            if let info {
                let watcher = Unmanaged<CommandTapWatcher>.fromOpaque(info).takeUnretainedValue()
                MainActor.assumeIsolated { watcher.handle(type, event) }
            }
            return Unmanaged.passUnretained(event)
        }
        guard let port = CGEvent.tapCreate(tap: .cghidEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                           eventsOfInterest: mask, callback: callback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.port = port
        self.source = source
        return true
    }

    private func startMonitors() {
        let flags = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated {
                guard let cgEvent = event.cgEvent else { return }
                self?.handle(.flagsChanged, cgEvent)
            }
        }
        let others = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.tap.interrupted() }
        }
        monitors = [flags, others].compactMap { $0 }
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
        case .flagsChanged:
            guard !Self.isFromLocalFlow(event) else { return tap.interrupted() }
            let flags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            if CommandTap.isCommandOnly(flags) {
                frontAtDown = NSWorkspace.shared.frontmostApplication?.processIdentifier
            }
            if tap.flagsChanged(keyCode: keyCode, flags: flags, at: ProcessInfo.processInfo.systemUptime) {
                confirm(front: frontAtDown)
            }
        default:
            tap.interrupted()
        }
    }

    /// A tap that brought another app forward was a ⌘Tab.
    private func confirm(front: pid_t?) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.settle)
            guard let self, self.isRunning,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == front else { return }
            self.onTap?()
        }
    }

    /// Posted by another copy of LocalFlow's own program: the agent's screen tools.
    private static func isFromLocalFlow(_ event: CGEvent) -> Bool {
        let pid = pid_t(event.getIntegerValueField(.eventSourceUnixProcessID))
        guard pid > 0, pid != getpid(), let own = Bundle.main.executablePath else { return false }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        return String(cString: buffer) == own
    }
}
