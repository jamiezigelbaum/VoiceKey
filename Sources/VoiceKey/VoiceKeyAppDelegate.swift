import AppKit
import Carbon

final class VoiceKeyAppDelegate: NSObject, NSApplicationDelegate {
    private var voiceHotKey = HotKeyConfiguration.voiceToggle
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var hotKey: GlobalHotKey?
    private var currentStatus: ProviderStatus = .loading
    private var settingsWindowController: SettingsWindowController?
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
    private let settingsMenuItem = NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ",")

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMenuBar()
        registerHotKey(voiceHotKey, previousHotKeyName: nil)
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
        settingsMenuItem.keyEquivalentModifierMask = [.command]
        menu.addItem(settingsMenuItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit VoiceKey", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func configureStatusItemIcon() {
        statusItem.length = NSStatusItem.squareLength
        guard let button = statusItem.button else { return }

        button.image = MenuBarIconRenderer.image(for: voiceHotKey, status: currentStatus)
        button.imagePosition = .imageOnly
        button.toolTip = "VoiceKey"
    }

    @discardableResult
    private func registerHotKey(_ configuration: HotKeyConfiguration, previousHotKeyName: String?) -> Bool {
        hotKey = nil

        do {
            hotKey = try GlobalHotKey(keyCode: configuration.keyCode, modifiers: configuration.carbonModifiers) { [weak self] in
                self?.toggleChatGPTVoice()
            }
            return true
        } catch {
            let fallback = previousHotKeyName.map { " VoiceKey restored \($0)." } ?? ""
            presentError("Could not register \(configuration.displayName): \(error.localizedDescription).\(fallback)")
            return false
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

    @objc private func showSettings() {
        let controller = settingsWindowController ?? SettingsWindowController(hotKey: voiceHotKey)
        controller.delegate = self
        controller.hotKey = voiceHotKey
        settingsWindowController = controller
        controller.showAndFocus()
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
        currentStatus = status
        statusItem.button?.toolTip = "VoiceKey - \(status.menuTitle)"
        statusMenuItem.title = "Status: \(status.menuTitle)"
        updateHotKeyPresentation()

        if let detail = status.detail {
            statusMenuItem.title = "Status: \(status.menuTitle) - \(detail)"
        }
    }

    private func updateHotKeyPresentation() {
        configureVoiceHotKeyMenuItem()
        settingsWindowController?.hotKey = voiceHotKey
        statusItem.button?.image = MenuBarIconRenderer.image(for: voiceHotKey, status: currentStatus)
    }
}

extension VoiceKeyAppDelegate: SettingsWindowControllerDelegate {
    func settingsWindowController(
        _ controller: SettingsWindowController,
        didRecord hotKey: HotKeyConfiguration
    ) {
        let previousHotKey = voiceHotKey
        voiceHotKey = hotKey

        guard registerHotKey(hotKey, previousHotKeyName: previousHotKey.displayName) else {
            voiceHotKey = previousHotKey
            _ = registerHotKey(previousHotKey, previousHotKeyName: nil)
            updateHotKeyPresentation()
            return
        }

        hotKey.saveAsVoiceToggle()
        updateHotKeyPresentation()
    }
}
