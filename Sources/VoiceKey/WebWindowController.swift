import AppKit
import ApplicationServices
import WebKit

final class WebWindowController: NSObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    private let window: NSWindow
    private var readyCallbacks: [(WKWebView) -> Void] = []
    var onNavigationFinished: (() -> Void)?
    var onDiagnostic: ((String) -> Void)?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        webView = WKWebView(frame: .zero, configuration: configuration)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        window.title = "VoiceKey"
        window.contentView = webView
        window.center()
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
        window.makeKeyAndOrderFront(nil)
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
        show()
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

        if AXIsProcessTrusted() {
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

    private func flushReadyCallbacks() {
        let callbacks = readyCallbacks
        readyCallbacks.removeAll()
        callbacks.forEach { $0(webView) }
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
