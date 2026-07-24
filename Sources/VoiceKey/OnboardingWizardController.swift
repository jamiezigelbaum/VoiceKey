import AppKit
import ApplicationServices
import AVFoundation

protocol OnboardingWizardControllerDelegate: AnyObject {
    func onboardingController(
        _ controller: OnboardingWizardController,
        didRecordHotKey hotKey: HotKeyConfiguration,
        for profile: VoiceProfile
    ) -> Bool
    func onboardingController(
        _ controller: OnboardingWizardController,
        didUpdateCredentialsFor profile: VoiceProfile
    )
    func onboardingController(
        _ controller: OnboardingWizardController,
        isRecordingHotKey: Bool
    )
    func onboardingControllerGroundTruthDidChange(
        _ controller: OnboardingWizardController
    )
}

extension OnboardingWizardControllerDelegate {
    func onboardingController(
        _ controller: OnboardingWizardController,
        didUpdateCredentialsFor profile: VoiceProfile
    ) {}

    func onboardingControllerGroundTruthDidChange(
        _ controller: OnboardingWizardController
    ) {}
}

enum ApplicationRelocationError: LocalizedError {
    case noBundle
    case destinationExists(URL)
    case relaunchFailed

    var errorDescription: String? {
        switch self {
        case .noBundle:
            return "VoiceKey couldn’t find its app bundle."
        case let .destinationExists(url):
            return "An app already exists at \(url.path). Remove it, then try again."
        case .relaunchFailed:
            return "VoiceKey moved, but macOS couldn’t reopen it."
        }
    }
}

enum ApplicationRelocator {
    static func moveToApplicationsAndRelaunch(
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let source = Bundle.main.bundleURL
        guard source.pathExtension == "app" else {
            completion(.failure(ApplicationRelocationError.noBundle))
            return
        }
        let destination = URL(
            fileURLWithPath: "/Applications",
            isDirectory: true
        ).appendingPathComponent(
            source.lastPathComponent,
            isDirectory: true
        )
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: destination.path) == false else {
            completion(
                .failure(
                    ApplicationRelocationError.destinationExists(
                        destination
                    )
                )
            )
            return
        }

        do {
            if source.path.contains("/AppTranslocation/") {
                try fileManager.copyItem(
                    at: source,
                    to: destination
                )
            } else {
                try fileManager.moveItem(
                    at: source,
                    to: destination
                )
            }
        } catch {
            completion(.failure(error))
            return
        }

        let configuration =
            NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(
            at: destination,
            configuration: configuration
        ) { _, error in
            DispatchQueue.main.async {
                if let error {
                    completion(.failure(error))
                    return
                }
                completion(.success(()))
                NSApplication.shared.terminate(nil)
            }
        }
    }
}

final class OnboardingWizardController: NSWindowController {
    weak var delegate: OnboardingWizardControllerDelegate?

    static let keyPlaceholder = "Paste key here"
    static let keyCaption =
        "API keys are stored in Apple keychain and shared across channels of this provider."
    static let maskedKey = "••••••••••••"

    private let profileProvider: () -> [VoiceProfile]
    private let credentialStore: VoiceCredentialStoring
    private let apiKeyVerifier: APIKeyVerifying
    private let applicationLocationProvider:
        () -> ApplicationLocationState
    private let microphoneAuthorizationProvider:
        () -> MicrophoneAuthorizationState
    private let audioEngineFactory:
        () -> RealtimeAudioEngineProtocol
    private let openURL: (URL) -> Void
    private let moveApplication:
        (@escaping (Result<Void, Error>) -> Void) -> Void
    private let quitApplication: () -> Void

    private let contentStack = NSStackView()
    private var currentStep: OnboardingStep = .welcome
    private var handledSteps: Set<OnboardingStep> = []
    private var verificationState: APIKeyVerificationState = .idle
    private var enteredAPIKey = ""
    private var isChangingStoredKey = false
    private var isMovingApplication = false
    private var microphoneTimer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var audioEngine: RealtimeAudioEngineProtocol?
    private var inputLevelMeter: InputLevelMeterView?
    private var previewStatusLabel: NSTextField?
    private var apiKeyField: NSSecureTextField?
    private var hotKeyRecorder: HotKeyRecorderView?
    private var hotKeyStatusLabel: NSTextField?
    private var microphoneHelpIsExpanded = false
    private var relocationStatusMessage: String?

