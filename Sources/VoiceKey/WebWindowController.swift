import AppKit
import ApplicationServices
import WebKit

final class WebWindowController: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    /// Presented to every host EXCEPT Google's OAuth pages (see
    /// decidePolicyFor): chatgpt.com strips GPT-Live's server-side tools
    /// for bare-embed UAs, while Google's sign-in rejects embeds that
    /// claim to be full Safari.
    static let safariUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    let webView: WKWebView
    private let window: NSWindow
    private var visibleFrame: NSRect
    private var readyCallbacks: [(WKWebView) -> Void] = []
    var onNavigationFinished: (() -> Void)?
    var onDiagnostic: ((String) -> Void)?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        webView = WKWebView(frame: .zero, configuration: configuration)
        // Present as Safari, not a bare WKWebView embed. chatgpt.com
        // feature-gates by browser fingerprint: with the default embed UA,
        // GPT-Live voice ran but its server-side tools (web search) were
        // stripped; the same account in a real browser searched fine
        // (verified 2026-07-24). Safari's UA is the truthful closest match —
        // this IS WebKit on macOS.
        webView.customUserAgent = Self.safariUserAgent
        let initialWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        initialWindow.center()
        window = initialWindow
        visibleFrame = initialWindow.frame

        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        window.delegate = self
        window.title = "VoiceKey"
        window.contentView = webView
    }

    func load(_ url: URL) {
        if webView.url?.absoluteString == url.absoluteString, webView.isLoading == false {
            flushReadyCallbacks()
            return
        }
        onDiagnostic?("Loading \(url.absoluteString)")
        webView.load(URLRequest(url: url))
    }

    func show() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.alphaValue = 1
        window.setFrame(visibleFrame, display: false)
        window.makeKeyAndOrderFront(nil)
    }

    func prepareForHiddenInteraction() {
        guard window.isVisible == false || window.alphaValue < 1 else { return }

        let hiddenFrame = hiddenInteractionFrame()
        window.setFrame(hiddenFrame, display: false)
        window.alphaValue = 0.01
        window.orderFrontRegardless()
    }

    func ensureVisibleForSetupIfNeeded() {
        if webView.url == nil {
            show()
        }
    }

    func runWhenReady(_ callback: @escaping (WKWebView) -> Void) {
        readyCallbacks.append(callback)
        if webView.isLoading == false {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.flushReadyCallbacks()
            }
        }
    }

    func runJavaScript(_ source: String, completion: ((Any?) -> Void)? = nil) {
        webView.evaluateJavaScript(source) { result, error in
            if let error {
                self.onDiagnostic?("JavaScript probe failed: \(error.localizedDescription)")
            }
            completion?(error == nil ? result : nil)
        }
    }

    @discardableResult
    func nativeClickInWebView(x: Double, y: Double) -> Bool {
        // A native click needs the window ordered front so the CGEvent
        // hit-tests into it — but NOT visible: the near-invisible
        // hidden-interaction mode satisfies both the gesture requirement
        // and the no-window UX. Only a window the user already has fully
        // open stays that way.
        if window.isVisible && window.alphaValue >= 1 {
            window.orderFrontRegardless()
        } else {
            prepareForHiddenInteraction()
        }
        let webPoint = Self.appKitPointForDOMPoint(
            x: x,
            y: y,
            webViewHeight: webView.bounds.height
        )
        let windowPoint = webView.convert(webPoint, to: nil)
        guard let screenPoint = window.contentView?.convert(windowPoint, to: nil) else {
            onDiagnostic?("Could not convert DOM click point to a screen point.")
            return false
        }
        let location = window.convertPoint(toScreen: screenPoint)
        onDiagnostic?(
            "Native click DOM=(\(Int(x)),\(Int(y))) view=(\(Int(webPoint.x)),\(Int(webPoint.y))) screen=(\(Int(location.x)),\(Int(location.y)))"
        )

        // Request trust with the system prompt: this registers the app's
        // CURRENT code signature in the Accessibility list. A stale entry
        // from a previous build reads as untrusted even when toggled on
        // (observed 2026-07-24 across three grant attempts).
        let promptOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(promptOptions) {
            clickScreenPoint(location)
        } else {
            onDiagnostic?("Accessibility trust is not reported; using in-window WebKit click fallback.")
            clickWebViewPoint(webPoint)
        }
        return true
    }

    static func appKitPointForDOMPoint(x: Double, y: Double, webViewHeight: CGFloat) -> NSPoint {
        NSPoint(x: x, y: Double(webViewHeight) - y)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.flushReadyCallbacks()
            self?.onNavigationFinished?()
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // Per-host UA: Google's OAuth rejects embedded webviews presenting
        // as full Safari ("Something went wrong" after account selection,
        // observed 2026-07-24), but the SAME flow succeeded a day earlier
        // under WKWebView's default UA. chatgpt.com, conversely, needs the
        // Safari UA or GPT-Live's server-side tools are stripped. Serve
        // each host the UA that works for it; auth cookies persist across
        // the switch because the website data store is shared.
        let host = navigationAction.request.url?.host?.lowercased() ?? ""
        let isGoogleAuth = host == "accounts.google.com" || host.hasSuffix(".accounts.google.com")
        let desiredAgent = isGoogleAuth ? nil : Self.safariUserAgent
        if webView.customUserAgent != desiredAgent {
            webView.customUserAgent = desiredAgent
            onDiagnostic?(
                isGoogleAuth
                    ? "Using the default WebKit user agent for Google sign-in."
                    : "Using the Safari user agent for \(host)."
            )
        }
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        if origin.host.contains("chatgpt.com") || origin.host.contains("openai.com") {
            onDiagnostic?("Granting microphone capture permission for \(origin.host)")
            decisionHandler(.grant)
        } else {
            onDiagnostic?("Prompting for microphone capture permission for \(origin.host)")
            decisionHandler(.prompt)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender.alphaValue >= 1 {
            visibleFrame = sender.frame
        }
        sender.alphaValue = 1
        sender.orderOut(nil)
        return false
    }

    func windowDidMove(_ notification: Notification) {
        rememberVisibleFrameIfNeeded()
    }

    func windowDidResize(_ notification: Notification) {
        rememberVisibleFrameIfNeeded()
    }

    private func flushReadyCallbacks() {
        let callbacks = readyCallbacks
        readyCallbacks.removeAll()
        callbacks.forEach { $0(webView) }
    }

    private func rememberVisibleFrameIfNeeded() {
        guard window.isVisible, window.alphaValue >= 1 else { return }
        visibleFrame = window.frame
    }

    private func hiddenInteractionFrame() -> NSRect {
        let referenceFrame = NSScreen.main?.frame ?? visibleFrame
        return NSRect(
            x: referenceFrame.maxX + 200,
            y: referenceFrame.maxY + 200,
            width: visibleFrame.width,
            height: visibleFrame.height
        )
    }

    private func clickScreenPoint(_ point: NSPoint) {
        guard let mouseDown = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: point,
            mouseButton: .left
        ),
        let mouseUp = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseUp,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else { return }

        mouseDown.post(tap: .cghidEventTap)
        mouseUp.post(tap: .cghidEventTap)
    }

    private func clickWebViewPoint(_ point: NSPoint) {
        let windowPoint = webView.convert(point, to: nil)
        let timestamp = ProcessInfo.processInfo.systemUptime
        let common: (NSEvent.EventType) -> NSEvent? = { type in
            NSEvent.mouseEvent(
                with: type,
                location: windowPoint,
                modifierFlags: [],
                timestamp: timestamp,
                windowNumber: self.window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        }

        guard let mouseDown = common(.leftMouseDown),
              let mouseUp = common(.leftMouseUp) else { return }

        webView.mouseDown(with: mouseDown)
        webView.mouseUp(with: mouseUp)
    }
}
