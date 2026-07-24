import AppKit
import Carbon

enum VoiceChannelUIStrings {
    static let windowTitle = "VoiceKey Voice Channels"
    static let channelSectionTitle = "Voice Channel"
    static let addChannel = "Add Channel"
    static let duplicateChannel = "Duplicate Channel"
    static let deleteChannel = "Delete Channel"
    static let channelNamePlaceholder = "Voice channel name"
    static let speakerModeLabel = "Channel speaker mode"
}

enum VoiceChannelOperations {
    static func makeChannel(
        provider: VoiceProviderID,
        existingNames: [String]
    ) -> VoiceProfile {
        VoiceProfile(
            id: UUID(),
            name: uniqueName(
                base: provider.displayName,
                existingNames: existingNames
            ),
            providerID: provider,
            hotKey: nil,
            model: provider.defaultModel,
            voice: provider.defaultVoice,
            instructions: VoiceSessionConfiguration.defaultInstructions,
            endpointURL: ""
        )
    }

    static func duplicate(
        _ source: VoiceProfile,
        existingNames: [String]
    ) -> VoiceProfile {
        var copy = source
        copy.id = UUID()
        copy.name = uniqueName(
            base: "\(displayName(for: source)) Copy",
            existingNames: existingNames
        )
        copy.hotKey = nil
        copy.mcpServers = source.mcpServers.map { server in
            MCPServerConfiguration(
                label: server.label,
                urlString: server.urlString,
                allowedTools: server.allowedTools
            )
        }
        return copy
    }

    private static func uniqueName(
        base: String,
        existingNames: [String]
    ) -> String {
        let names = Set(existingNames)
        if names.contains(base) == false {
            return base
        }
        var suffix = 2
        while names.contains("\(base) \(suffix)") {
            suffix += 1
        }
        return "\(base) \(suffix)"
    }

    private static func displayName(for profile: VoiceProfile) -> String {
        let trimmed = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? profile.providerID.displayName : trimmed
    }
}

struct OpenClawRuntimePanelSnapshot: Equatable {
    var isVisible: Bool
    var modelIsEditable: Bool
    var voicePickerIsVisible: Bool
    var applyButtonIsVisible: Bool
}

struct VoiceProfileProviderSettings: Equatable {
    var model: String
    var voice: String
}

struct VoiceProfileProviderSettingsCache {
    private var settingsByProfile: [UUID: [String: VoiceProfileProviderSettings]] = [:]

    init(profiles: [VoiceProfile]) {
        for profile in profiles {
            remember(profile)
        }
    }

    mutating func remember(_ profile: VoiceProfile) {
        settingsByProfile[profile.id, default: [:]][profile.providerID.rawValue] = VoiceProfileProviderSettings(
            model: profile.model,
            voice: profile.voice
        )
    }

    func settings(for profileID: UUID, provider: VoiceProviderID) -> VoiceProfileProviderSettings? {
        settingsByProfile[profileID]?[provider.rawValue]
    }

    mutating func remove(profileID: UUID) {
        settingsByProfile[profileID] = nil
    }
}

protocol SettingsWindowControllerDelegate: AnyObject {
    func settingsController(_ controller: SettingsWindowController, didUpdateProfiles profiles: [VoiceProfile])
    func settingsController(
        _ controller: SettingsWindowController,
        didRecordHotKey hotKey: HotKeyConfiguration,
        for profile: VoiceProfile
    ) -> Bool
    func settingsControllerDidUpdateCredentials(_ controller: SettingsWindowController)
    func settingsController(_ controller: SettingsWindowController, isRecordingHotKey: Bool)
}

final class SettingsWindowController: NSWindowController {
    weak var delegate: SettingsWindowControllerDelegate?

    private var workingProfiles: [VoiceProfile]
    private var selectedProfileID: UUID
    private var providerSettingsCache: VoiceProfileProviderSettingsCache
    private var pendingMCPAuthorizationValues: [UUID: String] = [:]
    private var pendingMCPAuthorizationDeletions: Set<UUID> = []
    private let openClawRuntimeService: OpenClawRuntimeSettingsServing
    private(set) var openClawRuntimePanelState: OpenClawRuntimePanelState
    private var openClawRuntimeLoadGeneration = UUID()

    /// The profiles under edit. The app delegate pushes its authoritative list whenever the
    /// settings window opens; setting this replaces the working copy and refreshes the form.
    var profiles: [VoiceProfile] {
        get { workingProfiles }
        set { adoptProfiles(newValue) }
    }

    var openClawRuntimePanelSnapshot: OpenClawRuntimePanelSnapshot {
        OpenClawRuntimePanelSnapshot(
            isVisible: openClawRuntimeSectionViews.first?.isHidden == false,
            modelIsEditable: openClawModelField.isEditable,
            voicePickerIsVisible: openClawVoicePopup.isHidden == false,
            applyButtonIsVisible: applyOpenClawRuntimeButton.isHidden == false
        )
    }

    private let formStackView = NSStackView()

