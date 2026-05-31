import AppKit
import Carbon

final class VoiceKeyAppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var hotKey: GlobalHotKey?
    private lazy var chatGPT = ChatGPTProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMenuBar()
        registerDefaultHotKey()
        chatGPT.prepare()
    }

    private func configureMenuBar() {
        statusItem.button?.title = "VoiceKey"

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Toggle ChatGPT Voice", action: #selector(toggleChatGPTVoice), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Show ChatGPT", action: #selector(showChatGPT), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Reload ChatGPT", action: #selector(reloadChatGPT), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit VoiceKey", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func registerDefaultHotKey() {
        do {
            hotKey = try GlobalHotKey(keyCode: UInt32(kVK_F16), modifiers: 0) { [weak self] in
                self?.toggleChatGPTVoice()
            }
        } catch {
            presentError("Could not register F16 hotkey: \(error.localizedDescription)")
        }
    }

    @objc private func toggleChatGPTVoice() {
        chatGPT.toggleVoice()
    }

    @objc private func showChatGPT() {
        chatGPT.show()
    }

    @objc private func reloadChatGPT() {
        chatGPT.reload()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func presentError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "VoiceKey"
        alert.informativeText = message
        alert.runModal()
    }
}
