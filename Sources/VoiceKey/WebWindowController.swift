import AppKit
import WebKit

final class WebWindowController: NSObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    private let window: NSWindow
    private var readyCallbacks: [(WKWebView) -> Void] = []

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
        if webView.url?.host == url.host {
            flushReadyCallbacks()
            return
        }
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
            completion?(error == nil ? result : nil)
        }
    }

    func nativeClickInWebView(x: Double, y: Double) {
        show()
        let webPoint = NSPoint(x: x, y: y)
        let windowPoint = webView.convert(webPoint, to: nil)
        guard let screenPoint = window.contentView?.convert(windowPoint, to: nil) else { return }
        let location = window.convertPoint(toScreen: screenPoint)
        clickScreenPoint(location)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.flushReadyCallbacks()
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
            decisionHandler(.grant)
        } else {
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
}