    private let profilePopup = NSPopUpButton()
    private let addProfileButton = NSButton(
        title: VoiceChannelUIStrings.addChannel,
        target: nil,
        action: nil
    )
    private let removeProfileButton = NSButton(
        title: VoiceChannelUIStrings.deleteChannel,
        target: nil,
        action: nil
    )
    private let duplicateProfileButton = NSButton(
        title: VoiceChannelUIStrings.duplicateChannel,
        target: nil,
        action: nil
    )

    private let nameField = NSTextField()
    private let providerPopup = NSPopUpButton()
    private let providerDescriptionLabel = NSTextField(wrappingLabelWithString: "")
    private let recorderView = HotKeyRecorderView()
    private let hotKeyStatusLabel = NSTextField(labelWithString: "")
    private let modelField = NSTextField()
    private let voiceComboBox = NSComboBox()
    private var modelRow: NSStackView?
    private var voiceRow: NSStackView?
    private let endpointLabel = NSTextField(labelWithString: "Endpoint (wss://...)")
    private let endpointField = NSTextField()
    private let endpointRequiredLabel = NSTextField(labelWithString: "Required")
    private let endpointRow = NSStackView()
    private let speakerModePopup = NSPopUpButton()
    private var speakerModeRow: NSStackView?
    private let apiCredentialLabel = NSTextField(labelWithString: "")
    private let apiKeyField = NSSecureTextField()
    private let removeAPIKeyButton = NSButton(title: "Remove Key", target: nil, action: nil)
    private let credentialStatusLabel = NSTextField(labelWithString: "")
    private let webSearchCheckbox = NSButton(checkboxWithTitle: "Enable OpenAI web search (hosted tool)", target: nil, action: nil)
    private let mcpServerPopup = NSPopUpButton()
    private let addMCPServerButton = NSButton(title: "Add", target: nil, action: nil)
    private let editMCPServerButton = NSButton(title: "Edit", target: nil, action: nil)
    private let removeMCPServerButton = NSButton(title: "Remove", target: nil, action: nil)
    private var mcpSectionViews: [NSView] = []
    private let instructionsScrollView = NSScrollView()
    private let instructionsTextView = NSTextView()
    private let tipLabel = NSTextField(wrappingLabelWithString: "If the voice hears phrases you did not say, use headphones — speaker audio feeding back into the microphone causes phantom turns.")
    private let formStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private var openClawRuntimeSectionViews: [NSView] = []
    private let openClawSessionLabel = NSTextField(labelWithString: "")
    private let openClawModelField = NSTextField()
    private let openClawVoiceLabel = NSTextField(labelWithString: "")
    private let openClawVoicePopup = NSPopUpButton()
    private let openClawRuntimeCaption = NSTextField(wrappingLabelWithString: "")
    private let applyOpenClawRuntimeButton = NSButton(
        title: "Apply Gateway Settings",
        target: nil,
        action: nil
    )
    private let openClawRuntimeStatusLabel = NSTextField(wrappingLabelWithString: "")

    private static let labelColumnWidth: CGFloat = 140
    private static let hotKeyHint = "Click the field, then press the new shortcut."

