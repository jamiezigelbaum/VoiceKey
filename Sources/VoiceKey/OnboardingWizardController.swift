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
    func onboardingController(
        _ controller: OnboardingWizardController,
        ensureChannelsFor services: Set<OnboardingService>,
        openClawEndpoint: String
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

    func onboardingController(
        _ controller: OnboardingWizardController,
        ensureChannelsFor services: Set<OnboardingService>,
        openClawEndpoint: String
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

/// Geometry for the wizard window. The window never changes width, so every
/// wrapping label is laid out against `contentWidth` and a step's height can be
/// measured straight from the constraint system.
enum OnboardingWindowMetrics {
    static let width: CGFloat = 620
    static let horizontalInset: CGFloat = 42
    static let minimumContentHeight: CGFloat = 200
    /// Kept clear of the usable screen edges when a step is taller than the
    /// screen can show.
    static let screenMargin: CGFloat = 60

    static var horizontalInsetTotal: CGFloat {
        horizontalInset * 2
    }

    static var contentWidth: CGFloat {
        width - horizontalInsetTotal
    }

    /// Height the window's content area should take for a step that needs
    /// `fitting` points, never taller than the screen can show.
    static func contentHeight(
        fitting: CGFloat,
        visibleFrameHeight: CGFloat,
        windowChromeHeight: CGFloat
    ) -> CGFloat {
        let natural = max(
            fitting.rounded(.up),
            minimumContentHeight
        )
        guard visibleFrameHeight > 0 else { return natural }
        let available = visibleFrameHeight
            - screenMargin * 2
            - windowChromeHeight
        return min(natural, max(minimumContentHeight, available))
    }

    /// Keeps the window's centre where it is while its height changes, then
    /// nudges it back inside the usable screen area.
    static func centeredFrame(
        currentFrame: NSRect,
        targetSize: NSSize,
        visibleFrame: NSRect
    ) -> NSRect {
        var frame = NSRect(
            x: currentFrame.midX - targetSize.width / 2,
            y: currentFrame.midY - targetSize.height / 2,
            width: targetSize.width,
            height: targetSize.height
        )
        guard visibleFrame.isEmpty == false else {
            return frame
        }
        frame.origin.x = min(
            max(frame.minX, visibleFrame.minX),
            max(visibleFrame.minX, visibleFrame.maxX - frame.width)
        )
        frame.origin.y = min(
            max(frame.minY, visibleFrame.minY),
            max(visibleFrame.minY, visibleFrame.maxY - frame.height)
        )
        return frame
    }
}

/// VoiceKey lives in the menu bar, so it normally runs as an accessory app with
/// no Dock icon and no Command-Tab entry — click another window and the wizard
/// can no longer be selected. The wizard borrows the regular activation policy
/// while it is on screen and hands the old one back when it closes.
struct OnboardingActivationPolicySwitch {
    private(set) var borrowedFrom: NSApplication.ActivationPolicy?

    /// The policy to apply now, or nil when nothing has to change.
    mutating func borrow(
        from current: NSApplication.ActivationPolicy
    ) -> NSApplication.ActivationPolicy? {
        guard borrowedFrom == nil, current != .regular else {
            return nil
        }
        borrowedFrom = current
        return .regular
    }

    /// The policy to restore, or nil when nothing was borrowed.
    mutating func release() -> NSApplication.ActivationPolicy? {
        defer { borrowedFrom = nil }
        return borrowedFrom
    }
}

final class OnboardingWizardController: NSWindowController {
    weak var delegate: OnboardingWizardControllerDelegate?

    static let keyPlaceholder = "Paste key here"
    static let keyCaption =
        "API keys are stored in Apple keychain and shared across channels of this provider."
    static let maskedKey = "••••••••••••"
    static let openClawTokenPlaceholder = "Paste token here"

    private let profileProvider: () -> [VoiceProfile]
    private let credentialStore: VoiceCredentialStoring
    private let apiKeyVerifier: APIKeyVerifying
    private let userDefaults: UserDefaults
    private let openClawTester: OpenClawConnectionTesting
    private let retryScheduler: OnboardingRetryScheduler
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
    private let activationPolicyProvider:
        () -> NSApplication.ActivationPolicy
    private let applyActivationPolicy:
        (NSApplication.ActivationPolicy) -> Void

    private let contentStack = NSStackView()
    private var currentStep: OnboardingStep = .welcome
    private var handledSteps: Set<OnboardingStep> = []
    private var handledHotKeyProfileIDs: Set<UUID> = []
    private var selectedServices: Set<OnboardingService>
    private var confirmedServicesThisSession:
        Set<OnboardingService> = []
    private var verificationState: APIKeyVerificationState = .idle
    private var enteredAPIKey = ""
    private var enteredOpenClawToken = ""
    private var openClawEndpoint = ""
    private var openClawApprovalCommand: String?
    private var openClawState: OpenClawConnectionWizardState = .searching
    private var openClawStepStarted = false
    private var isChangingStoredKey = false
    private var isMovingApplication = false
    private var microphoneTimer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var audioEngine: RealtimeAudioEngineProtocol?
    private var inputLevelMeter: InputLevelMeterView?
    private var previewStatusLabel: NSTextField?
    private var apiKeyField: NSSecureTextField?
    private var openClawTokenField: NSSecureTextField?
    private var openClawEndpointField: NSTextField?
    private var hotKeyRecorder: HotKeyRecorderView?
    private var hotKeyStatusLabel: NSTextField?
    private var microphoneHelpIsExpanded = false
    private var relocationStatusMessage: String?
    private var activationPolicySwitch =
        OnboardingActivationPolicySwitch()
    private var terminationObserver: NSObjectProtocol?
    private lazy var openClawWizard = OpenClawConnectionWizard(
        tester: openClawTester,
        tokenProvider: { [weak self] in
            self?.resolvedOpenClawToken()
        },
        retryScheduler: retryScheduler
    )

    init(
        profileProvider: @escaping () -> [VoiceProfile],
        credentialStore: VoiceCredentialStoring = APIKeyStore.shared,
        apiKeyVerifier: APIKeyVerifying = OpenAIAPIKeyVerifier(),
        userDefaults: UserDefaults = .standard,
        openClawTester: OpenClawConnectionTesting = OpenClawConnectionTester(),
        retryScheduler: @escaping OnboardingRetryScheduler = { delay, action in
            let workItem = DispatchWorkItem(block: action)
            DispatchQueue.main.asyncAfter(
                deadline: .now() + delay,
                execute: workItem
            )
            return workItem
        },
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
        },
        activationPolicyProvider: @escaping (
        ) -> NSApplication.ActivationPolicy = {
            NSApplication.shared.activationPolicy()
        },
        applyActivationPolicy: @escaping (
            NSApplication.ActivationPolicy
        ) -> Void = {
            NSApplication.shared.setActivationPolicy($0)
        }
    ) {
        self.profileProvider = profileProvider
        self.credentialStore = credentialStore
        self.apiKeyVerifier = apiKeyVerifier
        self.userDefaults = userDefaults
        self.openClawTester = openClawTester
        self.retryScheduler = retryScheduler
        selectedServices =
            OnboardingServicePreferences.selectedServices(
                defaults: userDefaults
            )
            ?? OnboardingServicePreferences.inferredServices(
                from: profileProvider()
            )
        openClawEndpoint = profileProvider().first(where: {
            $0.providerID == .openClaw
        })?.endpointURL ?? ""
        self.applicationLocationProvider =
            applicationLocationProvider
        self.microphoneAuthorizationProvider =
            microphoneAuthorizationProvider
        self.audioEngineFactory = audioEngineFactory
        self.openURL = openURL
        self.moveApplication = moveApplication
        self.quitApplication = quitApplication
        self.activationPolicyProvider = activationPolicyProvider
        self.applyActivationPolicy = applyActivationPolicy

        // Every step resizes the window to its own content, so this is only a
        // starting frame — see sizeWindowToFitCurrentStep().
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: OnboardingWindowMetrics.width,
                height: OnboardingWindowMetrics
                    .minimumContentHeight
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
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.releaseActivationPolicy()
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
        if let terminationObserver {
            NotificationCenter.default.removeObserver(
                terminationObserver
            )
        }
        audioEngine?.stop()
    }

    var groundTruthSnapshot: OnboardingGroundTruth {
        let profiles = profileProvider()
        let openAIProfile = profiles.first {
            $0.providerID == .openAIRealtime
        }
        return OnboardingGroundTruth(
            applicationLocation:
                applicationLocationProvider(),
            selectedServices: selectedServices,
            hasOpenAIAPIKey: openAIProfile.map {
                credentialStore.hasAPIKey(for: $0)
            } ?? false,
            hasOpenClawConnection:
                OnboardingServicePreferences
                    .hasOpenClawConnection(
                        defaults: userDefaults
                    ),
            microphoneAuthorization:
                microphoneAuthorizationProvider(),
            hasHotKeysForSelectedServices:
                OnboardingHotKeyPolicy
                    .hasHotKeysForEverySelectedChannel(
                        profiles: profiles,
                        selectedServices: selectedServices
                    )
        )
    }

    var currentStepSnapshot: OnboardingStep {
        currentStep
    }

    func showInitial() {
        beginWizardSession()
        handledSteps.removeAll()
        handledHotKeyProfileIDs.removeAll()
        currentStep = OnboardingFlowPolicy.initialStep(
            groundTruth: groundTruthSnapshot
        )
        showAndRender()
    }

    func showReentrant() {
        beginWizardSession()
        handledSteps.removeAll()
        handledHotKeyProfileIDs.removeAll()
        currentStep = OnboardingFlowPolicy.reentryStep(
            groundTruth: groundTruthSnapshot
        )
        showAndRender()
    }

    private func showAndRender() {
        if [.microphone, .hotKey, .done].contains(currentStep) {
            ensureSelectedChannels()
        }
        borrowActivationPolicy()
        render()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// Gives the wizard a Dock icon and a Command-Tab entry for as long as it is
    /// open, so it stays selectable after the owner clicks another app.
    private func borrowActivationPolicy() {
        guard let policy = activationPolicySwitch.borrow(
            from: activationPolicyProvider()
        ) else {
            return
        }
        applyActivationPolicy(policy)
    }

    private func releaseActivationPolicy() {
        guard let policy = activationPolicySwitch.release() else {
            return
        }
        applyActivationPolicy(policy)
    }

    private func beginWizardSession() {
        confirmedServicesThisSession.removeAll()
        let profiles = profileProvider()
        guard let persisted =
            OnboardingServicePreferences.selectedServices(
                defaults: userDefaults
            ) else {
            selectedServices =
                OnboardingServicePreferences.inferredServices(
                    from: profiles
                )
            return
        }

        let providersWithChannels = Set(
            profiles.map(\.providerID)
        )
        let reconciled = Set(persisted.filter {
            providersWithChannels.contains($0.providerID)
        })
        selectedServices = reconciled
        if reconciled != persisted {
            OnboardingServicePreferences.saveSelectedServices(
                reconciled,
                defaults: userDefaults
            )
        }
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
            left: OnboardingWindowMetrics.horizontalInset,
            bottom: 30,
            right: OnboardingWindowMetrics.horizontalInset
        )
        contentStack.translatesAutoresizingMaskIntoConstraints =
            false
        contentView.addSubview(contentStack)
        // Pinned on all four edges: the window is sized to the stack's fitting
        // height, and the bottom pin lets the step's flexible space take up
        // whatever slack is left when a step has to be clamped to the screen.
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
                equalTo: contentView.bottomAnchor
            )
        ])
    }

    /// Resizes the window to the height the current step actually needs.
    private func sizeWindowToFitCurrentStep() {
        guard let window,
              let contentView = window.contentView else {
            return
        }
        contentView.layoutSubtreeIfNeeded()
        let visibleFrame =
            (window.screen ?? NSScreen.main)?.visibleFrame
            ?? .zero
        let chromeHeight = window.frameRect(
            forContentRect: .zero
        ).height
        let contentHeight = OnboardingWindowMetrics.contentHeight(
            fitting: contentView.fittingSize.height,
            visibleFrameHeight: visibleFrame.height,
            windowChromeHeight: chromeHeight
        )
        let targetSize = window.frameRect(
            forContentRect: NSRect(
                x: 0,
                y: 0,
                width: OnboardingWindowMetrics.width,
                height: contentHeight
            )
        ).size
        let heightChange = abs(
            targetSize.height - window.frame.height
        )
        guard heightChange > 0.5
            || abs(targetSize.width - window.frame.width) > 0.5
        else {
            return
        }
        window.setFrame(
            OnboardingWindowMetrics.centeredFrame(
                currentFrame: window.frame,
                targetSize: targetSize,
                visibleFrame: visibleFrame
            ),
            display: true,
            animate: window.isVisible && heightChange > 8
        )
    }

    private func render() {
        microphoneTimer?.invalidate()
        microphoneTimer = nil
        if currentStep != .hotKey {
            stopMicrophonePreview()
        }
        if currentStep != .openClawConnect {
            openClawWizard.leave()
            openClawStepStarted = false
        }
        contentStack.arrangedSubviews.forEach {
            contentStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        apiKeyField = nil
        openClawTokenField = nil
        openClawEndpointField = nil
        openClawApprovalCommand = nil
        hotKeyRecorder = nil
        hotKeyStatusLabel = nil
        inputLevelMeter = nil
        previewStatusLabel = nil

        switch currentStep {
        case .location:
            renderLocation()
        case .welcome:
            renderWelcome()
        case .services:
            renderServices()
        case .apiKey:
            renderAPIKey()
        case .openClawConnect:
            renderOpenClawConnect()
        case .microphone:
            renderMicrophone()
        case .hotKey:
            renderHotKey()
        case .done:
            renderDone()
        }

        sizeWindowToFitCurrentStep()
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

    private func renderServices() {
        addIcon(named: "point.3.connected.trianglepath.dotted")
        addTitle("What would you like to connect?")
        addBody("Choose one or both. You can add more voice channels later.")

        addServiceCard(
            service: .openAI,
            title: "OpenAI",
            description: "Fast, natural voice conversations with OpenAI."
        )
        addServiceCard(
            service: .openClaw,
            title: "OpenClaw",
            description: "Talk with your own OpenClaw assistant and tools."
        )

        if selectedServices.isEmpty {
            addStatus(
                "Choose at least one service to continue.",
                color: .systemRed
            )
        }

        addFlexibleSpace()
        let continueButton = addFooter(
            primaryTitle: "Continue",
            primaryAction: #selector(continueFromServices),
            secondaryTitle: "Set up later",
            secondaryAction: #selector(closeWizard)
        )
        continueButton.isEnabled =
            selectedServices.isEmpty == false
    }

    private func addServiceCard(
        service: OnboardingService,
        title: String,
        description: String
    ) {
        let checkbox = NSButton(
            checkboxWithTitle: title,
            target: self,
            action: #selector(toggleService(_:))
        )
        checkbox.state = selectedServices.contains(service)
            ? .on
            : .off
        checkbox.tag = OnboardingService.allCases.firstIndex(
            of: service
        ) ?? 0
        checkbox.font = NSFont.systemFont(
            ofSize: 16,
            weight: .semibold
        )

        let detail = NSTextField(
            wrappingLabelWithString: description
        )
        detail.textColor = .secondaryLabelColor
        detail.font = NSFont.systemFont(ofSize: 13)
        detail.maximumNumberOfLines = 2
        detail.preferredMaxLayoutWidth =
            OnboardingWindowMetrics.contentWidth - 28

        let stack = NSStackView(views: [checkbox, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(
            top: 14,
            left: 14,
            bottom: 14,
            right: 14
        )
        let box = NSBox()
        box.boxType = .custom
        box.borderWidth = 1
        box.cornerRadius = 10
        box.borderColor = selectedServices.contains(service)
            ? .controlAccentColor
            : .separatorColor
        box.contentView = stack
        addFullWidth(box)
        box.heightAnchor.constraint(equalToConstant: 88).isActive = true
    }

    private func renderAPIKey() {
        addIcon(named: "key.fill")
        addTitle("Connect OpenAI")
        addBody(
            "Verify your API key before VoiceKey saves it."
        )

        guard let profile = profileProvider().first(where: {
            $0.providerID == .openAIRealtime
        }) else {
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
        field.setContentHuggingPriority(
            NSLayoutConstraint.Priority(1),
            for: .horizontal
        )
        addFullWidth(row)

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

    private func renderOpenClawConnect() {
        addIcon(named: "link.circle.fill")
        addTitle("Connect OpenClaw")

        switch openClawState {
        case .searching:
            addBody("Looking for OpenClaw on this Mac…")
            addSpinner(label: "Searching…")
            addSkipFooter()
        case .testing:
            addBody("Checking your OpenClaw connection…")
            addSpinner(label: "Connecting…")
            addSkipFooter()
        case let .needsToken(message):
            addBody(message)
            let field = NSSecureTextField()
            field.placeholderString = Self.openClawTokenPlaceholder
            field.stringValue = enteredOpenClawToken
            field.delegate = self
            field.font = NSFont.monospacedSystemFont(
                ofSize: 13,
                weight: .regular
            )
            field.translatesAutoresizingMaskIntoConstraints = false
            field.heightAnchor.constraint(
                equalToConstant: 30
            ).isActive = true
            openClawTokenField = field
            addFullWidth(field)
            let hint = addStatus(
                "You can find the gateway token on the Mac where OpenClaw runs.",
                color: .secondaryLabelColor
            )
            hint.maximumNumberOfLines = 2
            addFlexibleSpace()
            addFooter(
                primaryTitle: "Save & Retry",
                primaryAction: #selector(saveOpenClawTokenAndRetry),
                secondaryTitle: "Skip for now",
                secondaryAction: #selector(skipCurrentStep)
            )
        case .needsEndpoint:
            addBody(
                "OpenClaw wasn’t reachable nearby. Enter the address of your gateway."
            )
            let field = NSTextField()
            field.placeholderString = "https://gateway.example.com"
            field.stringValue = openClawEndpoint
            field.delegate = self
            field.translatesAutoresizingMaskIntoConstraints = false
            field.heightAnchor.constraint(
                equalToConstant: 30
            ).isActive = true
            openClawEndpointField = field
            addFullWidth(field)
            addStatus(
                "VoiceKey accepts http, https, ws, or wss addresses.",
                color: .secondaryLabelColor
            )
            addFlexibleSpace()
            addFooter(
                primaryTitle: "Test Gateway",
                primaryAction: #selector(testOpenClawEndpoint),
                secondaryTitle: "Skip for now",
                secondaryAction: #selector(skipCurrentStep)
            )
        case let .pairingWait(reason, requestID, remediationHint):
            addBody("OpenClaw needs your approval")
            if let requestID, requestID.isEmpty == false {
                addStatus(
                    "Current request: \(requestID)",
                    color: .labelColor
                )
                let command = "openclaw devices approve \(requestID)"
                let commandField = NSTextField(
                    labelWithString: command
                )
                commandField.isSelectable = true
                commandField.font = NSFont.monospacedSystemFont(
                    ofSize: 13,
                    weight: .regular
                )
                commandField.lineBreakMode = .byTruncatingMiddle
                let copyButton = NSButton(
                    title: "Copy",
                    target: self,
                    action: #selector(copyOpenClawApprovalCommand)
                )
                openClawApprovalCommand = command
                copyButton.bezelStyle = .rounded
                let row = NSStackView(
                    views: [commandField, copyButton]
                )
                row.orientation = .horizontal
                row.spacing = 10
                addFullWidth(row)
            } else {
                addStatus(
                    "Waiting for a current approval request…",
                    color: .secondaryLabelColor
                )
            }
            if let remediationHint, remediationHint.isEmpty == false {
                let hint = addStatus(
                    remediationHint,
                    color: .secondaryLabelColor
                )
                hint.maximumNumberOfLines = 3
            } else if let reason, reason.isEmpty == false {
                addStatus(
                    "Approval reason: \(reason)",
                    color: .secondaryLabelColor
                )
            }
            addStatus(
                "VoiceKey checks again automatically.",
                color: .secondaryLabelColor
            )
            addFlexibleSpace()
            addFooter(
                primaryTitle: "Retry Now",
                primaryAction: #selector(retryOpenClawConnection),
                secondaryTitle: "Skip for now",
                secondaryAction: #selector(skipCurrentStep)
            )
        case let .success(serverVersion):
            addBody("OpenClaw is connected.")
            addStatus(
                "Gateway version \(serverVersion)",
                color: .systemGreen
            )
            addFlexibleSpace()
            addFooter(
                primaryTitle: "Continue",
                primaryAction: #selector(advance),
                secondaryTitle: nil,
                secondaryAction: nil
            )
        case let .failed(message):
            addBody("VoiceKey couldn’t connect to OpenClaw.")
            let status = addStatus(
                message,
                color: .systemRed
            )
            status.maximumNumberOfLines = 4
            addFlexibleSpace()
            addFooter(
                primaryTitle: "Retry",
                primaryAction: #selector(retryOpenClawConnection),
                secondaryTitle: "Skip for now",
                secondaryAction: #selector(skipCurrentStep)
            )
        }

        guard openClawStepStarted == false else { return }
        openClawStepStarted = true
        openClawWizard.onStateChange = { [weak self] state in
            guard let self else { return }
            self.openClawState = state
            if case .success = state {
                OnboardingServicePreferences
                    .setHasOpenClawConnection(
                        true,
                        defaults: self.userDefaults
                    )
                self.delegate?
                    .onboardingControllerGroundTruthDidChange(
                        self
                    )
            }
            guard self.currentStep == .openClawConnect else {
                return
            }
            self.render()
        }
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.currentStep == .openClawConnect else {
                return
            }
            self.openClawWizard.begin(
                endpointURL: self.openClawEndpoint
            )
        }
    }

    private func addSpinner(label: String) {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let row = NSStackView(
            views: [
                spinner,
                NSTextField(labelWithString: label)
            ]
        )
        row.orientation = .horizontal
        row.spacing = 8
        contentStack.addArrangedSubview(row)
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
        guard let profile = nextHotKeyProfile() else {
            handledSteps.insert(.hotKey)
            currentStep = .done
            render()
            return
        }
        addIcon(named: "keyboard.fill")
        addTitle("Choose a key for \(profile.name)")
        addBody(
            "Click the field, then press the shortcut you want to use."
        )

        let recorder = HotKeyRecorderView()
        recorder.profileID = profile.id
        recorder.hotKey = profile.hotKey
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
        addFullWidth(recorder)

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
        let selectedProviderIDs = Set(
            selectedServices.map(\.providerID)
        )
        for profile in profileProvider() where
            selectedProviderIDs.contains(profile.providerID) {
            let row = NSTextField(
                labelWithString: "\(profile.name): \(profile.hotKey?.displayName ?? "Set up later")"
            )
            row.font = NSFont.monospacedSystemFont(
                ofSize: 18,
                weight: .semibold
            )
            contentStack.addArrangedSubview(row)
        }
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

    /// Adds `view` to the step and only then pins it to the content width.
    /// Order matters: activating a constraint between two views with no shared
    /// ancestor raises and aborts the rest of the step — that is how the service
    /// picker shipped with no cards and no buttons (2026-07-25).
    @discardableResult
    private func addFullWidth<V: NSView>(_ view: V) -> V {
        view.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(view)
        view.widthAnchor.constraint(
            equalTo: contentStack.widthAnchor,
            constant: -OnboardingWindowMetrics.horizontalInsetTotal
        ).isActive = true
        return view
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
        label.preferredMaxLayoutWidth =
            OnboardingWindowMetrics.contentWidth
        return addFullWidth(label)
    }

    @discardableResult
    private func addBody(_ text: String) -> NSTextField {
        let label = NSTextField(
            wrappingLabelWithString: text
        )
        label.font = NSFont.systemFont(ofSize: 15)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 3
        label.preferredMaxLayoutWidth =
            OnboardingWindowMetrics.contentWidth
        return addFullWidth(label)
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
        label.preferredMaxLayoutWidth =
            OnboardingWindowMetrics.contentWidth
        contentStack.addArrangedSubview(label)
        label.widthAnchor.constraint(
            lessThanOrEqualTo: contentStack.widthAnchor,
            constant: -OnboardingWindowMetrics.horizontalInsetTotal
        ).isActive = true
        return label
    }

    /// Takes up whatever height is left over when a step has to be clamped to
    /// the screen. It measures as zero, so it never inflates the window.
    private func addFlexibleSpace() {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.heightAnchor.constraint(
            greaterThanOrEqualToConstant: 0
        ).isActive = true
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

    @discardableResult
    private func addFooter(
        primaryTitle: String,
        primaryAction: Selector,
        secondaryTitle: String?,
        secondaryAction: Selector?
    ) -> NSButton {
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
        let primaryButton = actionButton(
            title: primaryTitle,
            action: primaryAction
        )
        views.append(primaryButton)
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        addFullWidth(row)
        return primaryButton
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

    @objc private func toggleService(_ sender: NSButton) {
        guard OnboardingService.allCases.indices.contains(
            sender.tag
        ) else {
            return
        }
        let service = OnboardingService.allCases[sender.tag]
        if sender.state == .on {
            selectedServices.insert(service)
        } else {
            selectedServices.remove(service)
        }
        OnboardingServicePreferences.saveSelectedServices(
            selectedServices,
            defaults: userDefaults
        )
        render()
    }

    @objc private func continueFromServices() {
        guard selectedServices.isEmpty == false else { return }
        confirmServices(selectedServices)
        advance()
    }

    func confirmServices(
        _ services: Set<OnboardingService>
    ) {
        selectedServices = services
        OnboardingServicePreferences.saveSelectedServices(
            services,
            defaults: userDefaults
        )
        confirmedServicesThisSession = services
        ensureSelectedChannels()
    }

    @objc private func advance() {
        handledSteps.insert(currentStep)
        var nextStep = OnboardingFlowPolicy.nextStep(
            after: currentStep,
            groundTruth: groundTruthSnapshot,
            handledSteps: handledSteps
        )
        if [.services, .apiKey, .openClawConnect].contains(
            currentStep
        ),
           [.services, .apiKey, .openClawConnect].contains(
               nextStep
           ) == false {
            ensureSelectedChannels()
            nextStep = OnboardingFlowPolicy.nextStep(
                after: currentStep,
                groundTruth: groundTruthSnapshot,
                handledSteps: handledSteps
            )
        }
        currentStep = nextStep
        delegate?.onboardingControllerGroundTruthDidChange(
            self
        )
        render()
    }

    @objc private func skipCurrentStep() {
        if currentStep == .hotKey {
            guard let profile = nextHotKeyProfile() else {
                currentStep = .done
                render()
                return
            }
            handledHotKeyProfileIDs.insert(profile.id)
            if nextHotKeyProfile() == nil {
                handledSteps.insert(.hotKey)
                currentStep = .done
            }
            render()
            return
        }
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

    @objc private func saveOpenClawTokenAndRetry() {
        guard let field = openClawTokenField else { return }
        let token = field.stringValue.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        enteredOpenClawToken = token
        guard token.isEmpty == false else {
            openClawState = .needsToken(
                message: "Paste a gateway token to continue."
            )
            render()
            return
        }
        let profile = profileProvider().first {
            $0.providerID == .openClaw
        } ?? defaultProfile(for: .openClaw)
        do {
            try credentialStore.setAPIKey(token, for: profile)
            enteredOpenClawToken = ""
            delegate?.onboardingController(
                self,
                didUpdateCredentialsFor: profile
            )
            delegate?.onboardingControllerGroundTruthDidChange(
                self
            )
            openClawWizard.retry(endpointURL: openClawEndpoint)
        } catch {
            openClawState = .failed(
                message: "Couldn’t save the gateway token: \(error.localizedDescription)"
            )
            render()
        }
    }

    @objc private func testOpenClawEndpoint() {
        guard let field = openClawEndpointField else { return }
        openClawEndpoint = field.stringValue.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard openClawEndpoint.isEmpty == false else {
            openClawState = .needsEndpoint
            render()
            return
        }
        openClawWizard.retry(endpointURL: openClawEndpoint)
    }

    @objc private func retryOpenClawConnection() {
        openClawWizard.retry(endpointURL: openClawEndpoint)
    }

    @objc private func copyOpenClawApprovalCommand() {
        guard let command = openClawApprovalCommand else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
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
        handledHotKeyProfileIDs.insert(profile.id)
        delegate?.onboardingControllerGroundTruthDidChange(
            self
        )
        if nextHotKeyProfile() == nil {
            currentStep = .done
        }
        render()
    }

    private func nextHotKeyProfile() -> VoiceProfile? {
        OnboardingHotKeyPolicy.nextProfile(
            in: profileProvider(),
            selectedServices: selectedServices,
            handledProfileIDs: handledHotKeyProfileIDs
        )
    }

    private func ensureSelectedChannels() {
        guard confirmedServicesThisSession.isEmpty == false else {
            return
        }
        delegate?.onboardingController(
            self,
            ensureChannelsFor: confirmedServicesThisSession,
            openClawEndpoint: openClawEndpoint
        )
    }

    private func defaultProfile(
        for service: OnboardingService
    ) -> VoiceProfile {
        let provider = service.providerID
        return VoiceProfile(
            name: service == .openAI ? "OpenAI" : "OpenClaw",
            providerID: provider,
            hotKey: nil,
            model: provider.defaultModel,
            voice: provider.defaultVoice,
            instructions: "",
            endpointURL: service == .openClaw
                ? openClawEndpoint
                : ""
        )
    }

    private func resolvedOpenClawToken() -> String? {
        let profile = profileProvider().first {
            $0.providerID == .openClaw
        } ?? defaultProfile(for: .openClaw)
        return OpenClawTokenResolver.resolveGatewayToken(
            apiKeyProvider: {
                self.credentialStore.apiKey(for: profile)
            }
        )
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
        guard let field = obj.object as? NSTextField else {
            return
        }
        let trimmed = field.stringValue.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if trimmed != field.stringValue {
            field.stringValue = trimmed
        }
        if field === apiKeyField {
            enteredAPIKey = trimmed
            if verificationState != .idle {
                verificationState = .idle
            }
        } else if field === openClawTokenField {
            enteredOpenClawToken = trimmed
        } else if field === openClawEndpointField {
            openClawEndpoint = trimmed
        }
    }
}

extension OnboardingWizardController: NSWindowDelegate {
    // Every way out of the wizard — Done, "Set up later", the close button and
    // programmatic dismissal — ends here, so the activation policy goes back
    // exactly once and VoiceKey returns to being a menu-bar-only app.
    func windowWillClose(_ notification: Notification) {
        microphoneTimer?.invalidate()
        microphoneTimer = nil
        openClawWizard.leave()
        openClawStepStarted = false
        hotKeyRecorder?.cancelRecording()
        stopMicrophonePreview()
        releaseActivationPolicy()
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
