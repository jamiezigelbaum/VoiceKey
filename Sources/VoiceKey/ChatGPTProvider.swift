import AppKit
import WebKit

final class ChatGPTProvider: NSObject {
    private let windowController: WebWindowController
    private var status: ProviderStatus = .loading

    var onStatusChange: ((ProviderStatus) -> Void)?

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
        show()
    }

    func toggleVoice() {
        switch status {
        case .voiceActive, .stopping:
            stopVoice()
        case .starting:
            log("Ignoring toggle while voice start is already in progress.")
        default:
            startVoice()
        }
    }

    private func startVoice() {
        updateStatus(.starting)
        windowController.ensureVisibleForSetupIfNeeded()
        windowController.load(URL(string: "https://chatgpt.com/")!)

        windowController.runWhenReady { [weak self] _ in
            self?.attemptStartVoice(remainingAttempts: 6)
        }
    }

    private func stopVoice() {
        updateStatus(.stopping)
        windowController.runJavaScript(ChatGPTDOMProbe.stopButtonScript) { [weak self] result in
            guard let self else { return }
            let probe = ProbeResult(result)
            switch probe.state {
            case "clickable":
                guard let x = probe.x, let y = probe.y else {
                    self.updateStatus(.needsAttention("ChatGPT returned a stop control without a usable screen position."))
                    self.windowController.show()
                    return
                }
                self.log("Clicking ChatGPT stop control: \(probe.label ?? "unknown")")
                guard self.windowController.nativeClickInWebView(x: x, y: y) else {
                    self.updateStatus(.needsAttention("Could not send the stop click to ChatGPT Voice."))
                    self.windowController.show()
                    return
                }
                self.verifyVoiceStopped(remainingAttempts: 6)
            case "ready", "loginRequired", "needsAttention":
                self.applySnapshot(probe, showAttention: true)
            default:
                self.updateStatus(.needsAttention("Could not find an active ChatGPT Voice session to stop."))
                self.windowController.show()
            }
        }
    }

    private func attemptStartVoice(remainingAttempts: Int) {
        windowController.runJavaScript(ChatGPTDOMProbe.startButtonScript) { [weak self] result in
            guard let self else { return }
            let probe = ProbeResult(result)
            switch probe.state {
            case "clickable":
                guard let x = probe.x, let y = probe.y else {
                    self.updateStatus(.needsAttention("ChatGPT returned a voice control without a usable screen position."))
                    self.windowController.show()
                    return
                }
                self.log("Clicking ChatGPT Voice control: \(probe.label ?? "unknown")")
                guard self.windowController.nativeClickInWebView(x: x, y: y) else {
                    self.updateStatus(.needsAttention("Could not send the start click to ChatGPT Voice."))
                    self.windowController.show()
                    return
                }
                self.verifyVoiceStarted(remainingAttempts: 8)
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

    private func verifyVoiceStarted(remainingAttempts: Int) {
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
                self.retryOrNeedAttention(
                    remainingAttempts: remainingAttempts,
                    message: "Clicked ChatGPT Voice, but the page did not show that voice became active.",
                    retry: self.verifyVoiceStarted
                )
            }
        }
    }

    private func verifyVoiceStopped(remainingAttempts: Int) {
        windowController.runJavaScript(ChatGPTDOMProbe.snapshotScript) { [weak self] result in
            guard let self else { return }
            let probe = ProbeResult(result)
            if probe.state == "voiceActive" {
                self.retryOrNeedAttention(
                    remainingAttempts: remainingAttempts,
                    message: "ChatGPT Voice still appears active after the stop click.",
                    retry: self.verifyVoiceStopped
                )
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
            if showAttention { windowController.show() }
        default:
            updateStatus(.needsAttention("ChatGPT status probe did not return a recognized state."))
            if showAttention { windowController.show() }
        }
    }

    private func retryOrNeedAttention(
        remainingAttempts: Int,
        message: String,
        retry: @escaping (Int) -> Void
    ) {
        guard remainingAttempts > 0 else {
            updateStatus(.needsAttention(message))
            windowController.show()
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
