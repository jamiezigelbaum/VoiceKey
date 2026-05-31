import AppKit
import Carbon

final class VoiceKeyAppDelegate: NSObject, NSApplicationDelegate {
    private let voiceHotKey = HotKeyConfiguration.voiceToggle
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
    private let audioTipMenuItem = NSMenuItem(title: "Tip: Use headphones or non-speaker output to prevent voice loops", action: nil, keyEquivalent: "")
    private lazy var toggleMenuItem = NSMenuItem(
        title: "Start/End ChatGPT Voice",
        action: #selector(toggleChatGPTVoice),
        keyEquivalent: voiceHotKey.menuKeyEquivalent
    )
    private let showMenuItem = NSMenuItem(title: "Show ChatGPT", action: #selector(showChatGPT), keyEquivalent: "")
    private let reloadMenuItem = NSMenuItem(title: "Reload ChatGPT", action: #selector(reloadChatGPT), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMenuBar()
        registerDefaultHotKey()
        chatGPT.prepare()
    }

    private func configureMenuBar() {
        configureStatusItemIcon()

        let menu = NSMenu()
        statusMenuItem.isEnabled = false
        audioTipMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(audioTipMenuItem)
        menu.addItem(.separator())
        configureVoiceHotKeyMenuItem()
        menu.addItem(toggleMenuItem)
        menu.addItem(showMenuItem)
        menu.addItem(reloadMenuItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit VoiceKey", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func configureStatusItemIcon() {
        statusItem.length = NSStatusItem.squareLength
        guard let button = statusItem.button else { return }

        button.image = MenuBarIconRenderer.image(for: voiceHotKey)
        button.imagePosition = .imageOnly
        button.toolTip = "VoiceKey"
    }

    private func registerDefaultHotKey() {
        do {
            hotKey = try GlobalHotKey(keyCode: voiceHotKey.keyCode, modifiers: voiceHotKey.carbonModifiers) { [weak self] in
                self?.toggleChatGPTVoice()
            }
        } catch {
            presentError("Could not register F16 hotkey: \(error.localizedDescription)")
        }
    }

    private func configureVoiceHotKeyMenuItem() {
        toggleMenuItem.title = "Start/End ChatGPT Voice"
        toggleMenuItem.keyEquivalent = voiceHotKey.menuKeyEquivalent
        toggleMenuItem.keyEquivalentModifierMask = voiceHotKey.menuModifierMask
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
        statusItem.button?.toolTip = "VoiceKey - \(status.menuTitle)"
        statusMenuItem.title = "Status: \(status.menuTitle)"
        configureVoiceHotKeyMenuItem()

        if let detail = status.detail {
            statusMenuItem.title = "Status: \(status.menuTitle) - \(detail)"
        }
    }
}
