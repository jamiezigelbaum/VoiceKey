import AppKit
import Carbon

final class VoiceKeyAppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var hotKey: GlobalHotKey?
    private lazy var chatGPT: ChatGPTProvider = {
        let provider = ChatGPTProvider()
        provider.onStatusChange = { [weak self] status in
            self?.updateStatus(status)
        }
        return provider
    }()
    private let statusMenuItem = NSMenuItem(title: "Status: Loading ChatGPT", action: nil, keyEquivalent: "")
    private let toggleMenuItem = NSMenuItem(title: "Start ChatGPT Voice", action: #selector(toggleChatGPTVoice), keyEquivalent: "")
    private let showMenuItem = NSMenuItem(title: "Show ChatGPT", action: #selector(showChatGPT), keyEquivalent: "")
    private let reloadMenuItem = NSMenuItem(title: "Reload ChatGPT", action: #selector(reloadChatGPT), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMenuBar()
        registerDefaultHotKey()
        chatGPT.prepare()
    }

    private func configureMenuBar() {
        statusItem.button?.title = ProviderStatus.loading.statusItemTitle

        let menu = NSMenu()
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())
        menu.addItem(toggleMenuItem)
        menu.addItem(showMenuItem)
        menu.addItem(reloadMenuItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit VoiceKey", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func registerDefaultHotKey() {
        do {
            hotKey = try GlobalHotKey(keyCode: UInt32(kVK_F16), modifiers: 0) { [weak self] in
                self?.toggleChatGPTVoice()
            }
        } catch {
            presentError("Could not register F16 hotkey: \(error.localizedDescription)")
        }
    }

    @objc private func toggleChatGPTVoice() {
        chatGPT.toggleVoice()
    }

    @objc private func showChatGPT() {
        chatGPT.show()
    }

    @objc private func reloadChatGPT() {
        chatGPT.reload()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func presentError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "VoiceKey"
        alert.informativeText = message
        alert.runModal()
    }

    private func updateStatus(_ status: ProviderStatus) {
        statusItem.button?.title = status.statusItemTitle
        statusMenuItem.title = "Status: \(status.menuTitle)"

        switch status {
        case .clickSent, .voiceActive, .stopping:
            toggleMenuItem.title = "Stop ChatGPT Voice"
        case .starting:
            toggleMenuItem.title = "Starting ChatGPT Voice..."
        default:
            toggleMenuItem.title = "Start ChatGPT Voice"
        }

        if let detail = status.detail {
            statusMenuItem.title = "Status: \(status.menuTitle) - \(detail)"
        }
    }
}
