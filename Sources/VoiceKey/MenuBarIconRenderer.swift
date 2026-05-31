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
        let size = NSSize(width: 144, height: 88)
        let image = NSImage(size: size)

        image.lockFocus()
        defer { image.unlockFocus() }

        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()

        let isTemplate = state != .problem
        let bubblePath = NSBezierPath(roundedRect: NSRect(x: 48, y: 27, width: 66, height: 42), xRadius: 17, yRadius: 17)
        bubblePath.appendTail()

        if isTemplate {
            NSColor.black.setFill()
            bubblePath.fill()
        } else {
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
            shadow.shadowBlurRadius = 8
            shadow.shadowOffset = NSSize(width: 0, height: -2)
            shadow.set()
            NSColor.white.setFill()
            bubblePath.fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        drawState(state, isTemplate: isTemplate)
        let label = abbreviatedText(text)
        let attributes = textAttributes(for: label)
        let textSize = label.size(withAttributes: attributes)
        let textRect = NSRect(
            x: 48 + (66 - textSize.width) / 2,
            y: 39 + (16 - textSize.height) / 2,
            width: textSize.width,
            height: textSize.height
        )

        if isTemplate {
            NSGraphicsContext.current?.cgContext.setBlendMode(.clear)
            label.draw(in: textRect, withAttributes: attributes)
            NSGraphicsContext.current?.cgContext.setBlendMode(.normal)
        } else {
            label.draw(in: textRect, withAttributes: attributes)
        }

        image.isTemplate = isTemplate
        image.size = NSSize(width: 36, height: 22)
        return image
    }

    private static func drawState(_ state: MenuBarIconState, isTemplate: Bool) {
        switch state {
        case .ready:
            break
        case .loading:
            drawLoadingArc()
        case .problem:
            drawProblemBadge(isTemplate: isTemplate)
        case .active:
            drawActiveBars()
        }
    }

    private static func drawLoadingArc() {
        let path = NSBezierPath()
        path.appendArc(
            withCenter: NSPoint(x: 75, y: 48),
            radius: 46,
            startAngle: 105,
            endAngle: 250,
            clockwise: false
        )
        path.lineWidth = 6
        path.lineCapStyle = .round
        path.stroke()
    }

    private static func drawProblemBadge(isTemplate: Bool) {
        if isTemplate {
            NSColor.black.setFill()
        } else {
            NSColor.systemRed.setFill()
        }

        let badge = NSBezierPath(ovalIn: NSRect(x: 106, y: 56, width: 28, height: 28))
        badge.fill()

        if isTemplate {
            NSGraphicsContext.current?.cgContext.setBlendMode(.clear)
        } else {
            NSColor.white.setFill()
        }

        let stem = NSBezierPath(roundedRect: NSRect(x: 118, y: 66, width: 4, height: 10), xRadius: 2, yRadius: 2)
        stem.fill()
        let dot = NSBezierPath(ovalIn: NSRect(x: 117.5, y: 61.5, width: 5, height: 5))
        dot.fill()

        if isTemplate {
            NSGraphicsContext.current?.cgContext.setBlendMode(.normal)
        }
    }

    private static func drawActiveBars() {
        let barRects = [
            NSRect(x: 29, y: 38, width: 5, height: 20),
            NSRect(x: 39, y: 31, width: 5, height: 34),
            NSRect(x: 124, y: 31, width: 5, height: 34),
            NSRect(x: 134, y: 38, width: 5, height: 20)
        ]

        for rect in barRects {
            let bar = NSBezierPath(roundedRect: rect, xRadius: 2.5, yRadius: 2.5)
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
        let fontSize: CGFloat
        if text.count > 6 {
            fontSize = 22
        } else if text.count > 4 {
            fontSize = 25
        } else {
            fontSize = 31
        }
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
        return [
            .font: font,
            .foregroundColor: NSColor.black
        ]
    }
}

private extension NSBezierPath {
    func appendTail() {
        move(to: NSPoint(x: 65, y: 29))
        line(to: NSPoint(x: 71, y: 12))
        line(to: NSPoint(x: 84, y: 29))
        close()
    }
}
