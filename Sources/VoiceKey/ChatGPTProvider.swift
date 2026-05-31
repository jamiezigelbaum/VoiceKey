import AppKit
import WebKit

final class ChatGPTProvider: NSObject {
    private let windowController: WebWindowController
    private var status: ProviderStatus = .loading
    private var startClickCount = 0
    private var stopClickCount = 0
    private var lastAction = "Idle"

    var onStatusChange: ((ProviderStatus) -> Void)?
    var onDebugChange: ((String) -> Void)?

    override init() {
        self.windowController = WebWindowController()
        super.init()

        windowController.onNavigationFinished = { [weak self] in
            self?.refreshStatusAfterNavigation()
        }
        windowController.onDiagnostic = { [weak self] message in
            self?.log(message)
        }
    }

    func prepare() {
        updateStatus(.loading)
        windowController.load(URL(string: "https://chatgpt.com/")!)
    }

    func show() {
        windowController.show()
    }

    func reload() {
        updateStatus(.loading)
        windowController.webView.reload()
    }

    func toggleVoice() {
        switch status {
        case .clickSent, .voiceActive, .stopping:
            stopVoice()
        case .starting:
            log("Ignoring toggle while voice start is already in progress.")
        default:
            startVoice()
        }
    }

    func endVoice() {
        stopVoice()
    }

    private func startVoice() {
        updateStatus(.starting)
        updateDebug("Start requested")
        windowController.load(URL(string: "https://chatgpt.com/")!)

        windowController.runWhenReady { [weak self] _ in
            self?.attemptStartVoice(remainingAttempts: 6)
        }
    }

    private func stopVoice() {
        updateStatus(.stopping)
        updateDebug("Stop requested")
        windowController.runJavaScript(ChatGPTDOMProbe.stopButtonScript) { [weak self] result in
            guard let self else { return }
            let probe = ProbeResult(result)
            switch probe.state {
            case "clickable":
                self.clickStopButtonOnce()
            case "ready" where self.status == .clickSent || self.status == .voiceActive:
                self.clickVoiceToggleToStop()
            case "ready", "loginRequired", "needsAttention":
                self.applySnapshot(probe, showAttention: true)
            default:
                self.updateStatus(.needsAttention("Could not find an active ChatGPT Voice session to stop."))
            }
        }
    }

    private func attemptStartVoice(remainingAttempts: Int) {
        windowController.runJavaScript(ChatGPTDOMProbe.startButtonScript) { [weak self] result in
            guard let self else { return }
            let probe = ProbeResult(result)
            switch probe.state {
            case "clickable":
                self.clickStartButtonOnce()
            case "loginRequired":
                self.updateStatus(.loginRequired)
                self.windowController.show()
            case "voiceActive":
                self.updateStatus(.voiceActive)
            case "needsAttention":
                self.retryOrNeedAttention(
                    remainingAttempts: remainingAttempts,
                    message: probe.reason ?? "Could not find ChatGPT Voice controls.",
                    retry: self.attemptStartVoice
                )
            default:
                self.retryOrNeedAttention(
                    remainingAttempts: remainingAttempts,
                    message: "ChatGPT did not return a usable voice-control probe result.",
                    retry: self.attemptStartVoice
                )
            }
        }
    }

    private func clickStartButtonOnce() {
        startClickCount += 1
        updateDebug("Start click #\(startClickCount)")
        log("Sending one DOM click to ChatGPT Voice control.")
        windowController.runJavaScript(ChatGPTDOMProbe.startButtonClickFallbackScript) { [weak self] result in
            guard let self else { return }
            let probe = ProbeResult(result)
            switch probe.state {
            case "clicked":
                self.log("DOM-clicked ChatGPT Voice control: \(probe.label ?? "unknown")")
                self.observeVoiceStartedAfterSingleClick()
            case "loginRequired":
                self.updateStatus(.loginRequired)
                self.windowController.show()
            case "voiceActive":
                self.updateStatus(.voiceActive)
            case "needsAttention":
                self.updateStatus(.needsAttention(probe.reason ?? "Could not find ChatGPT Voice controls."))
            default:
                self.updateStatus(.needsAttention("ChatGPT did not accept the Voice start click."))
            }
        }
    }

    private func clickStopButtonOnce() {
        stopClickCount += 1
        updateDebug("Stop click #\(stopClickCount)")
        log("Sending one DOM click to ChatGPT Voice stop control.")
        windowController.runJavaScript(ChatGPTDOMProbe.stopButtonClickFallbackScript) { [weak self] result in
            guard let self else { return }
            let probe = ProbeResult(result)
            switch probe.state {
            case "clicked":
                self.log("DOM-clicked ChatGPT Voice stop control: \(probe.label ?? "unknown")")
                self.observeVoiceStoppedAfterSingleClick()
            case "ready", "loginRequired", "needsAttention", "voiceActive":
                self.applySnapshot(probe, showAttention: true)
            default:
                self.updateStatus(.needsAttention("ChatGPT did not accept the Voice stop click."))
            }
        }
    }

