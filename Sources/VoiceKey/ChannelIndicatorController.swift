import AppKit

/// A small panel that drops from the menu-bar item to say a channel opened or
/// closed, and takes itself away again.
///
/// It exists because the status item is not always visible: with the menu bar
/// hidden there is no icon to change, so pressing a hotkey gave no feedback at
/// all — the owner could not tell whether the channel was live (2026-07-30).
///
/// Deliberately a `.nonactivatingPanel` that ignores mouse events: it must never
/// take focus from whatever the owner is typing into, and it must never be a
/// thing to dismiss.
final class ChannelIndicatorController {
    /// Long enough to read three words, short enough not to sit over anything.
    static let visibleDuration: TimeInterval = 1.6
    private static let fadeDuration: TimeInterval = 0.18
    private static let size = NSSize(width: 232, height: 40)
    /// Clear of the menu bar when it is showing, and still on screen when it is
    /// hidden.
    private static let topMargin: CGFloat = 8

    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private var dismissWorkItem: DispatchWorkItem?

    /// Where the status item is on screen, so the panel can drop from it.
    /// Returns nil when the item is unavailable, and the panel falls back to the
    /// top-right of the active screen.
    var statusItemFrame: () -> NSRect?

    init(statusItemFrame: @escaping () -> NSRect? = { nil }) {
        self.statusItemFrame = statusItemFrame
    }

    func show(_ event: ChannelIndicatorEvent) {
        let panel = panel ?? makePanel()
        self.panel = panel

        label.stringValue = event.text
        icon.image = NSImage(
            systemSymbolName: event.symbolName,
            accessibilityDescription: event.text
        )

        panel.setFrame(frameForPanel(), display: true)
        // Shown at full opacity rather than faded in. An earlier version
        // ordered the panel front at alpha 0 and animated up; the animation did
        // not run in the app and the panel stayed invisible while every other
        // part of the feature worked (2026-07-30 app run). Only the dismissal
        // fades, where failing to animate merely means it disappears crisply.
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        dismissWorkItem?.cancel()
        let dismiss = DispatchWorkItem { [weak self] in self?.hide() }
        dismissWorkItem = dismiss
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.visibleDuration,
            execute: dismiss
        )
    }

    func hide() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            panel.animator().alphaValue = 0
        } completionHandler: { [weak panel] in
            panel?.orderOut(nil)
        }
    }

    // MARK: - Panel

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // .statusBar keeps it above a hidden menu bar; without this the panel
        // is drawn underneath exactly when it is needed most.
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]

        let background = NSVisualEffectView(
            frame: NSRect(origin: .zero, size: Self.size)
        )
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true

        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.contentTintColor = .labelColor
        icon.imageScaling = .scaleProportionallyUpOrDown

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail

        background.addSubview(icon)
        background.addSubview(label)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(
                equalTo: background.leadingAnchor, constant: 12
            ),
            icon.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(
                equalTo: icon.trailingAnchor, constant: 8
            ),
            label.trailingAnchor.constraint(
                equalTo: background.trailingAnchor, constant: -12
            ),
            label.centerYAnchor.constraint(equalTo: background.centerYAnchor)
        ])

        panel.contentView = background
        return panel
    }

    /// Under the status item when we can find it, otherwise the top-right of the
    /// active screen — which is where the item would be.
    private func frameForPanel() -> NSRect {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let top = visible.maxY - Self.size.height - Self.topMargin

        guard let item = statusItemFrame() else {
            return NSRect(
                x: visible.maxX - Self.size.width - 12,
                y: top,
                width: Self.size.width,
                height: Self.size.height
            )
        }

        // Centre on the item, then keep the whole panel on screen: the item can
        // sit close enough to the right edge that centring would push it off.
        let centred = item.midX - Self.size.width / 2
        let clamped = min(
            max(centred, visible.minX + 12),
            visible.maxX - Self.size.width - 12
        )
        return NSRect(
            x: clamped,
            y: top,
            width: Self.size.width,
            height: Self.size.height
        )
    }
}
