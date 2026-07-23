import AppKit
import Carbon

protocol SettingsWindowControllerDelegate: AnyObject {
    func settingsController(_ controller: SettingsWindowController, didUpdateProfiles profiles: [VoiceProfile])
    func settingsController(_ controller: SettingsWindowController, didRecordHotKey hotKey: HotKeyConfiguration, forProfileID id: UUID) -> Bool
}

final class SettingsWindowController: NSWindowController {
    weak var delegate: SettingsWindowControllerDelegate?

    private var workingProfiles: [VoiceProfile]
    private var selectedProfileID: UUID

    /// The profiles under edit. The app delegate pushes its authoritative list whenever the
    /// settings window opens; setting this replaces the working copy and refreshes the form.
    var profiles: [VoiceProfile] {
        get { workingProfiles }
        set { adoptProfiles(newValue) }
    }

    private let formStackView = NSStackView()

    private let profilePopup = NSPopUpButton()
    private let addProfileButton = NSButton(title: "Add", target: nil, action: nil)
    private let removeProfileButton = NSButton(title: "Remove", target: nil, action: nil)
    private let duplicateProfileButton = NSButton(title: "Duplicate", target: nil, action: nil)

    private let nameField = NSTextField()
    private let providerPopup = NSPopUpButton()
    private let recorderView = HotKeyRecorderView()
    private let hotKeyStatusLabel = NSTextField(labelWithString: "")
    private let modelField = NSTextField()
    private let voiceComboBox = NSComboBox()
    private let endpointLabel = NSTextField(labelWithString: "Endpoint (wss://...)")
    private let endpointField = NSTextField()
    private let endpointRequiredLabel = NSTextField(labelWithString: "Required")
    private let endpointRow = NSStackView()
    private let apiCredentialLabel = NSTextField(labelWithString: "")
    private let apiKeyField = NSSecureTextField()
    private let removeAPIKeyButton = NSButton(title: "Remove Key", target: nil, action: nil)
    private let credentialStatusLabel = NSTextField(labelWithString: "")
    private let instructionsScrollView = NSScrollView()
    private let instructionsTextView = NSTextView()
    private let tipLabel = NSTextField(wrappingLabelWithString: "If the voice hears phrases you did not say, use headphones — speaker audio feeding back into the microphone causes phantom turns.")
    private let formStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)

    private static let labelColumnWidth: CGFloat = 140
    private static let hotKeyHint = "Click the field, then press the new shortcut."

    init(profiles: [VoiceProfile]) {
        let initialProfiles = profiles.isEmpty ? [Self.makeDefaultProfile()] : profiles
        workingProfiles = initialProfiles
        selectedProfileID = initialProfiles[0].id

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "VoiceKey Settings"
        window.contentMinSize = NSSize(width: 540, height: 560)
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)

        buildContent()
        rebuildProfilePopup()
        syncFormFromSelectedProfile()
        updateProfileButtons()

        recorderView.onHotKeyRecorded = { [weak self] profileID, hotKey in
            self?.handleRecordedHotKey(hotKey, forProfileID: profileID)
        }
    }

    convenience init() {
        self.init(profiles: VoiceProfileStore.load())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showAndFocus() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    // MARK: - Layout

    private func buildContent() {
        guard let contentView = window?.contentView else { return }

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.frame = contentView.bounds
        scrollView.autoresizingMask = [.width, .height]
        contentView.addSubview(scrollView)

        formStackView.orientation = .vertical
        formStackView.alignment = .leading
        formStackView.spacing = 8
        formStackView.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        formStackView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = formStackView
        NSLayoutConstraint.activate([
            formStackView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            formStackView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            formStackView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor)
        ])

        configureProfileControls()
        configureProviderPopup()
        configureInstructionsEditor()
        configureStaticControls()

        // Profile: picker with add/remove/duplicate, plus the display name.
        addSection("Profile")
        addArranged(makeControlRow(
            views: [profilePopup, addProfileButton, removeProfileButton, duplicateProfileButton],
            stretching: profilePopup
        ))
        let nameRow = makeRow(label: "Name", views: [nameField], stretching: nameField)
        addArranged(nameRow)
        endSection(after: nameRow)

        // Voice Provider: adapter choice plus its model/voice/endpoint knobs.
        addSection("Voice Provider")
        addArranged(makeRow(label: "Provider", views: [providerPopup], stretching: providerPopup))
        addArranged(makeRow(label: "Model", views: [modelField], stretching: modelField))
        addArranged(makeRow(label: "Voice", views: [voiceComboBox], stretching: voiceComboBox))

        endpointRow.orientation = .horizontal
        endpointRow.alignment = .centerY
        endpointRow.spacing = 12
        endpointRow.translatesAutoresizingMaskIntoConstraints = false
        styleFormLabel(endpointLabel)
        endpointField.translatesAutoresizingMaskIntoConstraints = false
        endpointField.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        endpointRequiredLabel.font = NSFont.systemFont(ofSize: 11)
        endpointRequiredLabel.textColor = .systemRed
        endpointRequiredLabel.translatesAutoresizingMaskIntoConstraints = false
        endpointRow.addArrangedSubview(endpointLabel)
        endpointRow.addArrangedSubview(endpointField)
        endpointRow.addArrangedSubview(endpointRequiredLabel)
        addArranged(endpointRow)
        endSection(after: endpointRow)

        // Shortcut: global hotkey recorder with an inline hint/error line.
        addSection("Shortcut")
        let hotKeyRow = makeRow(label: "Hotkey", views: [recorderView], stretching: recorderView)
        recorderView.heightAnchor.constraint(equalToConstant: 44).isActive = true
        addArranged(hotKeyRow)
        formStackView.setCustomSpacing(4, after: hotKeyRow)
        let hotKeyHintRow = indentedRow(hotKeyStatusLabel)
        addArranged(hotKeyHintRow)
        endSection(after: hotKeyHintRow)

        // Credentials: per-provider key/token entry with an inline status line.
        addSection("Credentials")
        styleFormLabel(apiCredentialLabel)
        apiKeyField.translatesAutoresizingMaskIntoConstraints = false
        apiKeyField.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        removeAPIKeyButton.bezelStyle = .rounded
        removeAPIKeyButton.controlSize = .small
        removeAPIKeyButton.translatesAutoresizingMaskIntoConstraints = false
        removeAPIKeyButton.target = self
        removeAPIKeyButton.action = #selector(removeAPIKey)
        let apiKeyRow = NSStackView(views: [apiCredentialLabel, apiKeyField, removeAPIKeyButton])
        apiKeyRow.orientation = .horizontal
        apiKeyRow.alignment = .centerY
        apiKeyRow.spacing = 12
        apiKeyRow.translatesAutoresizingMaskIntoConstraints = false
        addArranged(apiKeyRow)
        formStackView.setCustomSpacing(4, after: apiKeyRow)
        let credentialHintRow = indentedRow(credentialStatusLabel)
        addArranged(credentialHintRow)
        endSection(after: credentialHintRow)

        // Instructions: system prompt for the selected profile.
        addSection("Instructions")
        addArranged(instructionsScrollView)
        endSection(after: instructionsScrollView)

        // Footer: speaker-feedback tip, inline status, prominent Save button.
        let footerSeparator = makeSeparator()
        addArranged(footerSeparator)
        formStackView.setCustomSpacing(12, after: footerSeparator)
        addArranged(tipLabel)
        addArranged(formStatusLabel)
        formStackView.setCustomSpacing(12, after: formStatusLabel)
        let saveSpacer = NSView()
        saveSpacer.translatesAutoresizingMaskIntoConstraints = false
        saveSpacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let saveRow = NSStackView(views: [saveSpacer, saveButton])
        saveRow.orientation = .horizontal
        saveRow.translatesAutoresizingMaskIntoConstraints = false
        addArranged(saveRow)
    }

    private func configureProfileControls() {
        profilePopup.translatesAutoresizingMaskIntoConstraints = false
        profilePopup.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        profilePopup.target = self
        profilePopup.action = #selector(profileSelectionChanged)

        // Compact square symbol buttons keep the picker row quiet; the titles
        // set at declaration remain as accessibility labels.
        configureProfileButton(addProfileButton, symbolName: "plus", toolTip: "Add profile", action: #selector(addProfile))
        configureProfileButton(removeProfileButton, symbolName: "minus", toolTip: "Remove profile", action: #selector(removeProfileWithConfirmation))
        configureProfileButton(duplicateProfileButton, symbolName: "plus.square.on.square", toolTip: "Duplicate profile", action: #selector(duplicateProfile))
    }

    private func configureProfileButton(_ button: NSButton, symbolName: String, toolTip: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: toolTip)
        button.imagePosition = .imageOnly
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.toolTip = toolTip
        button.translatesAutoresizingMaskIntoConstraints = false
        button.target = self
        button.action = action
    }

    private func configureProviderPopup() {
        providerPopup.translatesAutoresizingMaskIntoConstraints = false
        providerPopup.removeAllItems()
        for provider in VoiceProviderID.allCases {
            let suffix = provider.isImplemented ? "" : " (coming soon)"
            providerPopup.addItem(withTitle: provider.displayName + suffix)
            providerPopup.lastItem?.representedObject = provider.rawValue
            providerPopup.lastItem?.isEnabled = provider.isImplemented
        }
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged)
    }

    private func configureInstructionsEditor() {
        instructionsScrollView.borderType = .bezelBorder
        instructionsScrollView.drawsBackground = true
        instructionsScrollView.hasVerticalScroller = true
        instructionsScrollView.autohidesScrollers = true
        instructionsScrollView.translatesAutoresizingMaskIntoConstraints = false
        instructionsScrollView.heightAnchor.constraint(equalToConstant: 84).isActive = true

        instructionsTextView.isRichText = false
        instructionsTextView.importsGraphics = false
        instructionsTextView.allowsUndo = true
        instructionsTextView.font = NSFont.systemFont(ofSize: 13)
        instructionsTextView.textContainerInset = NSSize(width: 4, height: 6)
        instructionsTextView.isVerticallyResizable = true
        instructionsTextView.isHorizontallyResizable = false
        instructionsTextView.autoresizingMask = [.width]
        instructionsTextView.textContainer?.widthTracksTextView = true
        instructionsTextView.textContainer?.containerSize = NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        instructionsScrollView.documentView = instructionsTextView
        instructionsTextView.frame = NSRect(origin: .zero, size: instructionsScrollView.contentSize)
    }

    private func configureStaticControls() {
        nameField.delegate = self
        nameField.placeholderString = "Profile name"

        hotKeyStatusLabel.font = NSFont.systemFont(ofSize: 11)
        resetHotKeyStatus()

        voiceComboBox.usesDataSource = false
        voiceComboBox.isEditable = true

        endpointField.placeholderString = "wss://localhost:8080"

        credentialStatusLabel.font = NSFont.systemFont(ofSize: 11)
        credentialStatusLabel.textColor = .secondaryLabelColor

        tipLabel.font = NSFont.systemFont(ofSize: 11)
        tipLabel.textColor = .secondaryLabelColor

        formStatusLabel.font = NSFont.systemFont(ofSize: 12)
        clearFormStatus()

        // Return-key default button: AppKit paints it with the accent color.
        saveButton.bezelStyle = .rounded
        saveButton.controlSize = .large
        saveButton.keyEquivalent = "\r"
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        saveButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true
        saveButton.target = self
        saveButton.action = #selector(saveSettings)
    }

    private func styleFormLabel(_ label: NSTextField) {
        label.font = NSFont.systemFont(ofSize: 13)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: Self.labelColumnWidth).isActive = true
        label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
    }

    private func makeRow(label: String, views: [NSView], stretching stretchedView: NSView) -> NSStackView {
        let labelField = NSTextField(labelWithString: label)
        styleFormLabel(labelField)

        var arranged: [NSView] = [labelField]
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            arranged.append(view)
        }
        stretchedView.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        let row = NSStackView(views: arranged)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    /// A row of controls without a leading label; the section header names it.
    private func makeControlRow(views: [NSView], stretching stretchedView: NSView) -> NSStackView {
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        stretchedView.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func indentedRow(_ view: NSView) -> NSStackView {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let row = NSStackView(views: [view])
        row.orientation = .horizontal
        row.edgeInsets = NSEdgeInsets(top: 0, left: Self.labelColumnWidth + 12, bottom: 0, right: 0)
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 13, weight: .bold)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func makeSeparator() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        return separator
    }

    /// Adds a bold section header followed by a hairline separator.
    private func addSection(_ title: String) {
        let header = sectionLabel(title)
        addArranged(header)
        formStackView.setCustomSpacing(4, after: header)
        addArranged(makeSeparator())
    }

    /// Restores the wider 20pt rhythm between one section and the next header.
    private func endSection(after view: NSView) {
        formStackView.setCustomSpacing(20, after: view)
    }

    private func addArranged(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        formStackView.addArrangedSubview(view)
        view.trailingAnchor.constraint(equalTo: formStackView.trailingAnchor, constant: -20).isActive = true
    }

    // MARK: - Working copy

    private static func makeDefaultProfile() -> VoiceProfile {
        let provider = VoiceProviderID.openAIRealtime
        return VoiceProfile(
            id: UUID(),
            name: provider.displayName,
            providerID: provider,
            hotKey: .defaultVoiceToggle,
            model: provider.defaultModel,
            voice: provider.defaultVoice,
            instructions: VoiceSessionConfiguration.defaultInstructions,
            endpointURL: ""
        )
    }

    private func adoptProfiles(_ newValue: [VoiceProfile]) {
        // While the window is visible the working copy owns the form; replacing it mid-edit
        // would discard in-progress values. Re-opening the window resets to persisted state.
        guard window?.isVisible != true else { return }

        let nextProfiles = newValue.isEmpty ? [Self.makeDefaultProfile()] : newValue
        workingProfiles = nextProfiles
        if nextProfiles.contains(where: { $0.id == selectedProfileID }) == false {
            selectedProfileID = nextProfiles[0].id
        }
        rebuildProfilePopup()
        syncFormFromSelectedProfile()
        updateProfileButtons()
    }

    private var selectedProfileIndex: Int? {
        workingProfiles.firstIndex(where: { $0.id == selectedProfileID })
    }

    private func displayName(for profile: VoiceProfile) -> String {
        let trimmed = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? profile.providerID.displayName : trimmed
    }

    private func commitFormToWorkingCopy() {
        guard let index = selectedProfileIndex else { return }
        var profile = workingProfiles[index]
        profile.name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if profile.providerID.isImplemented,
           let raw = providerPopup.selectedItem?.representedObject as? String,
           let provider = VoiceProviderID(rawValue: raw) {
            profile.providerID = provider
        }
        profile.model = modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.voice = voiceComboBox.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.instructions = instructionsTextView.string
        profile.endpointURL = endpointField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        workingProfiles[index] = profile
    }

    private func syncFormFromSelectedProfile() {
        guard let index = selectedProfileIndex else { return }
        let profile = workingProfiles[index]
        let provider = profile.providerID

        nameField.stringValue = profile.name

        if let itemIndex = providerPopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == provider.rawValue }),
           provider.isImplemented {
            providerPopup.selectItem(at: itemIndex)
        } else if providerPopup.itemArray.isEmpty == false {
            providerPopup.selectItem(at: 0)
        }

        recorderView.profileID = profile.id
        recorderView.hotKey = profile.hotKey
        resetHotKeyStatus()

        modelField.isEnabled = provider.supportsModelSetting
        modelField.placeholderString = provider.defaultModel
        let model = profile.model.trimmingCharacters(in: .whitespacesAndNewlines)
        modelField.stringValue = provider.supportsModelSetting && model.isEmpty == false ? model : provider.defaultModel

        voiceComboBox.isEnabled = provider.supportsVoiceSetting
        voiceComboBox.placeholderString = provider.defaultVoice
        voiceComboBox.removeAllItems()
        voiceComboBox.addItems(withObjectValues: provider.voiceOptions)
        let voice = profile.voice.trimmingCharacters(in: .whitespacesAndNewlines)
        voiceComboBox.stringValue = provider.supportsVoiceSetting && voice.isEmpty == false ? voice : provider.defaultVoice

        endpointRow.isHidden = provider.supportsEndpointSetting == false
        endpointRequiredLabel.isHidden = provider != .custom
        endpointField.placeholderString = provider.endpointPlaceholder
        endpointField.stringValue = profile.endpointURL

        instructionsTextView.string = profile.instructions
        instructionsTextView.isEditable = provider != .chatGPTWeb

        apiCredentialLabel.stringValue = provider.credentialLabel
        apiKeyField.stringValue = ""
        syncCredentialStatus(for: provider)

        clearFormStatus()
    }

    private func syncCredentialStatus(for provider: VoiceProviderID) {
        let credentialState = VoiceProviderCredentialViewState(
            provider: provider,
            hasAPIKey: APIKeyStore.shared.hasAPIKey(for: provider)
        )
        apiKeyField.isEnabled = credentialState.acceptsAPIKeyInput
        apiKeyField.placeholderString = provider.credentialPlaceholder
        removeAPIKeyButton.isEnabled = credentialState.canRemoveAPIKey
        removeAPIKeyButton.isHidden = provider == .chatGPTWeb
        credentialStatusLabel.stringValue = credentialState.statusMessage
    }

    private func rebuildProfilePopup() {
        profilePopup.removeAllItems()
        for profile in workingProfiles {
            profilePopup.addItem(withTitle: displayName(for: profile))
            profilePopup.lastItem?.representedObject = profile.id.uuidString
        }
        if let index = selectedProfileIndex {
            profilePopup.selectItem(at: index)
        }
    }

    private func selectProfile(id: UUID) {
        guard workingProfiles.contains(where: { $0.id == id }) else { return }
        selectedProfileID = id
        rebuildProfilePopup()
        syncFormFromSelectedProfile()
    }

    private func updateProfileButtons() {
        removeProfileButton.isEnabled = workingProfiles.count > 1
    }

    private func uniqueProfileName(base: String) -> String {
        let names = Set(workingProfiles.map { $0.name })
        if names.contains(base) == false {
            return base
        }
        var suffix = 2
        while names.contains("\(base) \(suffix)") {
            suffix += 1
        }
        return "\(base) \(suffix)"
    }

    // MARK: - Profile picker actions

    @objc private func profileSelectionChanged() {
        guard let raw = profilePopup.selectedItem?.representedObject as? String,
              let id = UUID(uuidString: raw),
              id != selectedProfileID else { return }
        commitFormToWorkingCopy()
        selectProfile(id: id)
    }

    @objc private func addProfile() {
        commitFormToWorkingCopy()
        let provider = VoiceProviderID.openAIRealtime
        let profile = VoiceProfile(
            id: UUID(),
            name: uniqueProfileName(base: "New Profile"),
            providerID: provider,
            hotKey: nil,
            model: provider.defaultModel,
            voice: provider.defaultVoice,
            instructions: VoiceSessionConfiguration.defaultInstructions,
            endpointURL: ""
        )
        workingProfiles.append(profile)
        selectProfile(id: profile.id)
        updateProfileButtons()
    }

    @objc private func duplicateProfile() {
        guard let sourceIndex = selectedProfileIndex else { return }
        commitFormToWorkingCopy()
        let source = workingProfiles[sourceIndex]
        var copy = source
        copy.id = UUID()
        copy.name = uniqueProfileName(base: "\(displayName(for: source)) Copy")
        copy.hotKey = nil
        workingProfiles.insert(copy, at: sourceIndex + 1)
        selectProfile(id: copy.id)
        updateProfileButtons()
    }

    @objc private func removeProfileWithConfirmation() {
        guard workingProfiles.count > 1, let index = selectedProfileIndex else { return }
        let name = displayName(for: workingProfiles[index])

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove profile “\(name)”?"
        alert.informativeText = "This can’t be undone."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        workingProfiles.remove(at: index)
        selectedProfileID = workingProfiles[min(index, workingProfiles.count - 1)].id
        rebuildProfilePopup()
        syncFormFromSelectedProfile()
        updateProfileButtons()
    }

    // MARK: - Provider / hotkey actions

    @objc private func providerChanged() {
        guard let index = selectedProfileIndex,
              let raw = providerPopup.selectedItem?.representedObject as? String,
              let provider = VoiceProviderID(rawValue: raw) else { return }
        guard provider != workingProfiles[index].providerID else { return }

        // Commit typed values first so switching providers never discards them.
        commitFormToWorkingCopy()
        workingProfiles[index].providerID = provider
        workingProfiles[index].model = provider.defaultModel
        workingProfiles[index].voice = provider.defaultVoice
        syncFormFromSelectedProfile()
    }

    private func handleRecordedHotKey(_ hotKey: HotKeyConfiguration, forProfileID profileID: UUID) {
        guard let index = workingProfiles.firstIndex(where: { $0.id == profileID }) else { return }

        if let conflict = workingProfiles.first(where: { $0.id != profileID && isSameHotKey($0.hotKey, hotKey) }) {
            recorderView.hotKey = workingProfiles[index].hotKey
            showHotKeyError("Already used by \(displayName(for: conflict))")
            return
        }

        let accepted = delegate?.settingsController(self, didRecordHotKey: hotKey, forProfileID: profileID) ?? false
        if accepted {
            workingProfiles[index].hotKey = hotKey
            resetHotKeyStatus()
        } else {
            recorderView.hotKey = workingProfiles[index].hotKey
            showHotKeyError("That shortcut could not be registered.")
        }
    }

    private func isSameHotKey(_ lhs: HotKeyConfiguration?, _ rhs: HotKeyConfiguration?) -> Bool {
        guard let lhs = lhs, let rhs = rhs else { return false }
        return lhs.keyCode == rhs.keyCode && lhs.carbonModifiers == rhs.carbonModifiers
    }

    private func resetHotKeyStatus() {
        hotKeyStatusLabel.stringValue = Self.hotKeyHint
        hotKeyStatusLabel.textColor = .secondaryLabelColor
    }

    private func showHotKeyError(_ message: String) {
        hotKeyStatusLabel.stringValue = message
        hotKeyStatusLabel.textColor = .systemRed
    }

    // MARK: - Save / API key actions

    @objc private func saveSettings() {
        let previouslySelectedID = selectedProfileID
        let typedAPIKey = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        commitFormToWorkingCopy()

        let normalized = normalizedProfilesForSave()
        for profile in normalized {
            if let message = endpointValidationError(for: profile) {
                workingProfiles = normalized
                selectProfile(id: profile.id)
                if profile.id == previouslySelectedID {
                    apiKeyField.stringValue = typedAPIKey
                }
                showFormError(message)
                return
            }
        }
        workingProfiles = normalized
        VoiceProfileStore.save(normalized)

        if let index = selectedProfileIndex {
            let provider = workingProfiles[index].providerID
            let credentialState = VoiceProviderCredentialViewState(
                provider: provider,
                hasAPIKey: APIKeyStore.shared.hasAPIKey(for: provider)
            )
            if credentialState.acceptsAPIKeyInput, typedAPIKey.isEmpty == false {
                do {
                    try APIKeyStore.shared.setAPIKey(typedAPIKey, for: provider)
                } catch {
                    showFormError("Couldn’t save the API key: \(error.localizedDescription)")
                    rebuildProfilePopup()
                    syncCredentialStatus(for: provider)
                    delegate?.settingsController(self, didUpdateProfiles: workingProfiles)
                    return
                }
            }
        }

        rebuildProfilePopup()
        syncFormFromSelectedProfile()
        delegate?.settingsController(self, didUpdateProfiles: workingProfiles)
        showFormStatus("Saved.")
    }

    @objc private func removeAPIKey() {
        guard let index = selectedProfileIndex else { return }
        let provider = workingProfiles[index].providerID
        guard provider != .chatGPTWeb else { return }

        do {
            try APIKeyStore.shared.deleteAPIKey(for: provider)
            apiKeyField.stringValue = ""
            syncCredentialStatus(for: provider)
            // No dedicated API-key hook exists; reusing didUpdateProfiles refreshes
            // menu enablement (e.g. Check API Connection) for the new key state.
            delegate?.settingsController(self, didUpdateProfiles: workingProfiles)
        } catch {
            showFormError("Couldn’t remove the API key: \(error.localizedDescription)")
        }
    }

    private func normalizedProfilesForSave() -> [VoiceProfile] {
        workingProfiles.map { profile in
            var normalized = profile
            let provider = profile.providerID

            normalized.name = displayName(for: profile)

            let model = profile.model.trimmingCharacters(in: .whitespacesAndNewlines)
            normalized.model = provider.supportsModelSetting && model.isEmpty == false ? model : provider.defaultModel

            let voice = profile.voice.trimmingCharacters(in: .whitespacesAndNewlines)
            normalized.voice = provider.supportsVoiceSetting && voice.isEmpty == false ? voice : provider.defaultVoice

            let instructions = profile.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
            normalized.instructions = provider != .chatGPTWeb && instructions.isEmpty == false
                ? instructions
                : VoiceSessionConfiguration.defaultInstructions

            normalized.endpointURL = profile.endpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized
        }
    }

    private func endpointValidationError(for profile: VoiceProfile) -> String? {
        let endpoint = profile.endpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if endpoint.isEmpty {
            return profile.providerID == .custom
                ? "“\(displayName(for: profile))” needs an endpoint URL — custom endpoints can’t be saved without one."
                : nil
        }
        guard isValidEndpointURL(endpoint) else {
            return "The endpoint URL for “\(displayName(for: profile))” must start with ws://, wss://, http://, or https:// and include a host."
        }
        return nil
    }

    private func isValidEndpointURL(_ string: String) -> Bool {
        guard let components = URLComponents(string: string),
              let scheme = components.scheme?.lowercased(),
              ["ws", "wss", "http", "https"].contains(scheme),
              let host = components.host,
              host.isEmpty == false else {
            return false
        }
        return true
    }

    private func showFormError(_ message: String) {
        formStatusLabel.stringValue = message
        formStatusLabel.textColor = .systemRed
        formStatusLabel.isHidden = false
    }

    private func showFormStatus(_ message: String) {
        formStatusLabel.stringValue = message
        formStatusLabel.textColor = .secondaryLabelColor
        formStatusLabel.isHidden = false
    }

    private func clearFormStatus() {
        formStatusLabel.stringValue = ""
        formStatusLabel.isHidden = true
    }
}

