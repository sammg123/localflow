import AppKit
import Carbon.HIToolbox

enum InsertionResult {
    case pasted
    case leftOnClipboard(reason: String)
}

/// Inserts text into the focused app the way Wispr Flow and VoiceInk do:
/// save clipboard -> write transcript (marked concealed so clipboard managers ignore it)
/// -> synthesize Cmd+V -> restore the previous clipboard.
@MainActor
final class TextInserter {
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// Kept so "Paste Last Transcript" always works even when auto-paste fails.
    private(set) var lastTranscript: String?

    func insert(_ text: String) async -> InsertionResult {
        lastTranscript = text

        guard AXIsProcessTrusted() else {
            copyToClipboard(text)
            return .leftOnClipboard(reason: "Accessibility permission is missing")
        }
        if IsSecureEventInputEnabled() {
            // A password field (or terminal secure-entry) is active: synthetic paste is blocked.
            copyToClipboard(text)
            return .leftOnClipboard(reason: "Secure input is active — press ⌘V to paste manually")
        }

        let pasteboard = NSPasteboard.general
        let saved = snapshot(of: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setString("", forType: Self.concealedType)
        let ourChangeCount = pasteboard.changeCount

        // Small delay so the pasteboard write settles before the target app reads it.
        try? await Task.sleep(for: .milliseconds(80))
        postCmdV()

        // Give the target app time to consume the pasteboard, then restore — slow apps
        // (Electron, remote desktops) read it late, and restoring early would paste the
        // user's OLD clipboard instead of the transcript. Restore only if nobody else
        // wrote in the meantime, and never from an incomplete snapshot.
        try? await Task.sleep(for: .milliseconds(600))
        if saved.complete, pasteboard.changeCount == ourChangeCount {
            restore(saved.items, to: pasteboard)
        }
        return .pasted
    }

    func copyToClipboard(_ text: String) {
        lastTranscript = text
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Re-paste the last transcript (menu action / recovery path).
    func pasteLastTranscript() async {
        guard let text = lastTranscript else { return }
        _ = await insert(text)
    }

    // MARK: - Selection capture (command mode)

    /// Reads the target app's current selection via a synthetic Cmd+C, restoring the
    /// user's clipboard afterwards. Returns nil when nothing is selected (no app writes
    /// the pasteboard for an empty copy) or capture isn't possible.
    func captureSelection() async -> String? {
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled() else { return nil }

        let pasteboard = NSPasteboard.general
        let saved = snapshot(of: pasteboard)
        pasteboard.clearContents()
        let baseline = pasteboard.changeCount

        postCommandShortcut(CGKeyCode(kVK_ANSI_C))

        // Poll briefly: slow apps (Electron) take a beat to service the copy.
        var selection: String?
        for _ in 0..<12 {
            try? await Task.sleep(for: .milliseconds(50))
            if pasteboard.changeCount != baseline {
                selection = pasteboard.string(forType: .string)
                break
            }
        }
        if saved.complete {
            restore(saved.items, to: pasteboard)
        }
        guard let selection, !selection.isEmpty else { return nil }
        return selection
    }

    // MARK: - Shortcut synthesis

    private func postCmdV() {
        postCommandShortcut(CGKeyCode(kVK_ANSI_V))
    }

    private func postCommandShortcut(_ virtualKey: CGKeyCode) {
        guard let source = CGEventSource(stateID: .privateState) else { return }

        // Match VoiceInk's timing: discrete events, ~10ms apart, posted to the HID tap.
        let events: [(CGKeyCode, Bool, CGEventFlags)] = [
            (CGKeyCode(kVK_Command), true, .maskCommand),
            (virtualKey, true, .maskCommand),
            (virtualKey, false, .maskCommand),
            (CGKeyCode(kVK_Command), false, []),
        ]
        for (key, down, flags) in events {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
            usleep(10_000)
        }
    }

    // MARK: - Clipboard save/restore

    private struct SavedItem {
        /// Ordered as the original item declared them: type order is fidelity order.
        var data: [(type: NSPasteboard.PasteboardType, data: Data)]
    }

    private struct Snapshot {
        var items: [SavedItem]
        /// False if anything was too big to capture — restoring a partial clipboard
        /// (e.g. an image's PNG without its TIFF) is worse than not restoring.
        var complete: Bool
    }

    /// Total memory budget for the snapshot (8 GB machine; huge copies aren't worth
    /// holding in RAM for the ~1s between paste and restore).
    private static let snapshotBudget = 128 * 1024 * 1024

    private func snapshot(of pasteboard: NSPasteboard) -> Snapshot {
        guard let items = pasteboard.pasteboardItems else { return Snapshot(items: [], complete: true) }
        var saved: [SavedItem] = []
        var budget = Self.snapshotBudget
        for item in items {
            var payload: [(NSPasteboard.PasteboardType, Data)] = []
            for type in item.types {
                guard let data = item.data(forType: type) else { continue }
                guard data.count <= budget else {
                    return Snapshot(items: [], complete: false)
                }
                budget -= data.count
                payload.append((type, data))
            }
            if !payload.isEmpty {
                saved.append(SavedItem(data: payload))
            }
        }
        return Snapshot(items: saved, complete: true)
    }

    private func restore(_ saved: [SavedItem], to pasteboard: NSPasteboard) {
        guard !saved.isEmpty else {
            pasteboard.clearContents()
            return
        }
        pasteboard.clearContents()
        let items: [NSPasteboardItem] = saved.map { savedItem in
            let item = NSPasteboardItem()
            for (type, data) in savedItem.data {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(items)
    }
}
