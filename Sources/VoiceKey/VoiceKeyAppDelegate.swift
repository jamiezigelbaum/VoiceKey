import AppKit
import AVFoundation

final class VoiceKeyAppDelegate: NSObject, NSApplicationDelegate {
    private static let hotKeyDebounceInterval: TimeInterval = 0.25
    private static let hasOpenedSettingsKey = "HasOpenedSettings.v1"
    private static let microphonePrivacySettingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"

    private var profiles: [VoiceProfile] = VoiceProfileStore.load()
    private var providerConfiguration = VoiceSessionConfiguration.default
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var hotKeys: [UUID: GlobalHotKey] = [:]
    private var carbonRegisteredProfileIDs: Set<UUID> = []
    private var lastTrigger: [UUID: TimeInterval] = [:]
    private var activeProfileID: UUID?
    private var currentStatus: ProviderStatus = .loading
    private var settingsWindowController: SettingsWindowController?
    private var sessionLogWindowController: SessionLogWindowController?
    private var voiceProvider: RealtimeVoiceProvider?
    private var sessionLog = VoiceSessionLog()
    private var localHotKeyMonitor: Any?
    private var globalHotKeyMonitor: Any?
    private let iconAnimator = MenuBarIconAnimator()
    private let statusMenuItem = NSMenuItem(title: "Status: Loading", action: nil, keyEquivalent: "")
    private var profileMenuItems: [UUID: NSMenuItem] = [:]
    private let checkProviderConnectionMenuItem = NSMenuItem(
        title: "Check API Connection",
        action: #selector(checkProviderConnection),
        keyEquivalent: ""
    )
    private let troubleshootingMenuItem = NSMenuItem(title: "Troubleshooting", action: nil, keyEquivalent: "")
    private let troubleshootingMenu = NSMenu(title: "Troubleshooting")
    private let showProviderMenuItem = NSMenuItem(
        title: "Show Provider Interface",
        action: #selector(showProvider),
        keyEquivalent: ""
    )
    private let reloadProviderMenuItem = NSMenuItem(
        title: "Reload Provider Interface",
        action: #selector(reloadProvider),
        keyEquivalent: ""
    )
    private let showSessionLogMenuItem = NSMenuItem(title: "Show Session Log", action: #selector(showSessionLog), keyEquivalent: "")
    private let copySessionLogMenuItem = NSMenuItem(title: "Copy Session Log", action: #selector(copySessionLog), keyEquivalent: "")
    private let clearSessionLogMenuItem = NSMenuItem(title: "Clear Session Log", action: #selector(clearSessionLog), keyEquivalent: "")
    private let copyDiagnosticsMenuItem = NSMenuItem(title: "Copy Diagnostics", action: #selector(copyDiagnostics), keyEquivalent: "")
    private let settingsMenuItem = NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ",")

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let selectedProfile {
            providerConfiguration = sessionConfiguration(for: selectedProfile)
        }
        configureApplicationMenu()
        configureMenuBar()
        registerAllHotKeys()
        configureProvider()
        voiceProvider?.prepare()
        openSettingsOnFirstRunIfNeeded()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private var selectedProfile: VoiceProfile? {
        if let activeProfileID,
           let activeProfile = profiles.first(where: { $0.id == activeProfileID }) {
            return activeProfile
        }
        return profiles.first
    }

    private func sessionConfiguration(for profile: VoiceProfile) -> VoiceSessionConfiguration {
        VoiceSessionConfiguration(
            providerID: profile.providerID,
            model: profile.model,
            voice: profile.voice,
            instructions: profile.instructions,
            endpointURL: profile.endpointURL
        )
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
        rebuildMenu()
    }

    private func rebuildMenu() {
        // Shared menu items move between menu instances; detach them from the
        // previous menu first because NSMenu refuses items owned by another menu.
        for item in [statusMenuItem, checkProviderConnectionMenuItem, troubleshootingMenuItem, settingsMenuItem] {
            item.menu?.removeItem(item)
        }

        let menu = NSMenu()
        menu.autoenablesItems = false

        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())

        profileMenuItems.removeAll()
        for profile in profiles {
            let item = NSMenuItem(title: "", action: #selector(activateProfileMenuItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = profile.id
            profileMenuItems[profile.id] = item
            menu.addItem(item)
        }
        if profiles.isEmpty == false {
            menu.addItem(.separator())
        }

        checkProviderConnectionMenuItem.target = self
        menu.addItem(checkProviderConnectionMenuItem)
        menu.addItem(.separator())

        troubleshootingMenu.autoenablesItems = false
        troubleshootingMenu.removeAllItems()
        for item in [
            showProviderMenuItem,
            reloadProviderMenuItem,
            showSessionLogMenuItem,
            copySessionLogMenuItem,
            clearSessionLogMenuItem,
            copyDiagnosticsMenuItem
        ] {
            item.target = self
            troubleshootingMenu.addItem(item)
        }
        troubleshootingMenuItem.submenu = troubleshootingMenu
        menu.addItem(troubleshootingMenuItem)

        settingsMenuItem.target = self
        settingsMenuItem.keyEquivalentModifierMask = [.command]
        menu.addItem(settingsMenuItem)

        let quitMenuItem = NSMenuItem(title: "Quit VoiceKey", action: #selector(quit), keyEquivalent: "q")
        quitMenuItem.target = self
        menu.addItem(quitMenuItem)

        statusItem.menu = menu
        updateMenuContent()
        updateStatusItemTooltip()
    }

    private func configureStatusItemIcon() {
        statusItem.length = 38
        statusItem.button?.imagePosition = .imageOnly

        iconAnimator.onFrame = { [weak self] phase in
            self?.renderStatusItemIcon(phase: phase)
        }
        renderStatusItemIcon(phase: 0)
        updateIconAnimation()
        updateStatusItemTooltip()
    }

    private func renderStatusItemIcon(phase: Double) {
        statusItem.button?.image = MenuBarIconRenderer.image(
            state: MenuBarIconState(status: currentStatus),
            phase: phase
        )
    }

    private func updateIconAnimation() {
        switch MenuBarIconState(status: currentStatus) {
        case .loading, .active, .listening, .thinking, .speaking:
            iconAnimator.start()
        case .problem, .ready:
            iconAnimator.stop()
            renderStatusItemIcon(phase: 0)
        }
    }

    private func updateStatusItemTooltip() {
        var tooltip = currentStatus.menuTitle
        if let detail = currentStatus.detail {
            tooltip += " - \(detail)"
        }
        let profileDescriptions = profiles.map { profile in
            "\(profile.name) (\(profile.hotKey?.displayName ?? "no hotkey"))"
        }
        if profileDescriptions.isEmpty == false {
            tooltip += " — " + profileDescriptions.joined(separator: ", ")
        }
        statusItem.button?.toolTip = tooltip
    }

    private func registerAllHotKeys() {
        hotKeys.removeAll()
        carbonRegisteredProfileIDs.removeAll()
        removeHotKeyMonitors()
        installHotKeyMonitors()

        for profile in profiles where profile.hotKey != nil {
            registerHotKey(for: profile.id)
        }
    }

    @discardableResult
    private func registerHotKey(for profileID: UUID) -> Bool {
        hotKeys[profileID] = nil
        carbonRegisteredProfileIDs.remove(profileID)

        guard let profile = profiles.first(where: { $0.id == profileID }),
              let configuration = profile.hotKey else {
            return false
        }

        guard let globalHotKey = GlobalHotKey(
            id: carbonHotKeyID(for: profileID),
            configuration: configuration,
            handler: { [weak self] in
                self?.triggerHotKey(for: profileID)
            }
        ) else {
            recordProviderEvent(.diagnostic(
                "Hotkey \(configuration.displayName) for profile \"\(profile.name)\" could not be registered with Carbon; event monitor fallback active."
            ))
            return false
        }

        hotKeys[profileID] = globalHotKey
        carbonRegisteredProfileIDs.insert(profileID)
        return true
    }

    private func carbonHotKeyID(for profileID: UUID) -> UInt32 {
        let uuid = profileID.uuid
        let bytes = [
            uuid.0, uuid.1, uuid.2, uuid.3, uuid.4, uuid.5, uuid.6, uuid.7,
            uuid.8, uuid.9, uuid.10, uuid.11, uuid.12, uuid.13, uuid.14, uuid.15
        ]
        var hash: UInt32 = 0x811C9DC5
        for byte in bytes {
            hash = (hash ^ UInt32(byte)) &* 0x01000193
        }
        return hash & 0x7FFFFFFF
    }

    private func installHotKeyMonitors() {
        localHotKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let profileID = self.profileID(matchingKeyEvent: event) else {
                return event
            }
            self.triggerHotKey(for: profileID)
            return nil
        }

        globalHotKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let profileID = self?.profileID(matchingKeyEvent: event) else { return }
            self?.triggerHotKey(for: profileID)
        }
    }

    private func profileID(matchingKeyEvent event: NSEvent) -> UUID? {
        profiles.first(where: { profile in
            profile.hotKey?.matches(keyCode: event.keyCode, modifierFlags: event.modifierFlags) == true
        })?.id
    }

    private func removeHotKeyMonitors() {
        if let localHotKeyMonitor {
            NSEvent.removeMonitor(localHotKeyMonitor)
            self.localHotKeyMonitor = nil
        }
        if let globalHotKeyMonitor {
            NSEvent.removeMonitor(globalHotKeyMonitor)
            self.globalHotKeyMonitor = nil
        }
    }

    private func triggerHotKey(for profileID: UUID) {
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastTrigger[profileID], now - last < Self.hotKeyDebounceInterval {
            return
        }
        lastTrigger[profileID] = now
        DispatchQueue.main.async { [weak self] in
            self?.activate(profileID: profileID)
        }
    }

    @objc private func activateProfileMenuItem(_ sender: NSMenuItem) {
        guard let profileID = sender.representedObject as? UUID else { return }
        activate(profileID: profileID)
    }

    private func activate(profileID: UUID) {
        guard let profile = profiles.first(where: { $0.id == profileID }) else { return }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted:
            presentMicrophoneAccessAlert()
            return
        case .authorized, .notDetermined:
            break
        @unknown default:
            break
        }

        guard isProfileReadyForVoice(profile) else { return }

        if activeProfileID == profile.id {
            voiceProvider?.toggleVoice()
            return
        }

        // Switching profiles: always stop the current session first. stopVoice is
        // safe on an idle provider, while gating the stop on the last reported
        // status could skip it (statuses arrive asynchronously) and abandon a
        // running audio engine.
        voiceProvider?.stopVoice()

        activeProfileID = profile.id
        updateProviderConfiguration(sessionConfiguration(for: profile))
        voiceProvider?.toggleVoice()
    }

    private func isProfileReadyForVoice(_ profile: VoiceProfile) -> Bool {
        if profile.providerID == .custom {
            guard profile.endpointURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                updateStatus(.needsAttention("Set the endpoint URL in Settings"))
                return false
            }
            return true
        }

        // OpenClaw resolves its gateway token and endpoint candidates at connect
        // time and surfaces its own needsAttention statuses, so no Settings gate.
        if profile.providerID == .openClaw {
            return true
        }

        let readiness = profile.providerID.readiness(
            hasAPIKey: APIKeyStore.shared.hasAPIKey(for: profile.providerID)
        )
        guard readiness.allowsVoiceToggle else {
            updateStatus(.needsAttention(readiness.settingsMessage))
            return false
        }
        return true
    }