    init(
        profiles: [VoiceProfile],
        openClawRuntimeService: OpenClawRuntimeSettingsServing = OpenClawRuntimeSettingsService()
    ) {
        let initialProfiles = profiles.isEmpty ? [Self.makeDefaultProfile()] : profiles
        workingProfiles = initialProfiles
        selectedProfileID = initialProfiles[0].id
        providerSettingsCache = VoiceProfileProviderSettingsCache(profiles: initialProfiles)
        self.openClawRuntimeService = openClawRuntimeService
        openClawRuntimePanelState = OpenClawRuntimePanelState(
            settings: .staticFallback,
            approvedScopes: openClawRuntimeService.approvedScopes,
            loadError: nil
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = VoiceChannelUIStrings.windowTitle
        window.contentMinSize = NSSize(width: 540, height: 560)
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
        window.delegate = self

        buildContent()
        rebuildProfilePopup()
        syncFormFromSelectedProfile()
        updateProfileButtons()

        recorderView.onHotKeyRecorded = { [weak self] profileID, hotKey in
            self?.handleRecordedHotKey(hotKey, forProfileID: profileID)
        }
        recorderView.onRecordingStateChanged = { [weak self] isRecording in
            guard let self else { return }
            self.delegate?.settingsController(self, isRecordingHotKey: isRecording)
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

    func beginHotKeyRecording() {
        recorderView.beginRecording()
    }

    func cancelHotKeyRecording() {
        recorderView.cancelRecording()
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
        configureSpeakerModePopup()
        configureOpenClawRuntimeControls()
        configureInstructionsEditor()
        configureStaticControls()
        configureMCPServerControls()

        // Voice channel: picker with add/delete/duplicate, plus the display name.
        addSection(VoiceChannelUIStrings.channelSectionTitle)
        addArranged(makeControlRow(
            views: [profilePopup, addProfileButton, removeProfileButton, duplicateProfileButton],
            stretching: profilePopup
        ))
        let nameRow = makeRow(label: "Name", views: [nameField], stretching: nameField)
        addArranged(nameRow)
        endSection(after: nameRow)

        // Voice Provider: adapter choice plus its model/voice/endpoint knobs.
        addSection("Voice Provider")
        let providerRow = makeRow(
            label: "Provider",
            views: [providerPopup],
            stretching: providerPopup
        )
        addArranged(providerRow)
        formStackView.setCustomSpacing(4, after: providerRow)
        addArranged(indentedRow(providerDescriptionLabel))
        let modelRow = makeRow(
            label: "Model",
            views: [modelField],
            stretching: modelField
        )
        self.modelRow = modelRow
        addArranged(modelRow)
        let voiceRow = makeRow(
            label: "Voice",
            views: [voiceComboBox],
            stretching: voiceComboBox
        )
        self.voiceRow = voiceRow
        addArranged(voiceRow)
        let speakerModeRow = makeRow(
            label: VoiceChannelUIStrings.speakerModeLabel,
            views: [speakerModePopup],
            stretching: speakerModePopup
        )
        self.speakerModeRow = speakerModeRow
        addArranged(speakerModeRow)

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

        // OpenClaw owns these values at the gateway. Scope determines whether the
        // paired device may edit them; the section never requests broader scopes.
        let runtimeHeader = sectionLabel("OpenClaw runtime")
        let runtimeSeparator = makeSeparator()
        let runtimeSessionRow = makeRow(
            label: "Consult session",
            views: [openClawSessionLabel],
            stretching: openClawSessionLabel
        )
        let runtimeModelRow = makeRow(
            label: "Pinned consult model",
            views: [openClawModelField],
            stretching: openClawModelField
        )
        let runtimeVoiceControls = NSStackView(
            views: [openClawVoiceLabel, openClawVoicePopup]
        )
        runtimeVoiceControls.orientation = .horizontal
        runtimeVoiceControls.alignment = .centerY
        runtimeVoiceControls.spacing = 8
        let runtimeVoiceRow = makeRow(
            label: "Gateway talk voice",
            views: [runtimeVoiceControls],
            stretching: runtimeVoiceControls
        )
        let runtimeApplySpacer = NSView()
        runtimeApplySpacer.translatesAutoresizingMaskIntoConstraints = false
        runtimeApplySpacer.setContentHuggingPriority(
            NSLayoutConstraint.Priority(1),
            for: .horizontal
        )
        let runtimeApplyRow = NSStackView(
            views: [runtimeApplySpacer, applyOpenClawRuntimeButton]
        )
        runtimeApplyRow.orientation = .horizontal
        runtimeApplyRow.translatesAutoresizingMaskIntoConstraints = false
        openClawRuntimeSectionViews = [
            runtimeHeader,
            runtimeSeparator,
            runtimeSessionRow,
            runtimeModelRow,
            runtimeVoiceRow,
            openClawRuntimeCaption,
            openClawRuntimeStatusLabel,
            runtimeApplyRow
        ]
        for view in openClawRuntimeSectionViews {
            addArranged(view)
        }
        formStackView.setCustomSpacing(4, after: runtimeHeader)
        formStackView.setCustomSpacing(4, after: openClawRuntimeCaption)
        endSection(after: runtimeApplyRow)

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

        // MCP tools are declared to OpenAI-protocol channels and executed there.
        let mcpHeader = sectionLabel("Tools")
        let mcpSeparator = makeSeparator()
        let mcpRow = makeControlRow(
            views: [
                mcpServerPopup,
                addMCPServerButton,
                editMCPServerButton,
                removeMCPServerButton
            ],
            stretching: mcpServerPopup
        )
        mcpSectionViews = [mcpHeader, mcpSeparator, webSearchCheckbox, mcpRow]
        addArranged(mcpHeader)
        formStackView.setCustomSpacing(4, after: mcpHeader)
        addArranged(mcpSeparator)
        addArranged(webSearchCheckbox)
        addArranged(mcpRow)
        endSection(after: mcpRow)

        // Instructions: system prompt for the selected voice channel.
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
        configureProfileButton(
            addProfileButton,
            symbolName: "plus",
            toolTip: VoiceChannelUIStrings.addChannel,
            action: #selector(addProfile)
        )
        configureProfileButton(
            removeProfileButton,
            symbolName: "minus",
            toolTip: VoiceChannelUIStrings.deleteChannel,
            action: #selector(removeProfileWithConfirmation)
        )
        configureProfileButton(
            duplicateProfileButton,
            symbolName: "plus.square.on.square",
            toolTip: VoiceChannelUIStrings.duplicateChannel,
            action: #selector(duplicateProfile)
        )
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

        providerDescriptionLabel.font = NSFont.systemFont(ofSize: 11)
        providerDescriptionLabel.textColor = .secondaryLabelColor
    }

    private func configureSpeakerModePopup() {
        speakerModePopup.translatesAutoresizingMaskIntoConstraints = false
        speakerModePopup.removeAllItems()
        for preference in OpenAISpeakerModePreference.allCases {
            speakerModePopup.addItem(withTitle: preference.displayName)
            speakerModePopup.lastItem?.representedObject = preference.rawValue
        }
        speakerModePopup.toolTip =
            "Controls speaker echo handling for this voice channel. Auto uses headphone behavior for Bluetooth and the built-in headphone jack; USB defaults to speaker behavior."
    }

    private func configureOpenClawRuntimeControls() {
        openClawSessionLabel.font = NSFont.monospacedSystemFont(
            ofSize: 12,
            weight: .regular
        )
        openClawSessionLabel.isSelectable = true

        openClawModelField.font = NSFont.monospacedSystemFont(
            ofSize: 12,
            weight: .regular
        )
        openClawModelField.placeholderString = "provider/model"

        openClawVoiceLabel.font = NSFont.monospacedSystemFont(
            ofSize: 12,
            weight: .regular
        )
        openClawVoiceLabel.isSelectable = true
        openClawVoicePopup.removeAllItems()
        openClawVoicePopup.addItems(
            withTitles: OpenClawRuntimeSettings.voiceOptions
        )

        openClawRuntimeCaption.font = NSFont.systemFont(ofSize: 11)
        openClawRuntimeCaption.textColor = .secondaryLabelColor
        openClawRuntimeStatusLabel.font = NSFont.systemFont(ofSize: 11)
        openClawRuntimeStatusLabel.isHidden = true

        applyOpenClawRuntimeButton.bezelStyle = .rounded
        applyOpenClawRuntimeButton.target = self
        applyOpenClawRuntimeButton.action = #selector(applyOpenClawRuntimeSettings)
    }

    private func configureMCPServerControls() {
        mcpServerPopup.translatesAutoresizingMaskIntoConstraints = false
        mcpServerPopup.setContentHuggingPriority(
            NSLayoutConstraint.Priority(1),
            for: .horizontal
        )
        mcpServerPopup.target = self
        mcpServerPopup.action = #selector(mcpServerSelectionChanged)

        for button in [addMCPServerButton, editMCPServerButton, removeMCPServerButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.translatesAutoresizingMaskIntoConstraints = false
            button.target = self
        }
        addMCPServerButton.action = #selector(addMCPServer)
        editMCPServerButton.action = #selector(editMCPServer)
        removeMCPServerButton.action = #selector(removeMCPServer)
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
        nameField.placeholderString = VoiceChannelUIStrings.channelNamePlaceholder

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
        VoiceProfile.defaultOpenAI(name: VoiceProviderID.openAIRealtime.displayName)
    }

    private func adoptProfiles(_ newValue: [VoiceProfile]) {
        // While the window is visible the working copy owns the form; replacing it mid-edit
        // would discard in-progress values. Re-opening the window resets to persisted state.
        guard window?.isVisible != true else { return }

        let nextProfiles = newValue.isEmpty ? [Self.makeDefaultProfile()] : newValue
        workingProfiles = nextProfiles
        providerSettingsCache = VoiceProfileProviderSettingsCache(profiles: nextProfiles)
        pendingMCPAuthorizationValues.removeAll()
        pendingMCPAuthorizationDeletions.removeAll()
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
        profile.webSearchEnabled = webSearchCheckbox.state == .on
        if let raw = speakerModePopup.selectedItem?.representedObject as? String,
           let preference = OpenAISpeakerModePreference(rawValue: raw) {
            profile.speakerModePreference = preference
        }
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
        providerDescriptionLabel.stringValue = provider.settingsDescription

        recorderView.profileID = profile.id
        recorderView.hotKey = profile.hotKey
        resetHotKeyStatus()

        modelRow?.isHidden = provider == .openClaw
        modelField.isEnabled = provider.supportsModelSetting
        modelField.placeholderString = provider.defaultModel
        let model = profile.model.trimmingCharacters(in: .whitespacesAndNewlines)
        modelField.stringValue = provider.supportsModelSetting && model.isEmpty == false ? model : provider.defaultModel

        voiceRow?.isHidden = provider == .openClaw
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
        speakerModeRow?.isHidden =
            provider != .openAIRealtime && provider != .openClaw
        if let index = speakerModePopup.itemArray.firstIndex(where: {
            ($0.representedObject as? String) == profile.speakerModePreference.rawValue
        }) {
            speakerModePopup.selectItem(at: index)
        }

        instructionsTextView.string = profile.instructions
        instructionsTextView.isEditable = provider != .chatGPTWeb

        apiCredentialLabel.stringValue = provider.credentialLabel
        apiKeyField.stringValue = ""
        syncCredentialStatus(for: provider)
        syncMCPServerControls(for: profile)
        syncOpenClawRuntimePanel(for: profile)

        clearFormStatus()
    }

    private func syncOpenClawRuntimePanel(for profile: VoiceProfile) {
        let isOpenClaw = profile.providerID == .openClaw
        for view in openClawRuntimeSectionViews {
            view.isHidden = isOpenClaw == false
        }
        guard isOpenClaw else {
            openClawRuntimeLoadGeneration = UUID()
            return
        }

        openClawRuntimePanelState.approvedScopes =
            openClawRuntimeService.approvedScopes
        openClawRuntimePanelState.loadError = nil
        renderOpenClawRuntimePanel()

        let generation = UUID()
        openClawRuntimeLoadGeneration = generation
        openClawRuntimeService.load(endpointURL: profile.endpointURL) {
            [weak self] result in
            DispatchQueue.main.async {
                guard let self,
                      self.openClawRuntimeLoadGeneration == generation,
                      self.selectedProfileID == profile.id else {
                    return
                }
                switch result {
                case let .success(settings):
                    self.openClawRuntimePanelState.settings = settings
                    self.openClawRuntimePanelState.loadError = nil
                case let .failure(error):
                    self.openClawRuntimePanelState.settings = .staticFallback
                    self.openClawRuntimePanelState.loadError =
                        error.localizedDescription
                }
                self.renderOpenClawRuntimePanel()
            }
        }
    }

    private func renderOpenClawRuntimePanel() {
        let settings = openClawRuntimePanelState.settings
        let isEditable = openClawRuntimePanelState.isEditable
        openClawSessionLabel.stringValue = settings.sessionKey
        openClawModelField.stringValue = settings.model
        openClawModelField.isEditable = isEditable
        openClawModelField.isSelectable = true
        openClawModelField.isBezeled = isEditable
        openClawModelField.drawsBackground = isEditable

        openClawVoiceLabel.stringValue = settings.voice
        openClawVoiceLabel.isHidden = isEditable
        openClawVoicePopup.isHidden = isEditable == false
        if let index = openClawVoicePopup.itemTitles.firstIndex(
            of: settings.voice
        ) {
            openClawVoicePopup.selectItem(at: index)
        }
        applyOpenClawRuntimeButton.isHidden = isEditable == false
        applyOpenClawRuntimeButton.isEnabled = isEditable
        openClawRuntimeCaption.stringValue =
            openClawRuntimePanelState.caption
        openClawRuntimeStatusLabel.stringValue = ""
        openClawRuntimeStatusLabel.isHidden = true
    }

    private func syncMCPServerControls(for profile: VoiceProfile) {
        let supportsMCP = [.openAIRealtime, .custom].contains(profile.providerID)
        for view in mcpSectionViews {
            view.isHidden = supportsMCP == false
        }
        // Hosted web search is an OpenAI platform feature, not part of the
        // generic realtime protocol, so only OpenAI profiles offer it.
        webSearchCheckbox.isHidden = profile.providerID != .openAIRealtime
        webSearchCheckbox.state = profile.webSearchEnabled ? .on : .off
        guard supportsMCP else { return }

        let selectedID = mcpServerPopup.selectedItem?.representedObject as? String
        mcpServerPopup.removeAllItems()
        if profile.mcpServers.isEmpty {
            mcpServerPopup.addItem(withTitle: "No servers configured")
            mcpServerPopup.lastItem?.isEnabled = false
        } else {
            for server in profile.mcpServers {
                mcpServerPopup.addItem(
                    withTitle: "\(server.label) — \(server.urlString)"
                )
                mcpServerPopup.lastItem?.representedObject = server.id.uuidString
            }
            if let selectedID,
               let index = mcpServerPopup.itemArray.firstIndex(where: {
                   ($0.representedObject as? String) == selectedID
               }) {
                mcpServerPopup.selectItem(at: index)
            }
        }
        updateMCPServerButtons()
    }

    private func updateMCPServerButtons() {
        guard let index = selectedProfileIndex else { return }
        let hasServers = workingProfiles[index].mcpServers.isEmpty == false
        editMCPServerButton.isEnabled = hasServers
        removeMCPServerButton.isEnabled = hasServers
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

    // MARK: - Voice channel picker actions

    @objc private func profileSelectionChanged() {
        guard let raw = profilePopup.selectedItem?.representedObject as? String,
              let id = UUID(uuidString: raw),
              id != selectedProfileID else { return }
        commitFormToWorkingCopy()
        selectProfile(id: id)
    }

    @objc private func addProfile() {
        commitFormToWorkingCopy()
        guard let provider = chooseProviderForNewChannel() else { return }
        let profile = VoiceChannelOperations.makeChannel(
            provider: provider,
            existingNames: workingProfiles.map(\.name)
        )
        workingProfiles.append(profile)
        providerSettingsCache.remember(profile)
        selectProfile(id: profile.id)
        updateProfileButtons()
    }

    @objc private func duplicateProfile() {
        guard let sourceIndex = selectedProfileIndex else { return }
        commitFormToWorkingCopy()
        let source = workingProfiles[sourceIndex]
        let copy = VoiceChannelOperations.duplicate(
            source,
            existingNames: workingProfiles.map(\.name)
        )
        for (sourceServer, copiedServer) in zip(
            source.mcpServers,
            copy.mcpServers
        ) {
            if let token = effectiveMCPAuthorization(for: sourceServer.id) {
                pendingMCPAuthorizationValues[copiedServer.id] = token
            }
        }
        workingProfiles.insert(copy, at: sourceIndex + 1)
        providerSettingsCache.remember(copy)
        selectProfile(id: copy.id)
        updateProfileButtons()
    }

    @objc private func removeProfileWithConfirmation() {
        guard workingProfiles.count > 1, let index = selectedProfileIndex else { return }
        let name = displayName(for: workingProfiles[index])

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete voice channel “\(name)”?"
        alert.informativeText = "This can’t be undone. If this channel is active, its voice session will stop when you save."
        alert.addButton(withTitle: VoiceChannelUIStrings.deleteChannel)
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let removedProfile = workingProfiles[index]
        let removedProfileID = removedProfile.id
        for server in removedProfile.mcpServers {
            scheduleMCPAuthorizationDeletion(for: server.id)
        }
        workingProfiles.remove(at: index)
        providerSettingsCache.remove(profileID: removedProfileID)
        selectedProfileID = workingProfiles[min(index, workingProfiles.count - 1)].id
        rebuildProfilePopup()
        syncFormFromSelectedProfile()
        updateProfileButtons()
    }

    private func chooseProviderForNewChannel() -> VoiceProviderID? {
        let picker = VoiceChannelProviderPickerView()
        let alert = NSAlert()
        alert.messageText = "Add Voice Channel"
        alert.informativeText = "Choose how this voice channel connects."
        alert.accessoryView = picker
        alert.addButton(withTitle: VoiceChannelUIStrings.addChannel)
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }
        return picker.selectedProvider
    }

    // MARK: - MCP server actions

    @objc private func mcpServerSelectionChanged() {
        updateMCPServerButtons()
    }

    @objc private func addMCPServer() {
        guard let index = selectedProfileIndex,
              [.openAIRealtime, .custom].contains(workingProfiles[index].providerID),
              let result = editMCPServerConfiguration(nil) else {
            return
        }
        workingProfiles[index].mcpServers.append(result.configuration)
        stageMCPAuthorization(
            result.authorization,
            for: result.configuration.id
        )
        syncMCPServerControls(for: workingProfiles[index])
        mcpServerPopup.selectItem(at: workingProfiles[index].mcpServers.count - 1)
        updateMCPServerButtons()
    }

    @objc private func editMCPServer() {
        guard let profileIndex = selectedProfileIndex,
              let serverIndex = selectedMCPServerIndex(for: workingProfiles[profileIndex]),
              let result = editMCPServerConfiguration(
                  workingProfiles[profileIndex].mcpServers[serverIndex]
              ) else {
            return
        }
        workingProfiles[profileIndex].mcpServers[serverIndex] = result.configuration
        stageMCPAuthorization(
            result.authorization,
            for: result.configuration.id
        )
        syncMCPServerControls(for: workingProfiles[profileIndex])
        mcpServerPopup.selectItem(at: serverIndex)
        updateMCPServerButtons()
    }

    @objc private func removeMCPServer() {
        guard let profileIndex = selectedProfileIndex,
              let serverIndex = selectedMCPServerIndex(for: workingProfiles[profileIndex]) else {
            return
        }
        let server = workingProfiles[profileIndex].mcpServers.remove(at: serverIndex)
        scheduleMCPAuthorizationDeletion(for: server.id)
        syncMCPServerControls(for: workingProfiles[profileIndex])
    }

    private func selectedMCPServerIndex(for profile: VoiceProfile) -> Int? {
        guard let rawID = mcpServerPopup.selectedItem?.representedObject as? String,
              let id = UUID(uuidString: rawID) else {
            return nil
        }
        return profile.mcpServers.firstIndex(where: { $0.id == id })
    }

    private struct MCPServerEditorResult {
        var configuration: MCPServerConfiguration
        var authorization: String?
    }

    private func editMCPServerConfiguration(
        _ existing: MCPServerConfiguration?
    ) -> MCPServerEditorResult? {
        let labelField = NSTextField(string: existing?.label ?? "")
        labelField.placeholderString = "calendar"
        let urlField = NSTextField(string: existing?.urlString ?? "")
        urlField.placeholderString = "https://mcp.example.com"
        let allowedToolsField = NSTextField(
            string: existing?.allowedTools?.joined(separator: ", ") ?? ""
        )
        allowedToolsField.placeholderString = "search, create_event (optional)"
        let authorizationField = NSSecureTextField(
            string: existing.flatMap {
                effectiveMCPAuthorization(for: $0.id)
            } ?? ""
        )
        authorizationField.placeholderString = "Optional bearer token"

        let editor = NSGridView(views: [
            [NSTextField(labelWithString: "Label"), labelField],
            [NSTextField(labelWithString: "URL"), urlField],
            [NSTextField(labelWithString: "Allowed tools"), allowedToolsField],
            [NSTextField(labelWithString: "Authorization"), authorizationField]
        ])
        editor.rowSpacing = 8
        editor.columnSpacing = 12
        editor.column(at: 0).xPlacement = .trailing
        editor.column(at: 1).width = 320

        let alert = NSAlert()
        alert.messageText = existing == nil ? "Add MCP Server" : "Edit MCP Server"
        alert.informativeText = "VoiceKey declares this server to the realtime channel. The channel executes its tools."
        alert.accessoryView = editor
        alert.addButton(withTitle: existing == nil ? "Add" : "Save")
        alert.addButton(withTitle: "Cancel")
        window?.makeFirstResponder(labelField)

        while alert.runModal() == .alertFirstButtonReturn {
            let label = labelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let urlString = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if label.isEmpty {
                alert.informativeText = "Enter a server label."
                continue
            }
            if isValidMCPServerURL(urlString) == false {
                alert.informativeText = "Enter an http:// or https:// URL with a host."
                continue
            }

            let allowedTools = allowedToolsField.stringValue
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.isEmpty == false }
            return MCPServerEditorResult(
                configuration: MCPServerConfiguration(
                    id: existing?.id ?? UUID(),
                    label: label,
                    urlString: urlString,
                    allowedTools: allowedTools.isEmpty ? nil : allowedTools
                ),
                authorization: authorizationField.stringValue
            )
        }
        return nil
    }

    private func effectiveMCPAuthorization(for id: UUID) -> String? {
        if pendingMCPAuthorizationDeletions.contains(id) {
            return nil
        }
        return pendingMCPAuthorizationValues[id]
            ?? APIKeyStore.shared.authorizationToken(forMCPServer: id)
    }

    private func stageMCPAuthorization(_ authorization: String?, for id: UUID) {
        let trimmed = authorization?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            scheduleMCPAuthorizationDeletion(for: id)
        } else {
            pendingMCPAuthorizationDeletions.remove(id)
            pendingMCPAuthorizationValues[id] = trimmed
        }
    }

    private func scheduleMCPAuthorizationDeletion(for id: UUID) {
        pendingMCPAuthorizationValues[id] = nil
        pendingMCPAuthorizationDeletions.insert(id)
    }

    // MARK: - Provider / hotkey actions

    @objc private func providerChanged() {
        guard let index = selectedProfileIndex,
              let raw = providerPopup.selectedItem?.representedObject as? String,
              let provider = VoiceProviderID(rawValue: raw) else { return }
        let previousProvider = workingProfiles[index].providerID
        guard provider != previousProvider else { return }

        // The popup already shows the destination, so commit temporarily adopts it.
        // Restore the source provider before stashing the fields that are still onscreen.
        commitFormToWorkingCopy()
        workingProfiles[index].providerID = previousProvider
        providerSettingsCache.remember(workingProfiles[index])
        workingProfiles[index].providerID = provider
        let settings = providerSettingsCache.settings(
            for: workingProfiles[index].id,
            provider: provider
        )
        workingProfiles[index].model = settings?.model ?? provider.defaultModel
        workingProfiles[index].voice = settings?.voice ?? provider.defaultVoice
        syncFormFromSelectedProfile()
    }

    private func handleRecordedHotKey(_ hotKey: HotKeyConfiguration, forProfileID profileID: UUID) {
        guard let index = workingProfiles.firstIndex(where: { $0.id == profileID }) else { return }

        if let conflict = workingProfiles.first(where: { $0.id != profileID && isSameHotKey($0.hotKey, hotKey) }) {
            recorderView.hotKey = workingProfiles[index].hotKey
            showHotKeyError("Already used by \(displayName(for: conflict))")
            return
        }

        let accepted = delegate?.settingsController(
            self,
            didRecordHotKey: hotKey,
            for: workingProfiles[index]
        ) ?? false
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

    // MARK: - Gateway runtime / save / API key actions

    @objc private func applyOpenClawRuntimeSettings() {
        guard let index = selectedProfileIndex,
              workingProfiles[index].providerID == .openClaw,
              openClawRuntimePanelState.isEditable else {
            showOpenClawRuntimeError(
                "The paired device is not approved for operator.admin."
            )
            return
        }
        let model = openClawModelField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard model.isEmpty == false else {
            showOpenClawRuntimeError(
                "Enter the gateway model as a provider/model string."
            )
            return
        }
        guard let voice = openClawVoicePopup.selectedItem?.title,
              OpenClawRuntimeSettings.voiceOptions.contains(voice) else {
            showOpenClawRuntimeError("Choose a supported realtime voice.")
            return
        }

        applyOpenClawRuntimeButton.isEnabled = false
        openClawRuntimeStatusLabel.stringValue =
            "Applying gateway-managed settings…"
        openClawRuntimeStatusLabel.textColor = .secondaryLabelColor
        openClawRuntimeStatusLabel.isHidden = false
        let profileID = workingProfiles[index].id
        let endpointURL = endpointField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
        openClawRuntimeService.apply(
            model: model,
            voice: voice,
            endpointURL: endpointURL
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self,
                      self.selectedProfileID == profileID else {
                    return
                }
                self.applyOpenClawRuntimeButton.isEnabled = true
                switch result {
                case let .success(settings):
                    self.openClawRuntimePanelState.settings = settings
                    self.openClawRuntimePanelState.loadError = nil
                    self.renderOpenClawRuntimePanel()
                    self.openClawRuntimeStatusLabel.stringValue =
                        "Gateway settings applied."
                    self.openClawRuntimeStatusLabel.textColor =
                        .secondaryLabelColor
                    self.openClawRuntimeStatusLabel.isHidden = false
                case let .failure(error):
                    self.showOpenClawRuntimeError(
                        "Gateway update failed: \(error.localizedDescription)"
                    )
                }
            }
        }
    }

    private func showOpenClawRuntimeError(_ message: String) {
        openClawRuntimeStatusLabel.stringValue = message
        openClawRuntimeStatusLabel.textColor = .systemRed
        openClawRuntimeStatusLabel.isHidden = false
    }

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
            if let message = mcpValidationError(for: profile) {
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
        for profile in normalized {
            providerSettingsCache.remember(profile)
        }

        do {
            try savePendingMCPAuthorizations()
        } catch {
            showFormError("Couldn’t save an MCP authorization token: \(error.localizedDescription)")
            return
        }
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
            delegate?.settingsControllerDidUpdateCredentials(self)
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
            normalized.mcpServers = profile.mcpServers.map { server in
                let allowedTools = server.allowedTools?
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { $0.isEmpty == false }
                return MCPServerConfiguration(
                    id: server.id,
                    label: server.label.trimmingCharacters(in: .whitespacesAndNewlines),
                    urlString: server.urlString.trimmingCharacters(in: .whitespacesAndNewlines),
                    allowedTools: allowedTools?.isEmpty == false ? allowedTools : nil
                )
            }
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

    private func mcpValidationError(for profile: VoiceProfile) -> String? {
        for server in profile.mcpServers {
            if server.label.isEmpty {
                return "An MCP server in “\(displayName(for: profile))” needs a label."
            }
            if isValidMCPServerURL(server.urlString) == false {
                return "The MCP server URL for “\(server.label)” must start with http:// or https:// and include a host."
            }
        }
        return nil
    }

    private func isValidMCPServerURL(_ string: String) -> Bool {
        guard let components = URLComponents(string: string),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host,
              host.isEmpty == false else {
            return false
        }
        return true
    }

    private func savePendingMCPAuthorizations() throws {
        for (id, token) in pendingMCPAuthorizationValues {
            try APIKeyStore.shared.setAuthorizationToken(token, forMCPServer: id)
        }
        for id in pendingMCPAuthorizationDeletions {
            try APIKeyStore.shared.deleteAuthorizationToken(forMCPServer: id)
        }
        pendingMCPAuthorizationValues.removeAll()
        pendingMCPAuthorizationDeletions.removeAll()
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

extension SettingsWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        cancelHotKeyRecording()
    }

    func windowDidResignKey(_ notification: Notification) {
        cancelHotKeyRecording()
    }
}

final class VoiceChannelProviderPickerView: NSView {
    private let popup = NSPopUpButton()
    private let descriptionLabel = NSTextField(wrappingLabelWithString: "")

    var selectedProvider: VoiceProviderID? {
        guard let rawValue = popup.selectedItem?.representedObject as? String else {
            return nil
        }
        return VoiceProviderID(rawValue: rawValue)
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 440, height: 72))

        popup.translatesAutoresizingMaskIntoConstraints = false
        for provider in VoiceProviderID.allCases {
            let suffix = provider.isImplemented ? "" : " (coming soon)"
            popup.addItem(withTitle: provider.displayName + suffix)
            popup.lastItem?.representedObject = provider.rawValue
            popup.lastItem?.isEnabled = provider.isImplemented
        }
        if let firstImplemented = popup.itemArray.firstIndex(where: {
            $0.isEnabled
        }) {
            popup.selectItem(at: firstImplemented)
        }
        popup.target = self
        popup.action = #selector(selectionChanged)

        descriptionLabel.font = NSFont.systemFont(ofSize: 12)
        descriptionLabel.textColor = .secondaryLabelColor
        descriptionLabel.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [popup, descriptionLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            popup.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        selectionChanged()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func selectionChanged() {
        descriptionLabel.stringValue =
            selectedProvider?.settingsDescription ?? ""
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
    var onRecordingStateChanged: ((Bool) -> Void)?

    private(set) var isRecording = false {
        didSet {
            needsDisplay = true
            if isRecording != oldValue {
                onRecordingStateChanged?(isRecording)
            }
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
        beginRecording()
    }

    override func resignFirstResponder() -> Bool {
        cancelRecording()
        return super.resignFirstResponder()
    }

    func beginRecording() {
        isRecording = true
    }

    func cancelRecording() {
        isRecording = false
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            cancelRecording()
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

        cancelRecording()
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
