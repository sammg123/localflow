import AppKit
import Foundation

/// Mouse events queued for a window on the real screen in this process: the real pointer
/// never moves and no other app sees them. A window under test reads the pointer from
/// `location`, which goes where each event is.
@MainActor
final class ScreenMouse {
    var location = CGPoint.zero

    /// Presses at `start`, moves in steps the way a hand does, lets go.
    func drag(_ window: NSWindow, from start: NSPoint, by delta: CGVector) {
        press(.leftMouseDown, at: start, in: window)
        for step in 1...20 {
            let fraction = CGFloat(step) / 20
            press(.leftMouseDragged, at: NSPoint(x: start.x + delta.dx * fraction, y: start.y + delta.dy * fraction),
                  in: window)
        }
        press(.leftMouseUp, at: NSPoint(x: start.x + delta.dx, y: start.y + delta.dy), in: window)
        pump(0.5) // a snap glides for 0.2 s
    }

    /// A press and release in place.
    func click(_ point: NSPoint, in window: NSWindow) {
        press(.leftMouseDown, at: point, in: window)
        press(.leftMouseUp, at: point, in: window)
        pump(0.5)
    }

    /// One mouse event, handled before the next.
    func press(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) {
        queue(type, at: point, in: window)
        pump(0.02)
    }

    /// A mouse event at a screen point (AppKit coordinates), queued for the window where it
    /// is now, as the window server would; the pointer moves there.
    func queue(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) {
        location = point
        let event = NSEvent.mouseEvent(
            with: type, location: window.convertPoint(fromScreen: point), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
        guard let event else { return }
        // Posted from inside the pump's loop: posting wakes the main loop by stopping it,
        // and from out here it would stop the test runner's own, ending the run unreported.
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
            NSApp.postEvent(event, atStart: false)
        }
    }

    /// Runs `body` on the next pump, inside its loop: for what wakes the main loop by
    /// stopping it, such as putting away a window that has the keyboard.
    func perform(_ body: @escaping @MainActor () -> Void) {
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
            MainActor.assumeIsolated(body)
        }
    }

    /// Handles events for `seconds`, inside a run of the main loop of its own: AppKit stops
    /// the loop to wake it (a text view does on mouse down), and a stop out here would end the
    /// test runner's own loop, so the process exits before it reports.
    func pump(_ seconds: TimeInterval) {
        let main = CFRunLoopGetMain()
        CFRunLoopPerformBlock(main, CFRunLoopMode.defaultMode.rawValue) {
            MainActor.assumeIsolated {
                let until = Date(timeIntervalSinceNow: seconds)
                while Date() < until {
                    if let event = NSApp.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.01),
                                                   inMode: .default, dequeue: true) {
                        NSApp.sendEvent(event)
                    }
                }
            }
            CFRunLoopStop(main)
        }
        CFRunLoopRunInMode(.defaultMode, seconds + 5, false)
    }
}