    private func clickVoiceToggleToStop() {
        stopClickCount += 1
        updateDebug("Stop/toggle click #\(stopClickCount)")
        log("No explicit stop control found; clicking the visible ChatGPT Voice toggle once.")
        windowController.runJavaScript(ChatGPTDOMProbe.voiceToggleClickScript) { [weak self] result in
            guard let self else { return }
            let probe = ProbeResult(result)
            switch probe.state {
            case "clicked":
                self.log("DOM-clicked ChatGPT Voice toggle: \(probe.label ?? "unknown")")
                self.observeVoiceStoppedAfterSingleClick()
            case "needsAttention":
                self.updateStatus(.needsAttention(probe.reason ?? "Could not find ChatGPT Voice controls."))
            default:
                self.updateStatus(.needsAttention("ChatGPT did not accept the Voice toggle click."))
            }
        }
    }

    private func observeVoiceStartedAfterSingleClick() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.capturePageState(context: "After start click")
            self?.verifyVoiceStartedOnce()
        }
    }

    private func observeVoiceStoppedAfterSingleClick() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.capturePageState(context: "After stop click")
            self?.verifyVoiceStoppedOnce()
        }
    }

    private func verifyVoiceStartedOnce() {
        windowController.runJavaScript(ChatGPTDOMProbe.snapshotScript) { [weak self] result in
            guard let self else { return }
            let probe = ProbeResult(result)
            switch probe.state {
            case "voiceActive":
                self.updateStatus(.voiceActive)
            case "loginRequired":
                self.updateStatus(.loginRequired)
                self.windowController.show()
            default:
                self.updateStatus(.clickSent)
                self.updateDebug("Voice started; use headphones or non-speaker output if it loops")
                self.log("Voice click was sent once. If the conversation loops, the likely cause is audio output feeding back into the microphone.")
            }
        }
    }

    private func verifyVoiceStoppedOnce() {
        windowController.runJavaScript(ChatGPTDOMProbe.snapshotScript) { [weak self] result in
            guard let self else { return }
            let probe = ProbeResult(result)
            if probe.state == "voiceActive" {
                self.updateStatus(.needsAttention("ChatGPT Voice still appears active after one stop click."))
                return
            }
            self.applySnapshot(probe, showAttention: true)
        }
    }

    private func refreshStatusAfterNavigation() {
        switch status {
        case .starting, .stopping:
            return
        default:
            windowController.runJavaScript(ChatGPTDOMProbe.snapshotScript) { [weak self] result in
                self?.applySnapshot(ProbeResult(result), showAttention: false)
            }
        }
    }

    private func applySnapshot(_ probe: ProbeResult, showAttention: Bool) {
        switch probe.state {
        case "loginRequired":
            updateStatus(.loginRequired)
            if showAttention { windowController.show() }
        case "voiceActive":
            updateStatus(.voiceActive)
        case "ready":
            updateStatus(.ready)
        case "needsAttention":
            updateStatus(.needsAttention(probe.reason ?? "Could not find ChatGPT Voice controls."))
        default:
            updateStatus(.needsAttention("ChatGPT status probe did not return a recognized state."))
        }
    }

    private func retryOrNeedAttention(
        remainingAttempts: Int,
        message: String,
        retry: @escaping (Int) -> Void
    ) {
        guard remainingAttempts > 0 else {
            updateStatus(.needsAttention(message))
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            retry(remainingAttempts - 1)
        }
    }

    private func updateStatus(_ newStatus: ProviderStatus) {
        guard newStatus != status else { return }
        status = newStatus
        log("Status: \(newStatus.menuTitle)\(newStatus.detail.map { " - \($0)" } ?? "")")
        onStatusChange?(newStatus)
    }

    private func updateDebug(_ action: String) {
        lastAction = action
        let summary = "Debug: \(lastAction) | start clicks \(startClickCount), stop clicks \(stopClickCount)"
        log(summary)
        onDebugChange?(summary)
    }

    private func capturePageState(context: String) {
        windowController.runJavaScript(ChatGPTDOMProbe.diagnosticScript) { [weak self] result in
            guard let self else { return }
            guard let dictionary = result as? [String: Any] else {
                self.updateDebug("\(context): diagnostic unavailable")
                return
            }
            let state = dictionary["state"] as? String ?? "unknown"
            let startLabel = dictionary["startLabel"] as? String ?? "none"
            let stopLabel = dictionary["stopLabel"] as? String ?? "none"
            self.updateDebug("\(context): state \(state), stop \(stopLabel), start \(startLabel)")
        }
    }

    private func log(_ message: String) {
        NSLog("[VoiceKey] ChatGPT: %@", message)
    }

}

private struct ProbeResult {
    let state: String
    let x: Double?
    let y: Double?
    let label: String?
    let reason: String?

    init(_ result: Any?) {
        guard let dictionary = result as? [String: Any] else {
            state = "invalid"
            x = nil
            y = nil
            label = nil
            reason = nil
            return
        }

        state = dictionary["state"] as? String ?? "invalid"
        x = dictionary["x"] as? Double
        y = dictionary["y"] as? Double
        label = dictionary["label"] as? String
        reason = dictionary["reason"] as? String
    }
}
