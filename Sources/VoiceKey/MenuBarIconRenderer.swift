import AppKit

enum MenuBarIconRenderer {
    static func image(for hotKey: HotKeyConfiguration) -> NSImage {
        image(text: hotKey.iconDisplayName)
    }

    static func image(text: String) -> NSImage {
        let size = NSSize(width: 44, height: 36)
        let image = NSImage(size: size)

        image.lockFocus()
        defer { image.unlockFocus() }

        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()

        let bubblePath = NSBezierPath(roundedRect: NSRect(x: 3, y: 9, width: 38, height: 22), xRadius: 10, yRadius: 10)
        bubblePath.appendTail()
        NSColor.black.setFill()
        bubblePath.fill()

        let label = abbreviatedText(text)
        let attributes = textAttributes(for: label)
        let textSize = label.size(withAttributes: attributes)
        let textRect = NSRect(
            x: (size.width - textSize.width) / 2,
            y: 14 + (11 - textSize.height) / 2,
            width: textSize.width,
            height: textSize.height
        )

        NSGraphicsContext.current?.cgContext.setBlendMode(.clear)
        label.draw(in: textRect, withAttributes: attributes)
        NSGraphicsContext.current?.cgContext.setBlendMode(.normal)

        image.isTemplate = true
        image.size = NSSize(width: 22, height: 18)
        return image
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
        let fontSize: CGFloat = text.count > 4 ? 8 : 10
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
        return [
            .font: font,
            .foregroundColor: NSColor.black
        ]
    }
}

private extension NSBezierPath {
    func appendTail() {
        move(to: NSPoint(x: 18, y: 10))
        line(to: NSPoint(x: 18, y: 4))
        line(to: NSPoint(x: 25, y: 10))
        close()
    }
}