extension SettingsWindowController: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField,
              field === nameField,
              let index = selectedProfileIndex else { return }
        workingProfiles[index].name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        rebuildProfilePopup()
    }
}

final class HotKeyRecorderView: NSView {
    var profileID: UUID?

    var hotKey: HotKeyConfiguration? {
        didSet {
            needsDisplay = true
        }
    }

    var onHotKeyRecorded: ((UUID, HotKeyConfiguration) -> Void)?

    private var isRecording = false {
        didSet {
            needsDisplay = true
        }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isRecording = true
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            isRecording = false
            return
        }

        guard let recordedHotKey = HotKeyConfiguration(
            keyCode: UInt32(event.keyCode),
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifierFlags: event.modifierFlags
        ) else {
            NSSound.beep()
            return
        }

        isRecording = false
        hotKey = recordedHotKey
        guard let profileID = profileID else { return }
        onHotKeyRecorded?(profileID, recordedHotKey)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let bounds = bounds.insetBy(dx: 0.5, dy: 0.5)
        let backgroundColor = isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.14) : NSColor.controlBackgroundColor
        let borderColor = isRecording ? NSColor.controlAccentColor : NSColor.separatorColor
        let path = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)

        backgroundColor.setFill()
        path.fill()
        borderColor.setStroke()
        path.lineWidth = isRecording ? 2 : 1
        path.stroke()

        let text: String
        let textColor: NSColor
        if isRecording {
            text = "Press shortcut"
            textColor = .labelColor
        } else if let hotKey = hotKey {
            text = hotKey.displayName
            textColor = .labelColor
        } else {
            text = "Click to set shortcut"
            textColor = .secondaryLabelColor
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 20, weight: .semibold),
            .foregroundColor: textColor
        ]
        let size = text.size(withAttributes: attributes)
        let rect = NSRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
        text.draw(in: rect, withAttributes: attributes)
    }
}
