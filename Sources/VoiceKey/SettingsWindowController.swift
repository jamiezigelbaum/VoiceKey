import AppKit
import Carbon

protocol SettingsWindowControllerDelegate: AnyObject {
    func settingsWindowController(
        _ controller: SettingsWindowController,
        didRecord hotKey: HotKeyConfiguration
    )
}

final class SettingsWindowController: NSWindowController {
    weak var delegate: SettingsWindowControllerDelegate?

    var hotKey: HotKeyConfiguration {
        didSet {
            recorderView.hotKey = hotKey
            currentShortcutLabel.stringValue = hotKey.displayName
        }
    }

    private let recorderView: HotKeyRecorderView
    private let currentShortcutLabel = NSTextField(labelWithString: "")

    init(hotKey: HotKeyConfiguration) {
        self.hotKey = hotKey
        self.recorderView = HotKeyRecorderView(hotKey: hotKey)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 220),
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

        let subtitleLabel = NSTextField(labelWithString: "Global shortcut")
        subtitleLabel.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        let hotKeyLabel = NSTextField(labelWithString: "Hotkey")
        hotKeyLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        hotKeyLabel.translatesAutoresizingMaskIntoConstraints = false

        currentShortcutLabel.stringValue = hotKey.displayName
        currentShortcutLabel.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
        currentShortcutLabel.textColor = .secondaryLabelColor
        currentShortcutLabel.translatesAutoresizingMaskIntoConstraints = false

        recorderView.translatesAutoresizingMaskIntoConstraints = false

        let hintLabel = NSTextField(labelWithString: "Click the field, then press the new shortcut.")
        hintLabel.font = NSFont.systemFont(ofSize: 12)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(titleLabel)
        contentView.addSubview(subtitleLabel)
        contentView.addSubview(hotKeyLabel)
        contentView.addSubview(currentShortcutLabel)
        contentView.addSubview(recorderView)
        contentView.addSubview(hintLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),

            hotKeyLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            hotKeyLabel.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 28),

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