    init(
        profileProvider: @escaping () -> [VoiceProfile],
        credentialStore: VoiceCredentialStoring = APIKeyStore.shared,
        apiKeyVerifier: APIKeyVerifying = OpenAIAPIKeyVerifier(),
        applicationLocationProvider: @escaping (
        ) -> ApplicationLocationState = {
            ApplicationLocationState.detect(
                executableURL: Bundle.main.executableURL,
                bundleURL: Bundle.main.bundleURL
            )
        },
        microphoneAuthorizationProvider: @escaping (
        ) -> MicrophoneAuthorizationState = {
            OnboardingWizardController
                .microphoneAuthorizationState()
        },
        audioEngineFactory: @escaping (
        ) -> RealtimeAudioEngineProtocol = {
            RealtimeAudioEngine()
        },
        openURL: @escaping (URL) -> Void = {
            _ = NSWorkspace.shared.open($0)
        },
        moveApplication: @escaping (
            @escaping (Result<Void, Error>) -> Void
        ) -> Void = ApplicationRelocator
            .moveToApplicationsAndRelaunch,
        quitApplication: @escaping () -> Void = {
            NSApplication.shared.terminate(nil)
        }
    ) {
        self.profileProvider = profileProvider
        self.credentialStore = credentialStore
        self.apiKeyVerifier = apiKeyVerifier
        self.applicationLocationProvider =
            applicationLocationProvider
        self.microphoneAuthorizationProvider =
            microphoneAuthorizationProvider
        self.audioEngineFactory = audioEngineFactory
        self.openURL = openURL
        self.moveApplication = moveApplication
        self.quitApplication = quitApplication

        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: 620,
                height: 520
            ),
            styleMask: [
                .titled,
                .closable,
                .miniaturizable
            ],
            backing: .buffered,
            defer: false
        )
        window.title = "Set Up VoiceKey"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        buildWindow()

        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshMicrophoneAuthorization()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        microphoneTimer?.invalidate()
        if let activationObserver {
            NotificationCenter.default.removeObserver(
                activationObserver
            )
        }
        audioEngine?.stop()
    }

    var groundTruthSnapshot: OnboardingGroundTruth {
        let profile = profileProvider().first
        return OnboardingGroundTruth(
            applicationLocation:
                applicationLocationProvider(),
            requiresAPIKey:
                profile?.providerID.requiresAPIKey == true,
            hasAPIKey: profile.map {
                credentialStore.hasAPIKey(for: $0)
            } ?? false,
            microphoneAuthorization:
                microphoneAuthorizationProvider(),
            hasHotKey: profile?.hotKey != nil
        )
    }

    var currentStepSnapshot: OnboardingStep {
        currentStep
    }

    func showInitial() {
        handledSteps.removeAll()
        currentStep = OnboardingFlowPolicy.initialStep(
            groundTruth: groundTruthSnapshot
        )
        showAndRender()
    }

    func showReentrant() {
        handledSteps.removeAll()
        currentStep = OnboardingFlowPolicy.reentryStep(
            groundTruth: groundTruthSnapshot
        )
        showAndRender()
    }

    private func showAndRender() {
        render()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func buildWindow() {
        guard let contentView = window?.contentView else {
            return
        }
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 18
        contentStack.edgeInsets = NSEdgeInsets(
            top: 34,
            left: 42,
            bottom: 30,
            right: 42
        )
        contentStack.translatesAutoresizingMaskIntoConstraints =
            false
        contentView.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor
            ),
            contentStack.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor
            ),
            contentStack.topAnchor.constraint(
                equalTo: contentView.topAnchor
            ),
            contentStack.bottomAnchor.constraint(
                lessThanOrEqualTo: contentView.bottomAnchor
            )
        ])
    }

    private func render() {
        microphoneTimer?.invalidate()
        microphoneTimer = nil
        if currentStep != .hotKey {
            stopMicrophonePreview()
        }
        contentStack.arrangedSubviews.forEach {
            contentStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        apiKeyField = nil
        hotKeyRecorder = nil
        hotKeyStatusLabel = nil
        inputLevelMeter = nil
        previewStatusLabel = nil

        switch currentStep {
        case .location:
            renderLocation()
        case .welcome:
            renderWelcome()
        case .apiKey:
            renderAPIKey()
        case .microphone:
            renderMicrophone()
        case .hotKey:
            renderHotKey()
        case .done:
            renderDone()
        }
    }

    private func renderLocation() {
        addIcon(
            named: "externaldrive.badge.exclamationmark"
        )
        addTitle(
            "VoiceKey needs to live in Applications so macOS can remember its permissions"
        )
        addBody(
            "Move VoiceKey once, then it will reopen from Applications."
        )

        if let relocationStatusMessage {
            let label = addStatus(
                relocationStatusMessage,
                color: .systemRed
            )
            label.maximumNumberOfLines = 3
        }

        let moveButton = actionButton(
            title: isMovingApplication
                ? "Moving…"
                : "Move to Applications",
            action: #selector(moveToApplications)
        )
        moveButton.isEnabled = isMovingApplication == false
        contentStack.addArrangedSubview(moveButton)

        let quitButton = linkButton(
            title: "Quit",
            action: #selector(quit)
        )
        contentStack.addArrangedSubview(quitButton)

        if OnboardingFlowPolicy.canSkip(
            .location,
            groundTruth: groundTruthSnapshot
        ) {
            let continueButton = linkButton(
                title: "continue anyway",
                action: #selector(continueOutsideApplications)
            )
            continueButton.controlSize = .small
            contentStack.addArrangedSubview(continueButton)
        }
    }

    private func renderWelcome() {
        addIcon(named: "waveform.circle.fill")
        addTitle("Welcome to VoiceKey")
        addBody("Map a key to a voice AI")
        addFlexibleSpace()
        addFooter(
            primaryTitle: "Get Started",
            primaryAction: #selector(advance),
            secondaryTitle: "Set up later",
            secondaryAction: #selector(closeWizard)
        )
    }

    private func renderAPIKey() {
        addIcon(named: "key.fill")
        addTitle("Connect OpenAI")
        addBody(
            "Verify your API key before VoiceKey saves it."
        )

        guard let profile = profileProvider().first else {
            addStatus(
                "Add a voice channel in Settings first.",
                color: .systemRed
            )
            addSkipFooter()
            return
        }

        let hasStoredKey =
            credentialStore.hasAPIKey(for: profile)
        let showsStoredKey =
            hasStoredKey && isChangingStoredKey == false
        let field = NSSecureTextField()
        field.placeholderString = Self.keyPlaceholder
        field.font = NSFont.monospacedSystemFont(
            ofSize: 13,
            weight: .regular
        )
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        field.heightAnchor.constraint(
            equalToConstant: 30
        ).isActive = true
        if showsStoredKey {
            field.stringValue = Self.maskedKey
            field.isEnabled = false
            field.textColor = .secondaryLabelColor
        } else {
            field.stringValue = enteredAPIKey
        }
        apiKeyField = field

        let changeButton = NSButton(
            title: "Change",
            target: self,
            action: #selector(changeStoredKey)
        )
        changeButton.bezelStyle = .rounded
        changeButton.isHidden = showsStoredKey == false

        let row = NSStackView(
            views: [field, changeButton]
        )
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        field.setContentHuggingPriority(
            NSLayoutConstraint.Priority(1),
            for: .horizontal
        )
        contentStack.addArrangedSubview(row)
        row.widthAnchor.constraint(
            equalTo: contentStack.widthAnchor,
            constant: -84
        ).isActive = true

        let caption = addStatus(
            Self.keyCaption,
            color: .secondaryLabelColor
        )
        caption.maximumNumberOfLines = 2

        switch verificationState {
        case .idle:
            break
        case .verifying:
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            let status = NSStackView(
                views: [
                    spinner,
                    NSTextField(
                        labelWithString: "Checking key…"
                    )
                ]
            )
            status.orientation = .horizontal
            status.spacing = 8
            contentStack.addArrangedSubview(status)
        case .verified:
            addStatus("Key works", color: .systemGreen)
        case let .failed(message):
            addStatus(message, color: .systemRed)
        }

        addFlexibleSpace()
        if showsStoredKey || verificationState == .verified {
            addFooter(
                primaryTitle: "Continue",
                primaryAction: #selector(advance),
                secondaryTitle: "Skip for now",
                secondaryAction: #selector(skipCurrentStep)
            )
        } else {
            addFooter(
                primaryTitle: "Verify",
                primaryAction: #selector(verifyAPIKey),
                secondaryTitle: "Skip for now",
                secondaryAction: #selector(skipCurrentStep)
            )
        }
    }

    private func renderMicrophone() {
        let status = microphoneAuthorizationProvider()
        switch status {
        case .authorized:
            handledSteps.insert(.microphone)
            currentStep = OnboardingFlowPolicy.nextStep(
                after: .microphone,
                groundTruth: groundTruthSnapshot,
                handledSteps: handledSteps
            )
            render()
            return
        case .notDetermined:
            addIcon(named: "mic.fill")
            addTitle(
                "VoiceKey needs your microphone to hear you"
            )
            addBody(
                "Speak normally and VoiceKey will show that it can hear you."
            )
            addFlexibleSpace()
            addFooter(
                primaryTitle: "Enable Microphone",
                primaryAction:
                    #selector(requestMicrophoneAccess),
                secondaryTitle: "Skip for now",
                secondaryAction: #selector(skipCurrentStep)
            )
        case .denied, .restricted:
            renderMicrophoneRecovery(status: status)
        }
        startMicrophonePolling()
    }

    private func renderMicrophoneRecovery(
        status: MicrophoneAuthorizationState
    ) {
        addIcon(named: "mic.slash.fill")
        addTitle("Turn on microphone access")
        if status == .restricted {
            addBody(
                "Your account or MDM profile blocks microphone access."
            )
        } else {
            addBody(
                "Open System Settings, turn on VoiceKey, then return here."
            )
        }

        let settingsButton = actionButton(
            title: "Open System Settings",
            action: #selector(openMicrophoneSettings)
        )
        contentStack.addArrangedSubview(settingsButton)

        let helpButton = linkButton(
            title: microphoneHelpIsExpanded
                ? "Hide help"
                : "Still not working?",
            action: #selector(toggleMicrophoneHelp)
        )
        contentStack.addArrangedSubview(helpButton)
        if microphoneHelpIsExpanded {
            let help = addStatus(
                "If VoiceKey is missing from the list, quit it and reopen it from Applications.",
                color: .secondaryLabelColor
            )
            help.maximumNumberOfLines = 3
        }
        addFlexibleSpace()
        addFooter(
            primaryTitle: "Check Again",
            primaryAction:
                #selector(checkMicrophoneAuthorization),
            secondaryTitle: "Skip for now",
            secondaryAction: #selector(skipCurrentStep)
        )
    }

    private func renderHotKey() {
        addIcon(named: "keyboard.fill")
        addTitle("Choose your voice key")
        addBody(
            "Click the field, then press the shortcut you want to use."
        )

        let recorder = HotKeyRecorderView()
        recorder.profileID = profileProvider().first?.id
        recorder.hotKey = profileProvider().first?.hotKey
        recorder.translatesAutoresizingMaskIntoConstraints = false
        recorder.heightAnchor.constraint(
            equalToConstant: 58
        ).isActive = true
        recorder.onHotKeyRecorded = {
            [weak self] profileID, hotKey in
            self?.handleRecordedHotKey(
                hotKey,
                profileID: profileID
            )
        }
        recorder.onRecordingStateChanged = {
            [weak self] isRecording in
            guard let self else { return }
            self.delegate?.onboardingController(
                self,
                isRecordingHotKey: isRecording
            )
        }
        hotKeyRecorder = recorder
        contentStack.addArrangedSubview(recorder)
        recorder.widthAnchor.constraint(
            equalTo: contentStack.widthAnchor,
            constant: -84
        ).isActive = true

        let status = addStatus(
            "Your shortcut works anywhere while VoiceKey is running.",
            color: .secondaryLabelColor
        )
        hotKeyStatusLabel = status

        let meterRow = NSStackView()
        meterRow.orientation = .horizontal
        meterRow.alignment = .centerY
        meterRow.spacing = 10
        let meterLabel = NSTextField(
            labelWithString: "Microphone level"
        )
        let meter = InputLevelMeterView()
        meter.translatesAutoresizingMaskIntoConstraints = false
        meter.heightAnchor.constraint(
            equalToConstant: 9
        ).isActive = true
        meter.widthAnchor.constraint(
            equalToConstant: 220
        ).isActive = true
        inputLevelMeter = meter
        meterRow.addArrangedSubview(meterLabel)
        meterRow.addArrangedSubview(meter)
        contentStack.addArrangedSubview(meterRow)

        let previewStatus = addStatus(
            "Speak to check that VoiceKey can hear you.",
            color: .secondaryLabelColor
        )
        previewStatusLabel = previewStatus

        addFlexibleSpace()
        addFooter(
            primaryTitle: "Record Shortcut",
            primaryAction: #selector(beginHotKeyRecording),
            secondaryTitle: "Skip for now",
            secondaryAction: #selector(skipCurrentStep)
        )
        startMicrophonePreview()
    }

    private func renderDone() {
        addIcon(named: "checkmark.circle.fill")
        addTitle("VoiceKey is ready")
        let hotKey = profileProvider().first?.hotKey
        let hotKeyLabel = NSTextField(
            labelWithString:
                hotKey?.displayName
                ?? "No shortcut set yet"
        )
        hotKeyLabel.font = NSFont.monospacedSystemFont(
            ofSize: 34,
            weight: .semibold
        )
        hotKeyLabel.alignment = .center
        hotKeyLabel.translatesAutoresizingMaskIntoConstraints =
            false
        contentStack.addArrangedSubview(hotKeyLabel)
        hotKeyLabel.widthAnchor.constraint(
            equalTo: contentStack.widthAnchor,
            constant: -84
        ).isActive = true
        addBody("VoiceKey lives in your menu bar.")
        addFlexibleSpace()
        addFooter(
            primaryTitle: "Done",
            primaryAction: #selector(closeWizard),
            secondaryTitle: nil,
            secondaryAction: nil
        )
    }

    private func addIcon(named symbolName: String) {
        let imageView = NSImageView()
        imageView.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: nil
        )
        imageView.contentTintColor = .controlAccentColor
        imageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: 48),
            imageView.heightAnchor.constraint(equalToConstant: 48)
        ])
        contentStack.addArrangedSubview(imageView)
    }

    @discardableResult
    private func addTitle(_ text: String) -> NSTextField {
        let label = NSTextField(
            wrappingLabelWithString: text
        )
        label.font = NSFont.systemFont(
            ofSize: 24,
            weight: .semibold
        )
        label.maximumNumberOfLines = 3
        contentStack.addArrangedSubview(label)
        label.widthAnchor.constraint(
            equalTo: contentStack.widthAnchor,
            constant: -84
        ).isActive = true
        return label
    }

    @discardableResult
    private func addBody(_ text: String) -> NSTextField {
        let label = NSTextField(
            wrappingLabelWithString: text
        )
        label.font = NSFont.systemFont(ofSize: 15)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 3
        contentStack.addArrangedSubview(label)
        label.widthAnchor.constraint(
            equalTo: contentStack.widthAnchor,
            constant: -84
        ).isActive = true
        return label
    }

    @discardableResult
    private func addStatus(
        _ text: String,
        color: NSColor
    ) -> NSTextField {
        let label = NSTextField(
            wrappingLabelWithString: text
        )
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = color
        contentStack.addArrangedSubview(label)
        label.widthAnchor.constraint(
            lessThanOrEqualTo: contentStack.widthAnchor,
            constant: -84
        ).isActive = true
        return label
    }

    private func addFlexibleSpace() {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(
            NSLayoutConstraint.Priority(1),
            for: .vertical
        )
        spacer.setContentCompressionResistancePriority(
            NSLayoutConstraint.Priority(1),
            for: .vertical
        )
        contentStack.addArrangedSubview(spacer)
    }

    private func addFooter(
        primaryTitle: String,
        primaryAction: Selector,
        secondaryTitle: String?,
        secondaryAction: Selector?
    ) {
        let spacer = NSView()
        spacer.setContentHuggingPriority(
            NSLayoutConstraint.Priority(1),
            for: .horizontal
        )
        var views: [NSView] = []
        if let secondaryTitle, let secondaryAction {
            views.append(
                linkButton(
                    title: secondaryTitle,
                    action: secondaryAction
                )
            )
        }
        views.append(spacer)
        views.append(
            actionButton(
                title: primaryTitle,
                action: primaryAction
            )
        )
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(row)
        row.widthAnchor.constraint(
            equalTo: contentStack.widthAnchor,
            constant: -84
        ).isActive = true
    }

    private func addSkipFooter() {
        addFlexibleSpace()
        addFooter(
            primaryTitle: "Skip for now",
            primaryAction: #selector(skipCurrentStep),
            secondaryTitle: nil,
            secondaryAction: nil
        )
    }

    private func actionButton(
        title: String,
        action: Selector
    ) -> NSButton {
        let button = NSButton(
            title: title,
            target: self,
            action: action
        )
        button.bezelStyle = .rounded
        button.keyEquivalent = "\r"
        return button
    }

    private func linkButton(
        title: String,
        action: Selector
    ) -> NSButton {
        let button = NSButton(
            title: title,
            target: self,
            action: action
        )
        button.isBordered = false
        button.contentTintColor = .linkColor
        return button
    }

    @objc private func advance() {
        handledSteps.insert(currentStep)
        currentStep = OnboardingFlowPolicy.nextStep(
            after: currentStep,
            groundTruth: groundTruthSnapshot,
            handledSteps: handledSteps
        )
        delegate?.onboardingControllerGroundTruthDidChange(
            self
        )
        render()
    }

    @objc private func skipCurrentStep() {
        guard OnboardingFlowPolicy.canSkip(
            currentStep,
            groundTruth: groundTruthSnapshot
        ) else {
            return
        }
        advance()
    }

    @objc private func continueOutsideApplications() {
        guard applicationLocationProvider()
                == .outsideApplications else {
            return
        }
        handledSteps.insert(.location)
        currentStep = .welcome
        render()
    }

    @objc private func moveToApplications() {
        guard isMovingApplication == false else { return }
        isMovingApplication = true
        relocationStatusMessage = nil
        render()
        moveApplication { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isMovingApplication = false
                if case let .failure(error) = result {
                    self.relocationStatusMessage =
                        "Couldn’t move VoiceKey: \(error.localizedDescription)"
                    self.render()
                }
            }
        }
    }

    @objc private func quit() {
        quitApplication()
    }

    @objc private func closeWizard() {
        close()
    }

    @objc private func changeStoredKey() {
        isChangingStoredKey = true
        enteredAPIKey = ""
        verificationState = .idle
        render()
        apiKeyField?.becomeFirstResponder()
    }

    @objc private func verifyAPIKey() {
        guard let profile = profileProvider().first,
              let field = apiKeyField else {
            return
        }
        let key = field.stringValue.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        enteredAPIKey = key
        guard key.isEmpty == false else {
            verificationState = .failed(
                "Paste an API key to verify it."
            )
            render()
            return
        }

        verificationState.begin()
        render()
        apiKeyVerifier.verify(apiKey: key) {
            [weak self] result in
            guard let self else { return }
            self.verificationState.finish(result)
            if case .success = result {
                do {
                    try self.credentialStore.setAPIKey(
                        key,
                        for: profile
                    )
                    self.isChangingStoredKey = false
                    self.enteredAPIKey = ""
                    self.delegate?.onboardingController(
                        self,
                        didUpdateCredentialsFor: profile
                    )
                    self.delegate?
                        .onboardingControllerGroundTruthDidChange(
                            self
                        )
                } catch {
                    self.verificationState = .failed(
                        "Couldn’t save the API key: \(error.localizedDescription)"
                    )
                }
            }
            self.render()
        }
    }

    @objc private func requestMicrophoneAccess() {
        let engine = audioEngine ?? audioEngineFactory()
        audioEngine = engine
        engine.requestMicrophoneAccess { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                if granted {
                    self.handledSteps.insert(.microphone)
                    self.currentStep =
                        OnboardingFlowPolicy.nextStep(
                            after: .microphone,
                            groundTruth:
                                self.groundTruthSnapshot,
                            handledSteps: self.handledSteps
                        )
                    self.delegate?
                        .onboardingControllerGroundTruthDidChange(
                            self
                        )
                    self.render()
                } else {
                    self.render()
                }
            }
        }
    }

    @objc private func openMicrophoneSettings() {
        guard let url = URL(
            string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        ) else {
            return
        }
        openURL(url)
    }

    @objc private func toggleMicrophoneHelp() {
        microphoneHelpIsExpanded.toggle()
        render()
    }

    @objc private func checkMicrophoneAuthorization() {
        refreshMicrophoneAuthorization()
        if currentStep == .microphone {
            render()
        }
    }

    private func startMicrophonePolling() {
        microphoneTimer?.invalidate()
        microphoneTimer = Timer(
            timeInterval: 1,
            repeats: true
        ) { [weak self] _ in
            self?.refreshMicrophoneAuthorization()
        }
        if let microphoneTimer {
            RunLoop.main.add(
                microphoneTimer,
                forMode: .common
            )
        }
    }

    private func refreshMicrophoneAuthorization() {
        guard currentStep == .microphone,
              microphoneAuthorizationProvider()
                == .authorized else {
            return
        }
        handledSteps.insert(.microphone)
        currentStep = OnboardingFlowPolicy.nextStep(
            after: .microphone,
            groundTruth: groundTruthSnapshot,
            handledSteps: handledSteps
        )
        delegate?.onboardingControllerGroundTruthDidChange(
            self
        )
        render()
    }

    @objc private func beginHotKeyRecording() {
        hotKeyRecorder?.beginRecording()
        hotKeyRecorder?.window?.makeFirstResponder(
            hotKeyRecorder
        )
    }

    private func handleRecordedHotKey(
        _ hotKey: HotKeyConfiguration,
        profileID: UUID
    ) {
        guard let profile = profileProvider().first(where: {
            $0.id == profileID
        }) else {
            return
        }
        if let conflict = profileProvider().first(where: {
            $0.id != profileID
                && $0.hotKey?.keyCode == hotKey.keyCode
                && $0.hotKey?.carbonModifiers
                    == hotKey.carbonModifiers
        }) {
            hotKeyRecorder?.hotKey = profile.hotKey
            hotKeyStatusLabel?.stringValue =
                "Already used by \(conflict.name)."
            hotKeyStatusLabel?.textColor = .systemRed
            return
        }

        let accepted = delegate?.onboardingController(
            self,
            didRecordHotKey: hotKey,
            for: profile
        ) == true
        guard accepted else {
            hotKeyRecorder?.hotKey = profile.hotKey
            hotKeyStatusLabel?.stringValue =
                "That shortcut could not be registered. It may already be in use."
            hotKeyStatusLabel?.textColor = .systemRed
            return
        }

        handledSteps.insert(.hotKey)
        delegate?.onboardingControllerGroundTruthDidChange(
            self
        )
        currentStep = .done
        render()
    }

    private func startMicrophonePreview() {
        guard microphoneAuthorizationProvider()
                == .authorized else {
            previewStatusLabel?.stringValue =
                "Microphone access is off. You can continue and finish it later."
            previewStatusLabel?.textColor = .systemRed
            return
        }
        let engine = audioEngine ?? audioEngineFactory()
        audioEngine = engine
        do {
            try engine.start(
                inputHandler: { _ in },
                activityHandler: { [weak self] activity in
                    DispatchQueue.main.async {
                        self?.inputLevelMeter?.level =
                            min(1, max(0, activity.peak * 5))
                    }
                }
            )
        } catch {
            previewStatusLabel?.stringValue =
                "VoiceKey couldn’t read your microphone. Check Sound Settings or restart VoiceKey."
            previewStatusLabel?.textColor = .systemRed
        }
    }

    private func stopMicrophonePreview() {
        audioEngine?.stop()
        inputLevelMeter?.level = 0
    }

    private static func microphoneAuthorizationState(
    ) -> MicrophoneAuthorizationState {
        switch AVCaptureDevice.authorizationStatus(
            for: .audio
        ) {
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .authorized:
            return .authorized
        case .restricted:
            return .restricted
        @unknown default:
            return .restricted
        }
    }
}

