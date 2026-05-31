import AppKit

enum MenuBarIconState: Equatable {
    case loading
    case problem
    case active
    case ready

    init(status: ProviderStatus) {
        switch status {
        case .loading, .starting, .stopping:
            self = .loading
        case .loginRequired, .needsAttention:
            self = .problem
        case .clickSent, .voiceActive:
            self = .active
        case .ready:
            self = .ready
        }
    }
}

enum MenuBarIconRenderer {
    static func image(for hotKey: HotKeyConfiguration, status: ProviderStatus = .ready) -> NSImage {
        image(text: hotKey.iconDisplayName, state: MenuBarIconState(status: status))
    }

    static func image(text: String, state: MenuBarIconState = .ready) -> NSImage {
        let size = NSSize(width: 72, height: 48)
        let image = NSImage(size: size)

        image.lockFocus()
        defer { image.unlockFocus() }

        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()

        let bubblePath = NSBezierPath(roundedRect: NSRect(x: 5, y: 12, width: 56, height: 29), xRadius: 14, yRadius: 14)
        bubblePath.appendTail()
        NSColor.black.setFill()
        bubblePath.fill()

        drawState(state)
        let label = abbreviatedText(text)
        let attributes = textAttributes(for: label)
        let textSize = label.size(withAttributes: attributes)
        let textRect = NSRect(
            x: 6 + (54 - textSize.width) / 2,
            y: 19 + (13 - textSize.height) / 2,
            width: textSize.width,
            height: textSize.height
        )

        NSGraphicsContext.current?.cgContext.setBlendMode(.clear)
        label.draw(in: textRect, withAttributes: attributes)
        NSGraphicsContext.current?.cgContext.setBlendMode(.normal)

        image.isTemplate = true
        image.size = NSSize(width: 24, height: 18)
        return image
    }

    private static func drawState(_ state: MenuBarIconState) {
        switch state {
        case .ready:
            break
        case .loading:
            drawLoadingDots()
        case .problem:
            drawProblemBadge()
        case .active:
            drawActiveBars()
        }
    }

    private static func drawLoadingDots() {
        for x in [55, 62, 68] {
            let dot = NSBezierPath(ovalIn: NSRect(x: CGFloat(x) - 3, y: 7, width: 5, height: 5))
            dot.fill()
        }
    }

    private static func drawProblemBadge() {
        let badge = NSBezierPath(ovalIn: NSRect(x: 52, y: 29, width: 17, height: 17))
        badge.fill()

        NSGraphicsContext.current?.cgContext.setBlendMode(.clear)
        let stem = NSBezierPath(roundedRect: NSRect(x: 59.25, y: 35, width: 2.5, height: 7), xRadius: 1.2, yRadius: 1.2)
        stem.fill()
        let dot = NSBezierPath(ovalIn: NSRect(x: 59.1, y: 32, width: 2.8, height: 2.8))
        dot.fill()
        NSGraphicsContext.current?.cgContext.setBlendMode(.normal)
    }

    private static func drawActiveBars() {
        let barRects = [
            NSRect(x: 63, y: 17, width: 3, height: 13),
            NSRect(x: 57, y: 21, width: 3, height: 8),
            NSRect(x: 68, y: 20, width: 3, height: 9)
        ]

        for rect in barRects {
            let bar = NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5)
            bar.fill()
        }
    }

    private static func abbreviatedText(_ text: String) -> String {
        switch text {
        case "Escape":
            return "Esc"
        case "Return":
            return "↵"
        case "Delete":
            return "Del"
        case "Space":
            return "Space"
        default:
            return text
        }
    }

    private static func textAttributes(for text: String) -> [NSAttributedString.Key: Any] {
        let fontSize: CGFloat = text.count > 4 ? 12 : 15
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
        return [
            .font: font,
            .foregroundColor: NSColor.black
        ]
    }
}

private extension NSBezierPath {
    func appendTail() {
        move(to: NSPoint(x: 23, y: 13))
        line(to: NSPoint(x: 24, y: 4))
        line(to: NSPoint(x: 33, y: 13))
        close()
    }
}
