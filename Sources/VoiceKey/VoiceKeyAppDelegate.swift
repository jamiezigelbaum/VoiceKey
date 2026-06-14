import AppKit
import Carbon

final class VoiceKeyAppDelegate: NSObject, NSApplicationDelegate {
    private var voiceHotKey = HotKeyConfiguration.voiceToggle
    private var providerConfiguration = VoiceProviderSettingsStore.load()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var hotKey: GlobalHotKey?
    private var currentStatus: ProviderStatus = .loading
    private var settingsWindowController: SettingsWindowController?
    private var voiceProvider: RealtimeVoiceProvider?
    private let statusMenuItem = NSMenuItem(title: "Status: Loading", action: nil, keyEquivalent: "")
    private let providerMenuItem = NSMenuItem(title: "Provider: OpenAI Realtime", action: nil, keyEquivalent: "")
    private let audioTipMenuItem = NSMenuItem(title: "Tip: Use headphones or non-speaker output to prevent voice loops", action: nil, keyEquivalent: "")
    private lazy var toggleMenuItem = NSMenuItem(
        title: "Start/End VoiceKey Voice",
        action: #selector(toggleVoice),
        keyEquivalent: voiceHotKey.menuKeyEquivalent
    )
    private let settingsMenuItem = NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ",")

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureApplicationMenu()
        configureMenuBar()
        registerHotKey(voiceHotKey, previousHotKeyName: nil)
        configureProvider()
        voiceProvider?.prepare()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func configureApplicationMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "VoiceKey")
        appMenu.addItem(NSMenuItem(title: "Quit VoiceKey", action: #selector(quit), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApplication.shared.mainMenu = mainMenu
    }

    private func configureMenuBar() {
        configureStatusItemIcon()

        let menu = NSMenu()
        statusMenuItem.isEnabled = false
        providerMenuItem.isEnabled = false
        audioTipMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(providerMenuItem)
        menu.addItem(audioTipMenuItem)
        menu.addItem(.separator())
        configureVoiceHotKeyMenuItem()
        menu.addItem(toggleMenuItem)
        settingsMenuItem.keyEquivalentModifierMask = [.command]
        menu.addItem(settingsMenuItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit VoiceKey", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func configureStatusItemIcon() {
        statusItem.length = 38
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
                self?.toggleVoice()
            }
            return true
        } catch {
            let fallback = previousHotKeyName.map { " VoiceKey restored \($0)." } ?? ""
            presentError("Could not register \(configuration.displayName): \(error.localizedDescription).\(fallback)")
            return false
        }
    }

    private func configureVoiceHotKeyMenuItem() {
        toggleMenuItem.title = "Start/End VoiceKey Voice"
        toggleMenuItem.keyEquivalent = voiceHotKey.menuKeyEquivalent
        toggleMenuItem.keyEquivalentModifierMask = voiceHotKey.menuModifierMask
    }

    private func configureProvider() {
        let provider: RealtimeVoiceProvider
        switch providerConfiguration.providerID {
        case .openAIRealtime:
            provider = OpenAIRealtimeProvider(
                configuration: providerConfiguration,
                apiKeyProvider: { APIKeyStore.shared.apiKey(for: .openAIRealtime) }
            )
        case .geminiLive, .deepgramVoiceAgent:
            provider = UnavailableVoiceProvider(id: providerConfiguration.providerID)
        }

        provider.onEvent = { [weak self] event in
            switch event {
            case let .status(status):
                self?.updateStatus(status)
            case let .diagnostic(message):
                self?.statusMenuItem.toolTip = message
            case .transcript:
                break
            }
        }

        voiceProvider = provider
        providerMenuItem.title = "Provider: \(providerConfiguration.providerID.displayName)"
    }

    @objc private func toggleVoice() {
        voiceProvider?.toggleVoice()
    }

    @objc private func showSettings() {
        let controller = settingsWindowController ?? SettingsWindowController(
            hotKey: voiceHotKey,
            configuration: providerConfiguration
        )
        controller.delegate = self
        controller.hotKey = voiceHotKey
        controller.configuration = providerConfiguration
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
        providerMenuItem.title = "Provider: \(providerConfiguration.providerID.displayName)"
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

    private func updateProviderConfiguration(_ configuration: VoiceSessionConfiguration) {
        providerConfiguration = configuration
        VoiceProviderSettingsStore.save(configuration)

        if voiceProvider?.id == configuration.providerID {
            voiceProvider?.update(configuration: configuration)
        } else {
            voiceProvider?.stopVoice()
            configureProvider()
            voiceProvider?.prepare()
        }
        updateHotKeyPresentation()
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

    func settingsWindowController(
        _ controller: SettingsWindowController,
        didUpdate configuration: VoiceSessionConfiguration
    ) {
        updateProviderConfiguration(configuration)
    }

    func settingsWindowControllerDidUpdateAPIKey(_ controller: SettingsWindowController) {
        voiceProvider?.prepare()
    }
}