extension OnboardingWizardController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSSecureTextField,
              field === apiKeyField else {
            return
        }
        let trimmed = field.stringValue.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if trimmed != field.stringValue {
            field.stringValue = trimmed
        }
        enteredAPIKey = trimmed
        if verificationState != .idle {
            verificationState = .idle
        }
    }
}

extension OnboardingWizardController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        microphoneTimer?.invalidate()
        microphoneTimer = nil
        hotKeyRecorder?.cancelRecording()
        stopMicrophonePreview()
    }
}

final class InputLevelMeterView: NSView {
    var level: Float = 0 {
        didSet {
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let track = NSBezierPath(
            roundedRect: bounds,
            xRadius: bounds.height / 2,
            yRadius: bounds.height / 2
        )
        NSColor.quaternaryLabelColor.setFill()
        track.fill()

        let clamped = CGFloat(min(1, max(0, level)))
        guard clamped > 0 else { return }
        let fillRect = NSRect(
            x: bounds.minX,
            y: bounds.minY,
            width: max(bounds.height, bounds.width * clamped),
            height: bounds.height
        )
        let fill = NSBezierPath(
            roundedRect: fillRect,
            xRadius: bounds.height / 2,
            yRadius: bounds.height / 2
        )
        NSColor.systemGreen.setFill()
        fill.fill()
    }
}