    private func presentMicrophoneAccessAlert() {
        let alert = NSAlert()
        alert.messageText = "VoiceKey Needs Microphone Access"
        alert.informativeText = "Microphone access is turned off for VoiceKey, so voice conversations cannot start. Turn on microphone access in System Settings, then try again."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn,
              let url = URL(string: Self.microphonePrivacySettingsURL) else { return }
        _ = NSWorkspace.shared.open(url)
    }

    private func configureProvider() {
        // Never replace a provider without stopping it first: an abandoned provider
        // keeps its audio engine (microphone + playback) and WebSocket alive.
        voiceProvider?.stopVoice()

        let provider = VoiceProviderFactory.makeProvider(for: providerConfiguration)
        provider.onEvent = { [weak self] event in
            self?.recordProviderEvent(event)
            switch event {
            case let .status(status):
                self?.updateStatus(status)
            case let .diagnostic(message):
                self?.statusMenuItem.toolTip = message
            case let .transcript(delta):
                self?.statusMenuItem.toolTip = delta
            }
        }

        voiceProvider = provider
        updateMenuContent()
    }

    private func updateProviderConfiguration(_ configuration: VoiceSessionConfiguration) {
        providerConfiguration = configuration

        if voiceProvider?.id == configuration.providerID {
            voiceProvider?.update(configuration: configuration)
        } else {
            // configureProvider() stops the outgoing provider before replacing it.
            configureProvider()
            voiceProvider?.prepare()
        }
        updateMenuContent()
    }

