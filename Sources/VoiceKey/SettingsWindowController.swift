import AppKit
import Carbon

protocol SettingsWindowControllerDelegate: AnyObject {
    func settingsWindowController(
        _ controller: SettingsWindowController,
        didRecord hotKey: HotKeyConfiguration
    )
    func settingsWindowController(
        _ controller: SettingsWindowController,
        didUpdate configuration: VoiceSessionConfiguration
    )
    func settingsWindowControllerDidUpdateAPIKey(_ controller: SettingsWindowController)
}

final class SettingsWindowController: NSWindowController {
    weak var delegate: SettingsWindowControllerDelegate?

    var hotKey: HotKeyConfiguration {
        didSet {
            recorderView.hotKey = hotKey
            currentShortcutLabel.stringValue = hotKey.displayName
        }
    }

    var configuration: VoiceSessionConfiguration {
        didSet {
            syncProviderControls()
        }
    }

    private let recorderView: HotKeyRecorderView
    private let currentShortcutLabel = NSTextField(labelWithString: "")
    private let providerPopup = NSPopUpButton()
    private let modelField = NSTextField()
    private let voicePopup = NSPopUpButton()
    private let apiCredentialLabel = NSTextField(labelWithString: "")
    private let apiKeyField = NSSecureTextField()
    private let removeAPIKeyButton = NSButton(title: "Remove Key", target: nil, action: nil)
    private let credentialStatusLabel = NSTextField(labelWithString: "")
    private let instructionsField = NSTextField()

    init(hotKey: HotKeyConfiguration, configuration: VoiceSessionConfiguration) {
        self.hotKey = hotKey
        self.configuration = configuration
        self.recorderView = HotKeyRecorderView(hotKey: hotKey)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "VoiceKey Settings"
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)

        buildContent()
        recorderView.onHotKeyRecorded = { [weak self] hotKey in
            guard let self else { return }
            delegate?.settingsWindowController(self, didRecord: hotKey)
        }
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

