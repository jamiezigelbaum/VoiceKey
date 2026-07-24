import AppKit
import ApplicationServices
import AVFoundation

enum HotKeyRecordingLifecycle {
    static func register(
        _ hotKey: HotKeyConfiguration,
        for workingProfile: VoiceProfile,
        committedProfiles: [VoiceProfile],
        register: (VoiceProfile) -> Bool
    ) -> Bool {
        guard let committedProfile = committedProfiles.first(where: {
            $0.id == workingProfile.id
        }) else {
            // Never register a Carbon hotkey for a channel the app does not own.
            return false
        }

        var candidate = committedProfile
        let previousCandidate = candidate
        candidate.hotKey = hotKey

        guard register(candidate) else {
            if previousCandidate.hotKey != nil {
                _ = register(previousCandidate)
            }
            return false
        }
        return true
    }
}

enum ActiveVoiceProfileLifecycle {
    static func reconcile(
        activeProfileID: UUID?,
        newProfiles: [VoiceProfile],
        provider: RealtimeVoiceProvider?
    ) -> UUID? {
        guard let activeProfileID,
              newProfiles.contains(where: { $0.id == activeProfileID }) == false else {
            return activeProfileID
        }

        provider?.stopVoice()
        return nil
    }
}

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
    private var appOwnedAttention: AppOwnedAttentionState?
    private var firstRunSettingsLifecycle: FirstRunSettingsLifecycle?
    private var settingsWindowController: SettingsWindowController?
    private var sessionLogWindowController: SessionLogWindowController?
    private var voiceProvider: RealtimeVoiceProvider?
    private var providerGeneration = UUID()
    private var sessionLog = VoiceSessionLog()
    private let sessionLogFile = VoiceSessionLogFile()
    private var localHotKeyMonitor: Any?
    private var globalHotKeyMonitor: Any?
    private let iconAnimator = MenuBarIconAnimator()
    private let stopWatchdog = StopWatchdog()
    private var isAccessibilityTrusted: () -> Bool = {
        AXIsProcessTrusted()
    }
    private var requestAccessibilityTrust: () -> Void = {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue()
                as String: true
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
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
        if selectedProfile != nil {
            configureProvider()
            voiceProvider?.prepare()
        } else {
            updateStatus(.ready)
        }
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
            profileID: profile.id,
            providerID: profile.providerID,
            model: profile.model,
            voice: profile.voice,
            instructions: profile.instructions,
            endpointURL: profile.endpointURL,
            mcpServers: [.openAIRealtime, .custom].contains(profile.providerID)
                ? profile.mcpServers
                : [],
            webSearchEnabled: profile.providerID == .openAIRealtime && profile.webSearchEnabled,
            speakerModePreference: profile.speakerModePreference
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
            registerHotKey(for: profile)
        }
    }

    @discardableResult
    private func registerHotKey(for profile: VoiceProfile) -> Bool {
        hotKeys[profile.id] = nil
        carbonRegisteredProfileIDs.remove(profile.id)

        guard let configuration = profile.hotKey else {
            return false
        }

        guard let globalHotKey = GlobalHotKey(
            id: carbonHotKeyID(for: profile.id),
            configuration: configuration,
            handler: { [weak self] in
                self?.triggerHotKey(for: profile.id)
            }
        ) else {
            let diagnostic = HotKeyFallbackPolicy.diagnostic(
                hotKeyName: configuration.displayName,
                profileName: profile.name,
                isAccessibilityTrusted: isAccessibilityTrusted(),
                requestAccessibilityTrust: requestAccessibilityTrust
            )
            recordProviderEvent(
                .diagnostic(diagnostic),
                provider: profile.providerID
            )
            return false
        }

        hotKeys[profile.id] = globalHotKey
        carbonRegisteredProfileIDs.insert(profile.id)
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
            guard let self,
                  self.settingsWindowController?.window?.isKeyWindow != true,
                  let profileID = self.profileID(matchingKeyEvent: event) else {
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

        if activeProfileID == profile.id,
           currentStatus.isLiveSessionStatus {
            voiceProvider?.toggleVoice()
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted:
            presentMicrophoneAccessAlert()
            return
        case .authorized, .notDetermined:
            break
        @unknown default:
            break
        }

        if let failure = ProfileActivationPolicy.failure(
            for: profile,
            hasAPIKey: APIKeyStore.shared.hasAPIKey(for: profile)
        ) {
            handleActivationFailure(failure, for: profile)
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

    private func handleActivationFailure(
        _ failure: ProfileActivationFailure,
        for profile: VoiceProfile
    ) {
        let message = failure.settingsMessage
        recordProviderEvent(
            .diagnostic(
                "Voice channel \"\(profile.name)\" could not start: \(message)"
            ),
            provider: profile.providerID
        )
        let preservesStatus =
            ProfileActivationPolicy.preservesGlobalStatus(
                requestedProfileID: profile.id,
                activeProfileID: activeProfileID,
                currentStatus: currentStatus
            )
        if preservesStatus == false {
            appOwnedAttention = AppOwnedAttentionState(
                profileID: profile.id,
                failure: failure
            )
            updateStatus(
                .needsAttention(message),
                clearsAppOwnedAttention: false
            )
        }
        presentActivationFailureAlert(
            channelName: profile.name,
            message: message
        )
        presentSettings(focusedOn: profile.id, failure: failure)
    }

    private func presentActivationFailureAlert(
        channelName: String,
        message: String
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "“\(channelName)” Isn’t Ready"
        alert.informativeText = message
        alert.addButton(withTitle: "Open Settings")
        alert.runModal()
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
        providerGeneration = UUID()
        stopWatchdog.cancel()
        voiceProvider?.stopVoice()

        let provider = VoiceProviderFactory.makeProvider(for: providerConfiguration)
        let wiredGeneration = providerGeneration
        provider.onEvent = ProviderEventAttribution.handler(
            providerID: provider.id
        ) { [weak self] event, providerID in
            guard let self else { return }
            self.recordProviderEvent(event, provider: providerID)
            switch event {
            case let .status(status):
                guard ProviderStatusAdoptionPolicy.shouldAdopt(
                    wiredGeneration: wiredGeneration,
                    currentGeneration: self.providerGeneration
                ) else {
                    return
                }
                self.updateStatus(
                    status,
                    sourceProviderID: providerID,
                    sourceProviderGeneration: wiredGeneration
                )
            case let .diagnostic(message):
                self.statusMenuItem.toolTip = message
            case let .transcript(delta):
                self.statusMenuItem.toolTip = delta
            }
        }

        voiceProvider = provider
        updateMenuContent()
    }

    private func updateProviderConfiguration(_ configuration: VoiceSessionConfiguration) {
        let previousConfiguration = providerConfiguration
        providerConfiguration = configuration

        if ProviderReplacementPolicy.requiresReplacement(
            current: previousConfiguration,
            next: configuration,
            currentProviderID: voiceProvider?.id
        ) {
            // configureProvider() stops the outgoing provider before replacing it.
            configureProvider()
            voiceProvider?.prepare()
        } else {
            voiceProvider?.update(configuration: configuration)
        }
        updateMenuContent()
    }

    @objc private func showProvider() {
        guard profiles.isEmpty == false else { return }
        voiceProvider?.showProviderInterface()
    }

    @objc private func reloadProvider() {
        guard profiles.isEmpty == false else { return }
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
        let readiness = provider.readiness(
            hasAPIKey: APIKeyStore.shared.hasAPIKey(for: profile)
        )
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
        sessionLogFile.clearToday()
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
        presentSettings(focusedOn: nil, failure: nil)
    }

    private func presentSettings(
        focusedOn profileID: UUID?,
        failure: ProfileActivationFailure?
    ) {
        registerAllHotKeys()
        let controller = settingsWindowController ?? SettingsWindowController(profiles: profiles)
        controller.delegate = self
        controller.profiles = profiles
        settingsWindowController = controller
        if let profileID, let failure {
            controller.showActivationFailure(
                for: profileID,
                failure: failure
            )
        } else {
            controller.showAndFocus()
        }
    }

    private func openSettingsOnFirstRunIfNeeded() {
        guard VoiceProfileStore.isFreshInstall(),
              UserDefaults.standard.bool(forKey: Self.hasOpenedSettingsKey) == false else { return }
        firstRunSettingsLifecycle = FirstRunSettingsLifecycle()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.registerAllHotKeys()
            let controller = self.settingsWindowController
                ?? SettingsWindowController(profiles: self.profiles)
            controller.delegate = self
            controller.profiles = self.profiles
            self.settingsWindowController = controller
            controller.showFirstRunHotKeyPrompt()
            let hasHotKey = self.profiles.contains(where: {
                $0.hotKey != nil
            })
            if self.firstRunSettingsLifecycle?
                .didShow(hasHotKey: hasHotKey) == true {
                self.markFirstRunSettingsComplete()
            }
        }
    }

    private func markFirstRunSettingsComplete() {
        UserDefaults.standard.set(
            true,
            forKey: Self.hasOpenedSettingsKey
        )
        firstRunSettingsLifecycle = nil
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func updateStatus(
        _ status: ProviderStatus,
        sourceProviderID: VoiceProviderID? = nil,
        sourceProviderGeneration: UUID? = nil,
        clearsAppOwnedAttention: Bool = true
    ) {
        if clearsAppOwnedAttention {
            appOwnedAttention = nil
        }
        currentStatus = status
        statusMenuItem.title = "Status: \(status.menuTitle)"
        if let detail = status.detail {
            statusMenuItem.title = "Status: \(status.menuTitle) - \(detail)"
        }
        updateIconAnimation()
        updateStatusItemTooltip()
        updateMenuContent()
        stopWatchdog.statusDidChange(
            status,
            providerID: sourceProviderID ?? voiceProvider?.id
        ) { [weak self] providerID in
            guard let self,
                  self.voiceProvider?.id == providerID,
                  self.providerGeneration ==
                    (sourceProviderGeneration
                        ?? self.providerGeneration),
                  self.currentStatus == .stopping else {
                return
            }
            self.recordProviderEvent(
                .diagnostic(
                    "Provider did not finish stopping within 10 seconds; forcing the app back to Ready."
                ),
                provider: providerID
            )
            self.updateStatus(.ready)
        }
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
        VoiceProfileMenuPolicy.isProfileItemEnabled(
            profileID: profile.id,
            activeProfileID: activeProfileID,
            status: currentStatus
        )
    }

    private func updateMenuContent() {
        for profile in profiles {
            guard let item = profileMenuItems[profile.id] else { continue }
            item.title = profileMenuTitle(for: profile)
            item.isEnabled = isProfileMenuItemEnabled(for: profile)
            if let hotKey = profile.hotKey {
                item.keyEquivalent = hotKey.effectiveMenuKeyEquivalent
                item.keyEquivalentModifierMask = hotKey.menuModifierMask
            } else {
                item.keyEquivalent = ""
                item.keyEquivalentModifierMask = []
            }
        }

        let state = providerMenuState()
        let providerTargetsEnabled =
            VoiceProfileMenuPolicy.providerTargetsEnabled(
                hasProfiles: profiles.isEmpty == false
            )
        showProviderMenuItem.isEnabled =
            providerTargetsEnabled
            && state.isProviderInterfaceEnabled
        reloadProviderMenuItem.isEnabled =
            providerTargetsEnabled
            && state.isProviderInterfaceEnabled

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
        checkProviderConnectionMenuItem.isEnabled =
            providerTargetsEnabled
            && state.isCheckConnectionEnabled
        copySessionLogMenuItem.isEnabled = state.isCopySessionLogEnabled
        clearSessionLogMenuItem.isEnabled = state.isClearSessionLogEnabled
    }

    private func providerMenuState() -> VoiceProviderMenuState {
        let provider = selectedProfile?.providerID ?? providerConfiguration.providerID
        let hasAPIKey = selectedProfile.map {
            APIKeyStore.shared.hasAPIKey(for: $0)
        } ?? APIKeyStore.shared.hasAPIKey(for: provider)
        return VoiceProviderMenuState(
            provider: provider,
            readiness: provider.readiness(hasAPIKey: hasAPIKey),
            currentStatus: currentStatus,
            supportsProviderInterface: voiceProvider?.capabilities.supportsProviderInterface == true,
            supportsConnectionCheck: voiceProvider?.capabilities.supportsConnectionCheck == true,
            hasSessionLog: sessionLog.isEmpty == false
        )
    }

    private func diagnosticsSnapshot() -> VoiceKeyDiagnosticsSnapshot {
        let provider = selectedProfile?.providerID ?? providerConfiguration.providerID
        let hasAPIKey = selectedProfile.map {
            APIKeyStore.shared.hasAPIKey(for: $0)
        } ?? APIKeyStore.shared.hasAPIKey(for: provider)
        return VoiceKeyDiagnosticsSnapshot(
            provider: provider,
            configuration: providerConfiguration,
            readiness: provider.readiness(hasAPIKey: hasAPIKey),
            hotKeys: profiles.map(hotKeyDiagnosticLine(for:)),
            currentStatus: currentStatus,
            hasAPIKey: hasAPIKey,
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
            : isAccessibilityTrusted()
                ? "trusted event-monitor fallback"
                : "unavailable without Accessibility access"
        return "\(profile.name): \(hotKey.displayName) (\(registration))"
    }

    private func recordProviderEvent(
        _ event: VoiceProviderEvent,
        provider: VoiceProviderID
    ) {
        sessionLog.append(event, provider: provider)
        sessionLogFile.append(event, provider: provider)
        sessionLogWindowController?.update(text: sessionLog.displayText)
        updateMenuContent()
    }
}

extension VoiceKeyAppDelegate: SettingsWindowControllerDelegate {
    func settingsController(_ controller: SettingsWindowController, didUpdateProfiles newProfiles: [VoiceProfile]) {
        let sortedProfiles = VoiceProfileStore.sortedByHotKey(
            newProfiles
        )
        if sortedProfiles.isEmpty {
            profiles = []
            resetProviderForEmptyProfiles()
            registerAllHotKeys()
            rebuildMenu()
            return
        }

        activeProfileID = ActiveVoiceProfileLifecycle.reconcile(
            activeProfileID: activeProfileID,
            newProfiles: sortedProfiles,
            provider: voiceProvider
        )

        profiles = sortedProfiles
        registerAllHotKeys()
        rebuildMenu()

        if let selectedProfile {
            let configuration = sessionConfiguration(for: selectedProfile)
            if voiceProvider == nil
                || configuration != providerConfiguration {
                updateProviderConfiguration(configuration)
            }
        }
        if firstRunSettingsLifecycle?
            .profilesDidChange(
                hasHotKey: profiles.contains(where: {
                    $0.hotKey != nil
                })
            ) == true {
            markFirstRunSettingsComplete()
        }
    }

    private func resetProviderForEmptyProfiles() {
        providerGeneration = UUID()
        stopWatchdog.cancel()
        voiceProvider?.onEvent = nil
        providerConfiguration =
            EmptyProfileRuntimeLifecycle.reset(
                provider: voiceProvider
            )
        voiceProvider = nil
        activeProfileID = nil
        appOwnedAttention = nil
        updateStatus(.ready)
    }

    func settingsController(
        _ controller: SettingsWindowController,
        didRecordHotKey hotKey: HotKeyConfiguration,
        for profile: VoiceProfile
    ) -> Bool {
        HotKeyRecordingLifecycle.register(
            hotKey,
            for: profile,
            committedProfiles: profiles,
            register: { [weak self] candidate in
                self?.registerHotKey(for: candidate) == true
            }
        )
    }

    func settingsController(
        _ controller: SettingsWindowController,
        didUpdateCredentialsFor profile: VoiceProfile
    ) {
        guard let committedProfile =
                CredentialAttentionPolicy
                    .profileAffectedByCredentialChange(
                        attention: appOwnedAttention,
                        changedProfile: profile,
                        profiles: profiles
                    ),
              let nextStatus = CredentialAttentionPolicy.reconcile(
                  attention: &appOwnedAttention,
                  profile: committedProfile,
                  hasAPIKey: APIKeyStore.shared.hasAPIKey(
                      for: committedProfile
                  ),
                  currentStatus: currentStatus
              ) else {
            updateMenuContent()
            return
        }
        updateStatus(
            nextStatus,
            clearsAppOwnedAttention: false
        )
    }

    func settingsControllerDidClose(
        _ controller: SettingsWindowController
    ) {
        if firstRunSettingsLifecycle?.didClose() == true {
            markFirstRunSettingsComplete()
        }
    }

    // Carbon hotkeys are consumed system-wide before any window sees them,
    // so while the recorder is capturing, suspend every registration:
    // otherwise pressing an already-assigned key toggles that profile's
    // session instead of reaching the recorder (and its conflict check).
    func settingsController(_ controller: SettingsWindowController, isRecordingHotKey: Bool) {
        if isRecordingHotKey {
            hotKeys.removeAll()
            carbonRegisteredProfileIDs.removeAll()
        } else {
            for profile in profiles where profile.hotKey != nil {
                registerHotKey(for: profile)
            }
        }
    }
}