    @objc private func showProvider() {
        voiceProvider?.showProviderInterface()
    }

    @objc private func reloadProvider() {
        voiceProvider?.reloadProviderInterface()
    }

    @objc private func checkProviderConnection() {
        guard let profile = selectedProfile else { return }

        if profile.providerID == .custom,
           profile.endpointURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updateStatus(.needsAttention("Set the endpoint URL in Settings"))
            return
        }

        let provider = profile.providerID
        let readiness = provider.readiness(hasAPIKey: APIKeyStore.shared.hasAPIKey(for: provider))
        guard readiness == .ready else {
            updateStatus(.needsAttention(readiness.settingsMessage))
            return
        }

        guard let connectionCheckingProvider = voiceProvider as? VoiceProviderConnectionChecking else {
            updateStatus(.needsAttention("Connection check is not available for \(provider.displayName)."))
            return
        }

        connectionCheckingProvider.checkConnection()
    }

    @objc private func showSessionLog() {
        let controller = sessionLogWindowController ?? SessionLogWindowController(text: sessionLog.displayText)
        sessionLogWindowController = controller
        controller.update(text: sessionLog.displayText)
        controller.showAndFocus()
    }

    @objc private func copySessionLog() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sessionLog.displayText, forType: .string)
        flashConfirmation("Session log copied to clipboard.", on: copySessionLogMenuItem)
    }

    @objc private func clearSessionLog() {
        sessionLog.clear()
        sessionLogWindowController?.update(text: sessionLog.displayText)
        updateMenuContent()
    }

    @objc private func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnosticsSnapshot().displayText, forType: .string)
        flashConfirmation("Diagnostics copied to clipboard.", on: copyDiagnosticsMenuItem)
    }

    private func flashConfirmation(_ message: String, on menuItem: NSMenuItem) {
        menuItem.toolTip = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak menuItem] in
            menuItem?.toolTip = nil
        }
    }

    @objc private func showSettings() {
        let controller = settingsWindowController ?? SettingsWindowController(profiles: profiles)
        controller.delegate = self
        controller.profiles = profiles
        settingsWindowController = controller
        controller.showAndFocus()
    }

    private func openSettingsOnFirstRunIfNeeded() {
        guard VoiceProfileStore.isFreshInstall(),
              UserDefaults.standard.bool(forKey: Self.hasOpenedSettingsKey) == false else { return }
        UserDefaults.standard.set(true, forKey: Self.hasOpenedSettingsKey)
        DispatchQueue.main.async { [weak self] in
            self?.showSettings()
        }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func updateStatus(_ status: ProviderStatus) {
        currentStatus = status
        statusMenuItem.title = "Status: \(status.menuTitle)"
        if let detail = status.detail {
            statusMenuItem.title = "Status: \(status.menuTitle) - \(detail)"
        }
        updateIconAnimation()
        updateStatusItemTooltip()
        updateMenuContent()
    }

    private func profileMenuTitle(for profile: VoiceProfile) -> String {
        guard profile.id == activeProfileID else {
            return "Start \(profile.name)"
        }
        switch currentStatus {
        case .starting, .listening, .thinking, .speaking, .clickSent, .voiceActive:
            return "Stop \(profile.name)"
        case .stopping:
            return "Stopping \(profile.name)"
        default:
            return "Start \(profile.name)"
        }
    }

    private func isProfileMenuItemEnabled(for profile: VoiceProfile) -> Bool {
        profile.id != activeProfileID || currentStatus != .stopping
    }

    private func updateMenuContent() {
        for profile in profiles {
            guard let item = profileMenuItems[profile.id] else { continue }
            item.title = profileMenuTitle(for: profile)
            item.isEnabled = isProfileMenuItemEnabled(for: profile)
            if let hotKey = profile.hotKey {
                item.keyEquivalent = hotKey.menuKeyEquivalent
                item.keyEquivalentModifierMask = hotKey.menuModifierMask
            } else {
                item.keyEquivalent = ""
                item.keyEquivalentModifierMask = []
            }
        }

        let state = providerMenuState()
        showProviderMenuItem.isEnabled = state.isProviderInterfaceEnabled
        reloadProviderMenuItem.isEnabled = state.isProviderInterfaceEnabled

        let provider = selectedProfile?.providerID ?? providerConfiguration.providerID
        if state.isProviderInterfaceEnabled {
            showProviderMenuItem.title = "Show Provider Interface"
            reloadProviderMenuItem.title = "Reload Provider Interface"
        } else if provider.isImplemented {
            showProviderMenuItem.title = "Show Provider Interface (API provider)"
            reloadProviderMenuItem.title = "Reload Provider Interface (API provider)"
        } else {
            showProviderMenuItem.title = "Show Provider Interface (coming soon)"
            reloadProviderMenuItem.title = "Reload Provider Interface (coming soon)"
        }

        checkProviderConnectionMenuItem.title = state.checkConnectionTitle
        checkProviderConnectionMenuItem.isEnabled = state.isCheckConnectionEnabled
        copySessionLogMenuItem.isEnabled = state.isCopySessionLogEnabled
        clearSessionLogMenuItem.isEnabled = state.isClearSessionLogEnabled
    }

    private func providerMenuState() -> VoiceProviderMenuState {
        let provider = selectedProfile?.providerID ?? providerConfiguration.providerID
        return VoiceProviderMenuState(
            provider: provider,
            readiness: provider.readiness(hasAPIKey: APIKeyStore.shared.hasAPIKey(for: provider)),
            currentStatus: currentStatus,
            supportsProviderInterface: voiceProvider?.capabilities.supportsProviderInterface == true,
            supportsConnectionCheck: voiceProvider?.capabilities.supportsConnectionCheck == true,
            hasSessionLog: sessionLog.isEmpty == false
        )
    }

    private func diagnosticsSnapshot() -> VoiceKeyDiagnosticsSnapshot {
        let provider = selectedProfile?.providerID ?? providerConfiguration.providerID
        return VoiceKeyDiagnosticsSnapshot(
            provider: provider,
            configuration: providerConfiguration,
            readiness: provider.readiness(hasAPIKey: APIKeyStore.shared.hasAPIKey(for: provider)),
            hotKeys: profiles.map(hotKeyDiagnosticLine(for:)),
            currentStatus: currentStatus,
            hasAPIKey: APIKeyStore.shared.hasAPIKey(for: provider),
            supportsProviderInterface: voiceProvider?.capabilities.supportsProviderInterface == true,
            supportsConnectionCheck: voiceProvider?.capabilities.supportsConnectionCheck == true,
            hasSessionLog: sessionLog.isEmpty == false
        )
    }

    private func hotKeyDiagnosticLine(for profile: VoiceProfile) -> String {
        guard let hotKey = profile.hotKey else {
            return "\(profile.name): no hotkey"
        }
        let registration = carbonRegisteredProfileIDs.contains(profile.id)
            ? "Carbon registered"
            : "event monitor only"
        return "\(profile.name): \(hotKey.displayName) (\(registration))"
    }

    private func recordProviderEvent(_ event: VoiceProviderEvent) {
        sessionLog.append(event, provider: providerConfiguration.providerID)
        sessionLogWindowController?.update(text: sessionLog.displayText)
        updateMenuContent()
    }
}

extension VoiceKeyAppDelegate: SettingsWindowControllerDelegate {
    func settingsController(_ controller: SettingsWindowController, didUpdateProfiles newProfiles: [VoiceProfile]) {
        profiles = newProfiles

        if let activeProfileID, newProfiles.contains(where: { $0.id == activeProfileID }) == false {
            self.activeProfileID = nil
        }

        registerAllHotKeys()
        rebuildMenu()

        if let selectedProfile {
            let configuration = sessionConfiguration(for: selectedProfile)
            if configuration != providerConfiguration {
                updateProviderConfiguration(configuration)
            }
        }
    }

    func settingsController(
        _ controller: SettingsWindowController,
        didRecordHotKey hotKey: HotKeyConfiguration,
        forProfileID id: UUID
    ) -> Bool {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return false }

        let previousHotKey = profiles[index].hotKey
        profiles[index].hotKey = hotKey

        guard registerHotKey(for: id) else {
            profiles[index].hotKey = previousHotKey
            _ = registerHotKey(for: id)
            rebuildMenu()
            return false
        }

        VoiceProfileStore.save(profiles)
        rebuildMenu()
        return true
    }
}
