import AppKit
import ServiceManagement

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private weak var controller: AppController?

    init(controller: AppController) {
        self.controller = controller
        super.init()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setIcon(recording: false)

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false // we manage isEnabled by hand in menuNeedsUpdate
        statusItem.menu = menu
    }

    func setIcon(recording: Bool) {
        guard let button = statusItem.button else { return }
        let symbolName = recording ? "mic.fill" : "mic"
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "LocalFlow")
        image?.isTemplate = true
        button.image = image
        button.contentTintColor = recording ? .systemRed : nil
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let controller else { return }
        menu.removeAllItems()

        let status = NSMenuItem(title: controller.statusLine, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let handsFree = NSMenuItem(
            title: controller.isHandsFreeWindowOpen ? "Paste Hands-Free Dictation"
                : controller.isHandsFree ? "Stop Hands-Free Dictation" : "Start Hands-Free Dictation",
            action: #selector(toggleHandsFree), keyEquivalent: ""
        )
        handsFree.target = self
        menu.addItem(handsFree)

        let shortcut = Settings.shared.hotkey.shortName.map { " (Control + \($0))" } ?? ""
        let pasteLast = NSMenuItem(title: "Paste Last Transcript\(shortcut)", action: #selector(pasteLast), keyEquivalent: "")
        pasteLast.target = self
        pasteLast.isEnabled = controller.inserter.lastTranscript != nil
        menu.addItem(pasteLast)

        // History submenu.
        let historyItem = NSMenuItem(title: "History", action: nil, keyEquivalent: "")
        let historyMenu = NSMenu()
        let entries = controller.history.entries.prefix(10)
        if entries.isEmpty {
            let empty = NSMenuItem(title: "No dictations yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            historyMenu.addItem(empty)
        } else {
            for entry in entries {
                let preview = entry.text.count > 60 ? String(entry.text.prefix(57)) + "…" : entry.text
                let item = NSMenuItem(title: preview, action: #selector(copyHistoryEntry(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry.text
                item.toolTip = entry.text
                historyMenu.addItem(item)
            }
            historyMenu.addItem(.separator())
            let clear = NSMenuItem(title: "Clear History", action: #selector(clearHistory), keyEquivalent: "")
            clear.target = self
            historyMenu.addItem(clear)
        }
        historyItem.submenu = historyMenu
        menu.addItem(historyItem)

        let chats = NSMenuItem(title: "Ask Chats…", action: #selector(openAskChats), keyEquivalent: "")
        chats.target = self
        menu.addItem(chats)

        let newChat = NSMenuItem(title: "Start New Ask Chat", action: #selector(forgetAsk), keyEquivalent: "")
        newChat.target = self
        newChat.isEnabled = controller.askHasCurrentChat
        newChat.toolTip = "Your next question starts fresh; this chat stays in Ask Chats"
        menu.addItem(newChat)

        menu.addItem(.separator())

        if !Permissions.allGranted {
            let perms = NSMenuItem(title: "⚠️ Grant Permissions…", action: #selector(openSetup), keyEquivalent: "")
            perms.target = self
            menu.addItem(perms)
        }

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let launchAtLogin = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLogin.target = self
        launchAtLogin.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(launchAtLogin)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit LocalFlow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    // MARK: - Actions

    @objc private func toggleHandsFree() { controller?.toggleHandsFree() }

    @objc private func openAskChats() { controller?.showAskChats() }

    @objc private func pasteLast() {
        controller?.pasteLastTranscript()
    }

    @objc private func copyHistoryEntry(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        controller?.inserter.copyToClipboard(text)
    }

    @objc private func clearHistory() { controller?.history.clear() }

    @objc private func forgetAsk() { controller?.forgetAskConversation() }

    @objc private func openSettings() { controller?.openSettings() }

    @objc private func openSetup() { controller?.openSettings(tab: .setup) }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("LocalFlow: launch-at-login toggle failed: \(error)")
        }
    }
}