    private func buildContent() {
        guard let contentView = window?.contentView else { return }

        let titleLabel = NSTextField(labelWithString: "VoiceKey")
        titleLabel.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let subtitleLabel = NSTextField(labelWithString: "Realtime voice settings")
        subtitleLabel.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        let providerLabel = formLabel("Provider")
        let modelLabel = formLabel("Model")
        let voiceLabel = formLabel("Voice")
        apiCredentialLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        apiCredentialLabel.translatesAutoresizingMaskIntoConstraints = false
        credentialStatusLabel.font = NSFont.systemFont(ofSize: 12)
        credentialStatusLabel.textColor = .tertiaryLabelColor
        credentialStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        let instructionsLabel = formLabel("Instructions")
        let hotKeyLabel = NSTextField(labelWithString: "Hotkey")
        hotKeyLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        hotKeyLabel.translatesAutoresizingMaskIntoConstraints = false

        currentShortcutLabel.stringValue = hotKey.displayName
        currentShortcutLabel.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
        currentShortcutLabel.textColor = .secondaryLabelColor
        currentShortcutLabel.translatesAutoresizingMaskIntoConstraints = false

        recorderView.translatesAutoresizingMaskIntoConstraints = false

        configureProviderControls()

        removeAPIKeyButton.target = self
        removeAPIKeyButton.action = #selector(removeAPIKey)
        removeAPIKeyButton.bezelStyle = .rounded
        removeAPIKeyButton.translatesAutoresizingMaskIntoConstraints = false

        let saveButton = NSButton(title: "Save Voice Settings", target: self, action: #selector(saveVoiceSettings))
        saveButton.bezelStyle = .rounded
        saveButton.translatesAutoresizingMaskIntoConstraints = false

        let hintLabel = NSTextField(labelWithString: "Click the field, then press the new shortcut.")
        hintLabel.font = NSFont.systemFont(ofSize: 12)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(titleLabel)
        contentView.addSubview(subtitleLabel)
        contentView.addSubview(providerLabel)
        contentView.addSubview(providerPopup)
        contentView.addSubview(modelLabel)
        contentView.addSubview(modelField)
        contentView.addSubview(voiceLabel)
        contentView.addSubview(voicePopup)
        contentView.addSubview(apiCredentialLabel)
        contentView.addSubview(apiKeyField)
        contentView.addSubview(removeAPIKeyButton)
        contentView.addSubview(credentialStatusLabel)
        contentView.addSubview(instructionsLabel)
        contentView.addSubview(instructionsField)
        contentView.addSubview(saveButton)
        contentView.addSubview(hotKeyLabel)
        contentView.addSubview(currentShortcutLabel)
        contentView.addSubview(recorderView)
        contentView.addSubview(hintLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),

            providerLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            providerLabel.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 28),
            providerLabel.widthAnchor.constraint(equalToConstant: 110),
            providerPopup.leadingAnchor.constraint(equalTo: providerLabel.trailingAnchor, constant: 12),
            providerPopup.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            providerPopup.centerYAnchor.constraint(equalTo: providerLabel.centerYAnchor),

            modelLabel.leadingAnchor.constraint(equalTo: providerLabel.leadingAnchor),
            modelLabel.topAnchor.constraint(equalTo: providerLabel.bottomAnchor, constant: 18),
            modelLabel.widthAnchor.constraint(equalTo: providerLabel.widthAnchor),
            modelField.leadingAnchor.constraint(equalTo: providerPopup.leadingAnchor),
            modelField.trailingAnchor.constraint(equalTo: providerPopup.trailingAnchor),
            modelField.centerYAnchor.constraint(equalTo: modelLabel.centerYAnchor),

            voiceLabel.leadingAnchor.constraint(equalTo: providerLabel.leadingAnchor),
            voiceLabel.topAnchor.constraint(equalTo: modelLabel.bottomAnchor, constant: 18),
            voiceLabel.widthAnchor.constraint(equalTo: providerLabel.widthAnchor),
            voicePopup.leadingAnchor.constraint(equalTo: providerPopup.leadingAnchor),
            voicePopup.trailingAnchor.constraint(equalTo: providerPopup.trailingAnchor),
            voicePopup.centerYAnchor.constraint(equalTo: voiceLabel.centerYAnchor),

            apiCredentialLabel.leadingAnchor.constraint(equalTo: providerLabel.leadingAnchor),
            apiCredentialLabel.topAnchor.constraint(equalTo: voiceLabel.bottomAnchor, constant: 18),
            apiCredentialLabel.widthAnchor.constraint(equalTo: providerLabel.widthAnchor),
            apiKeyField.leadingAnchor.constraint(equalTo: providerPopup.leadingAnchor),
            apiKeyField.trailingAnchor.constraint(equalTo: removeAPIKeyButton.leadingAnchor, constant: -8),
            apiKeyField.centerYAnchor.constraint(equalTo: apiCredentialLabel.centerYAnchor),
            removeAPIKeyButton.trailingAnchor.constraint(equalTo: providerPopup.trailingAnchor),
            removeAPIKeyButton.centerYAnchor.constraint(equalTo: apiKeyField.centerYAnchor),
            removeAPIKeyButton.widthAnchor.constraint(equalToConstant: 104),

            credentialStatusLabel.leadingAnchor.constraint(equalTo: providerPopup.leadingAnchor),
            credentialStatusLabel.trailingAnchor.constraint(equalTo: providerPopup.trailingAnchor),
            credentialStatusLabel.topAnchor.constraint(equalTo: apiKeyField.bottomAnchor, constant: 5),

            instructionsLabel.leadingAnchor.constraint(equalTo: providerLabel.leadingAnchor),
            instructionsLabel.topAnchor.constraint(equalTo: credentialStatusLabel.bottomAnchor, constant: 14),
            instructionsLabel.widthAnchor.constraint(equalTo: providerLabel.widthAnchor),
            instructionsField.leadingAnchor.constraint(equalTo: providerPopup.leadingAnchor),
            instructionsField.trailingAnchor.constraint(equalTo: providerPopup.trailingAnchor),
            instructionsField.centerYAnchor.constraint(equalTo: instructionsLabel.centerYAnchor),

            saveButton.trailingAnchor.constraint(equalTo: providerPopup.trailingAnchor),
            saveButton.topAnchor.constraint(equalTo: instructionsField.bottomAnchor, constant: 18),

            hotKeyLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            hotKeyLabel.topAnchor.constraint(equalTo: saveButton.bottomAnchor, constant: 28),

            currentShortcutLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            currentShortcutLabel.centerYAnchor.constraint(equalTo: hotKeyLabel.centerYAnchor),

            recorderView.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            recorderView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            recorderView.topAnchor.constraint(equalTo: hotKeyLabel.bottomAnchor, constant: 10),
            recorderView.heightAnchor.constraint(equalToConstant: 54),

            hintLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            hintLabel.topAnchor.constraint(equalTo: recorderView.bottomAnchor, constant: 10)
        ])
    }

    private func formLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func configureProviderControls() {
        for control in [providerPopup, modelField, voicePopup, apiKeyField, instructionsField] {
            control.translatesAutoresizingMaskIntoConstraints = false
        }

        providerPopup.removeAllItems()
        for provider in VoiceProviderID.allCases {
            let suffix = provider.isImplemented ? "" : " (coming soon)"
            providerPopup.addItem(withTitle: provider.displayName + suffix)
            providerPopup.lastItem?.representedObject = provider.rawValue
        }
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged)

        instructionsField.placeholderString = VoiceSessionConfiguration.defaultInstructions

        syncProviderControls()
    }

    private func syncProviderControls() {
        if let index = providerPopup.itemArray.firstIndex(where: { item in
            item.representedObject as? String == configuration.providerID.rawValue
        }) {
            providerPopup.selectItem(at: index)
        }

        let provider = configuration.providerID
        modelField.isEnabled = provider.supportsModelSetting
        modelField.placeholderString = provider.defaultModel
        modelField.stringValue = provider.supportsModelSetting ? configuration.model : provider.defaultModel

        voicePopup.isEnabled = provider.supportsVoiceSetting
        voicePopup.removeAllItems()
        provider.voiceOptions.forEach { voicePopup.addItem(withTitle: $0) }
        voicePopup.selectItem(withTitle: configuration.voice)
        if voicePopup.selectedItem == nil {
            voicePopup.selectItem(withTitle: provider.defaultVoice)
        }

        apiCredentialLabel.stringValue = provider.credentialLabel
        let credentialState = VoiceProviderCredentialViewState(
            provider: provider,
            hasAPIKey: APIKeyStore.shared.hasAPIKey(for: provider)
        )
        apiKeyField.isEnabled = credentialState.acceptsAPIKeyInput
        apiKeyField.placeholderString = provider.credentialPlaceholder
        if provider.requiresAPIKey == false {
            apiKeyField.stringValue = ""
        }
        removeAPIKeyButton.isEnabled = credentialState.canRemoveAPIKey
        removeAPIKeyButton.isHidden = provider.requiresAPIKey == false
        credentialStatusLabel.stringValue = credentialState.statusMessage

        instructionsField.isEnabled = provider != .chatGPTWeb
        instructionsField.stringValue = configuration.instructions
    }

    @objc private func providerChanged() {
        guard let raw = providerPopup.selectedItem?.representedObject as? String,
              let provider = VoiceProviderID(rawValue: raw) else { return }

        var nextConfiguration = provider.defaultConfiguration
        let instructions = instructionsField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if instructions.isEmpty == false, provider != .chatGPTWeb {
            nextConfiguration.instructions = instructions
        }
        configuration = nextConfiguration
    }

    @objc private func saveVoiceSettings() {
        guard let raw = providerPopup.selectedItem?.representedObject as? String,
              let provider = VoiceProviderID(rawValue: raw) else { return }

        let model = modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let instructions = instructionsField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextConfiguration = VoiceSessionConfiguration(
            providerID: provider,
            model: provider.supportsModelSetting && model.isEmpty == false ? model : provider.defaultModel,
            voice: provider.supportsVoiceSetting ? (voicePopup.selectedItem?.title ?? provider.defaultVoice) : provider.defaultVoice,
            instructions: provider != .chatGPTWeb && instructions.isEmpty == false ? instructions : VoiceSessionConfiguration.defaultInstructions
        )
        configuration = nextConfiguration
        VoiceProviderSettingsStore.save(nextConfiguration)

        let apiKey = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let credentialState = VoiceProviderCredentialViewState(
            provider: provider,
            hasAPIKey: APIKeyStore.shared.hasAPIKey(for: provider)
        )
        if credentialState.acceptsAPIKeyInput, apiKey.isEmpty == false {
            do {
                try APIKeyStore.shared.setAPIKey(apiKey, for: provider)
                apiKeyField.stringValue = ""
                syncProviderControls()
            } catch {
                NSSound.beep()
            }
        }

        delegate?.settingsWindowController(self, didUpdate: nextConfiguration)
        delegate?.settingsWindowControllerDidUpdateAPIKey(self)
    }

    @objc private func removeAPIKey() {
        guard let raw = providerPopup.selectedItem?.representedObject as? String,
              let provider = VoiceProviderID(rawValue: raw),
              provider.requiresAPIKey else { return }

        do {
            try APIKeyStore.shared.deleteAPIKey(for: provider)
            apiKeyField.stringValue = ""
            syncProviderControls()
            delegate?.settingsWindowControllerDidUpdateAPIKey(self)
        } catch {
            NSSound.beep()
        }
    }
}

final class HotKeyRecorderView: NSView {
    var hotKey: HotKeyConfiguration {
        didSet {
            needsDisplay = true
        }
    }

    var onHotKeyRecorded: ((HotKeyConfiguration) -> Void)?

    private var isRecording = false {
        didSet {
            needsDisplay = true
        }
    }

    init(hotKey: HotKeyConfiguration) {
        self.hotKey = hotKey
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
        onHotKeyRecorded?(recordedHotKey)
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

        let text = isRecording ? "Press shortcut" : hotKey.displayName
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 20, weight: .semibold),
            .foregroundColor: NSColor.labelColor
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
