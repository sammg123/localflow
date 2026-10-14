import AppKit
import Carbon.HIToolbox

enum InsertionResult: Equatable {
    case pasted
    case leftOnClipboard(reason: String)
}

/// Inserts text into the focused app: write the transcript to the clipboard, then
/// synthesize Cmd+V. The transcript is deliberately LEFT on the clipboard afterwards
/// (marked concealed, so clipboard-history managers don't archive every dictation),
/// so when a paste misses (wrong field, an app that ignores synthetic keys, focus that
/// moved) a plain ⌘V anywhere still delivers it. Restoring the old clipboard used to
/// race slow apps (Electron reads late) and could paste the user's previous clipboard.
@MainActor
final class TextInserter {
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// Kept so "Paste Last Transcript" always works even when auto-paste fails.
    private(set) var lastTranscript: String?

    private let pasteboard: NSPasteboard
    private let isTrusted: () -> Bool
    private let isSecureInput: () -> Bool
    private let postPaste: () -> Void

    init(pasteboard: NSPasteboard = .general,
         isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
         isSecureInput: @escaping () -> Bool = { IsSecureEventInputEnabled() },
         postPaste: (() -> Void)? = nil) {
        self.pasteboard = pasteboard
        self.isTrusted = isTrusted
        self.isSecureInput = isSecureInput
        self.postPaste = postPaste ?? { TextInserter.postCommandShortcut(CGKeyCode(kVK_ANSI_V)) }
    }

    func insert(_ text: String) async -> InsertionResult {
        copyToClipboard(text)

        guard isTrusted() else {
            return .leftOnClipboard(reason: "Accessibility permission is missing")
        }
        if isSecureInput() {
            // A password field (or terminal secure-entry) is active: synthetic paste is blocked.
            return .leftOnClipboard(reason: "Secure input is active — press ⌘V to paste manually")
        }

        // Small delay so the pasteboard write settles before the target app reads it.
        try? await Task.sleep(for: .milliseconds(80))
        postPaste()
        return .pasted
    }

    func copyToClipboard(_ text: String) {
        lastTranscript = text
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setString("", forType: Self.concealedType)
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
        guard isTrusted(), !isSecureInput() else { return nil }

        let saved = snapshot(of: pasteboard)
        pasteboard.clearContents()
        let baseline = pasteboard.changeCount

        Self.postCommandShortcut(CGKeyCode(kVK_ANSI_C))

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

    private static func postCommandShortcut(_ virtualKey: CGKeyCode) {
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
