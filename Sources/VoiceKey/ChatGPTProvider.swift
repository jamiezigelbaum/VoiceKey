import AppKit
import WebKit

final class ChatGPTProvider: NSObject {
    private let windowController: WebWindowController
    private var voiceActive = false

    override init() {
        self.windowController = WebWindowController()
        super.init()
    }

    func prepare() {
        windowController.load(URL(string: "https://chatgpt.com/")!)
    }

    func show() {
        windowController.show()
    }

    func reload() {
        windowController.webView.reload()
        show()
    }

    func toggleVoice() {
        if voiceActive {
            stopVoice()
        } else {
            startVoice()
        }
    }

    private func startVoice() {
        voiceActive = true
        windowController.ensureVisibleForSetupIfNeeded()
        windowController.load(URL(string: "https://chatgpt.com/")!)

        windowController.runWhenReady { [weak self] webView in
            self?.clickVoiceButton(in: webView)
        }
    }

    private func stopVoice() {
        voiceActive = false
        windowController.runJavaScript("""
        (() => {
          const labels = ['End voice', 'Exit voice', 'Close voice', 'Stop'];
          const buttons = [...document.querySelectorAll('button,[role="button"]')];
          const target = buttons.find((button) => {
            const text = [
              button.getAttribute('aria-label'),
              button.getAttribute('data-testid'),
              button.textContent
            ].filter(Boolean).join(' ').toLowerCase();
            return labels.some((label) => text.includes(label.toLowerCase()));
          });
          if (!target) return false;
          const rect = target.getBoundingClientRect();
          return { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 };
        })();
        """) { [weak self] result in
            guard let point = result as? [String: Any],
                  let x = point["x"] as? Double,
                  let y = point["y"] as? Double else { return }
            self?.windowController.nativeClickInWebView(x: x, y: y)
        }
    }

    private func clickVoiceButton(in webView: WKWebView) {
        windowController.runJavaScript("""
        (() => {
          const candidates = [...document.querySelectorAll('button,[role="button"]')];
          const voiceButton = candidates.find((button) => {
            const label = [
              button.getAttribute('aria-label'),
              button.getAttribute('data-testid'),
              button.title,
              button.textContent
            ].filter(Boolean).join(' ').toLowerCase();
            return label.includes('voice') && !label.includes('dictation');
          });
          if (!voiceButton) return false;
          const rect = voiceButton.getBoundingClientRect();
          return { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 };
        })();
        """) { [weak self] result in
            guard let point = result as? [String: Any],
                  let x = point["x"] as? Double,
                  let y = point["y"] as? Double else {
                self?.windowController.show()
                return
            }
            self?.windowController.nativeClickInWebView(x: x, y: y)
        }
    }
}
