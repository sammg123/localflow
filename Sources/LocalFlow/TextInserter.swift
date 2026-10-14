import AppKit
import Carbon.HIToolbox

enum InsertionResult: Equatable {
    case pasted
    case leftOnClipboard(reason: String)
}

/// Inserts text into the focused app the way Wispr Flow and VoiceInk do: save the
/// clipboard, write the transcript (marked concealed so clipboard managers ignore it),
/// synthesize Cmd+V, then put the user's clipboard back. A missed paste is recovered
/// with Control + hotkey (paste last transcript), never by leaving the transcript on
/// the clipboard over whatever the user had copied.
@MainActor
final class TextInserter {
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// Kept so "Paste Last Transcript" always works even when auto-paste fails.
    private(set) var lastTranscript: String?

    private let pasteboard: NSPasteboard
    private let isTrusted: () -> Bool
    private let isSecureInput: () -> Bool
    private let postPaste: () -> Void
    /// How long the target app gets to read the transcript before the old clipboard
    /// returns. Slow apps (Electron, remote desktops) read late; too short a wait
    /// pastes the user's OLD clipboard instead of the transcript.
    private let restoreDelay: Duration
    /// Inserts run one at a time. Two overlapping ones would each snapshot the
    /// clipboard, and the second would "restore" the first one's transcript.
    private var insertQueue: Task<InsertionResult, Never>?

    init(pasteboard: NSPasteboard = .general,
         isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
         isSecureInput: @escaping () -> Bool = { IsSecureEventInputEnabled() },
         postPaste: (() -> Void)? = nil,
         restoreDelay: Duration = .milliseconds(800)) {
        self.pasteboard = pasteboard
        self.isTrusted = isTrusted
        self.isSecureInput = isSecureInput
        self.postPaste = postPaste ?? { TextInserter.postCommandShortcut(CGKeyCode(kVK_ANSI_V)) }
        self.restoreDelay = restoreDelay
    }

    func insert(_ text: String) async -> InsertionResult {
        lastTranscript = text
        let previous = insertQueue
        let task = Task { @MainActor [weak self] () -> InsertionResult in
            _ = await previous?.value
            guard let self else { return .leftOnClipboard(reason: "LocalFlow is quitting") }
            return await self.performInsert(text)
        }
        insertQueue = task
        return await task.value
    }

    private func performInsert(_ text: String) async -> InsertionResult {
        guard isTrusted() else {
            copyToClipboard(text)
            return .leftOnClipboard(reason: "Accessibility permission is missing")
        }
        if isSecureInput() {
            // A password field (or terminal secure-entry) is active: synthetic paste is
            // blocked, so the clipboard is the only way to deliver it.
            copyToClipboard(text)
            return .leftOnClipboard(reason: "Secure input is active — press ⌘V to paste manually")
        }

        let saved = snapshot(of: pasteboard)
        copyToClipboard(text)
        let ourChangeCount = pasteboard.changeCount

        // Small delay so the pasteboard write settles before the target app reads it.
        try? await Task.sleep(for: .milliseconds(80))
        postPaste()

        // Restore only if nobody else wrote in the meantime, and never from an
        // incomplete snapshot.
        try? await Task.sleep(for: restoreDelay)
        if saved.complete, pasteboard.changeCount == ourChangeCount {
            restore(saved.items, to: pasteboard)
        }
        return .pasted
    }

    func copyToClipboard(_ text: String) {
        lastTranscript = text
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setString("", forType: Self.concealedType)
    }

    /// Re-paste the last transcript (Control + hotkey, or the menu). Nil when there is
    /// nothing to paste yet.
    @discardableResult
    func pasteLastTranscript() async -> InsertionResult? {
        guard let text = lastTranscript else { return nil }
        return await insert(text)
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
