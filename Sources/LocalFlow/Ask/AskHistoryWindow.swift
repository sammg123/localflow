import AppKit
import SwiftUI

/// The Ask Chats window: an ordinary window, so it takes the keyboard for searching and
/// stays put while you read.
@MainActor
final class AskHistoryWindowController {
    private let store: AskChatStore
    private let onContinue: (AskChat.ID) -> Void
    private var window: NSWindow?
    private let selection = SelectionBox()

    init(store: AskChatStore, onContinue: @escaping (AskChat.ID) -> Void) {
        self.store = store
        self.onContinue = onContinue
    }

    var isVisible: Bool { window?.isVisible == true }
    var frame: NSRect { window?.frame ?? .zero }
    var contentView: NSView? { window?.contentView }

    /// Opens on the current chat, or the newest one. (Tests pass `activating: false` so
    /// the window never takes the keyboard from the app you're using.)
    func show(activating: Bool = true) {
        let window = self.window ?? makeWindow()
        self.window = window
        if selection.id == nil || !store.log.chats.contains(where: { $0.id == selection.id }) {
            selection.id = store.currentChat?.id ?? store.log.chats.first?.id
        }
        guard activating else { return window.orderFrontRegardless() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }

    private func makeWindow() -> NSWindow {
        let root = HistoryRoot(store: store, selection: selection, onContinue: { [weak self] id in self?.onContinue(id) })
        let hosting = NSHostingController(rootView: root)
        hosting.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentViewController: hosting)
        window.title = "Ask Chats"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 920, height: 600))
        window.center()
        window.setFrameAutosaveName("AskChats")
        return window
    }
}

/// The selected chat, kept by the controller so reopening the window can pick one.
@MainActor
private final class SelectionBox: ObservableObject {
    @Published var id: AskChat.ID?
}

private struct HistoryRoot: View {
    @ObservedObject var store: AskChatStore
    @ObservedObject var selection: SelectionBox
    var onContinue: (AskChat.ID) -> Void

    var body: some View {
        AskHistoryView(store: store, selection: $selection.id, onContinue: onContinue)
    }
}
