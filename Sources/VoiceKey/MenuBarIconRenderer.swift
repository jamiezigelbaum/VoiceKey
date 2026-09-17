import AppKit

enum MenuBarIconState: Equatable {
    case loading
    case problem
    case listening
    case thinking
    case speaking
    /// Legacy aggregate of the active family; renders like `.speaking`.
    /// New code should map statuses to the specific active states above.
    case active
    case ready

    init(status: ProviderStatus) {
        switch status {
        case .loading, .checking, .starting, .stopping:
            self = .loading
        case .loginRequired, .needsAttention:
            self = .problem
        case .listening:
            self = .listening
        case .thinking:
            self = .thinking
        case .speaking, .clickSent, .voiceActive:
            self = .speaking
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
        makeImage(state: state, phase: 0, text: text)
    }

    static func image(state: MenuBarIconState, phase: Double = 0) -> NSImage {
        makeImage(state: state, phase: phase, text: nil)
    }

    private static let canvasSize = NSSize(width: 144, height: 88)
    private static let bubbleRect = NSRect(x: 48, y: 27, width: 66, height: 42)
    private static let bubbleCenter = NSPoint(x: 81, y: 48)

    private static func makeImage(state: MenuBarIconState, phase: Double, text: String?) -> NSImage {
        let normalizedPhase = phase - phase.rounded(.down)
        let image = NSImage(size: canvasSize)

        image.lockFocus()
        defer { image.unlockFocus() }

        NSColor.clear.setFill()
        NSRect(origin: .zero, size: canvasSize).fill()

        let isTemplate = state != .problem
        let bubblePath = makeBubblePath(scale: bubbleScale(for: state, phase: normalizedPhase))

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

        // Decorations drawn inside the bubble are knocked out of its fill, so
        // they only make sense without a hotkey label occupying the same space.
        drawState(state, isTemplate: isTemplate, phase: normalizedPhase, drawsInsideBubble: text == nil)

        if let text {
            let label = abbreviatedText(text)
            let attributes = textAttributes(for: label)
            let textSize = label.size(withAttributes: attributes)
            let textRect = NSRect(
                x: bubbleRect.minX + (bubbleRect.width - textSize.width) / 2,
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
        }

        image.isTemplate = isTemplate
        image.size = NSSize(width: 36, height: 22)
        return image
    }

    private static func makeBubblePath(scale: CGFloat) -> NSBezierPath {
        let path = NSBezierPath(
            roundedRect: bubbleRect,
            xRadius: 17,
            yRadius: 17
        )
        path.appendTail()

        if scale != 1 {
            var transform = AffineTransform()
            transform.translate(x: bubbleCenter.x, y: bubbleCenter.y)
            transform.scale(scale)
            transform.translate(x: -bubbleCenter.x, y: -bubbleCenter.y)
            path.transform(using: transform)
        }
        return path
    }

    private static func bubbleScale(for state: MenuBarIconState, phase: Double) -> CGFloat {
        switch state {
        case .listening:
            // Gentle breathing: 1.0 at phase 0, peaking at 1.05 mid-cycle.
            return 1.025 + 0.025 * sin(2 * .pi * phase - .pi / 2)
        case .loading, .problem, .thinking, .speaking, .active, .ready:
            return 1
        }
    }

    private static func drawState(_ state: MenuBarIconState, isTemplate: Bool, phase: Double, drawsInsideBubble: Bool) {
        switch state {
        case .ready, .listening:
            break
        case .loading:
            drawLoadingComet(phase: phase)
        case .problem:
            drawProblemBadge(isTemplate: isTemplate)
        case .thinking:
            if drawsInsideBubble {
                drawThinkingDots(phase: phase, isTemplate: isTemplate)
            }
        case .speaking, .active:
            if drawsInsideBubble {
                drawSpeakingBars(phase: phase, isTemplate: isTemplate)
            }
        }
    }

    // MARK: - Connecting

    /// A comet of three arcs orbiting the glyph: a bright head whose sweep
    /// breathes slightly, trailed by two shorter arcs of decreasing alpha.
    private static func drawLoadingComet(phase: Double) {
        let center = NSPoint(x: 81, y: 44)
        let radius: CGFloat = 40
        let rotation = 360 * phase
        let sweep = 100 + 18 * sin(2 * .pi * phase)

        strokeArc(center: center, radius: radius, startAngle: rotation - 56, endAngle: rotation - 36, alpha: 0.25)
        strokeArc(center: center, radius: radius, startAngle: rotation - 30, endAngle: rotation - 8, alpha: 0.5)
        strokeArc(center: center, radius: radius, startAngle: rotation, endAngle: rotation + sweep, alpha: 1)
    }

    private static func strokeArc(center: NSPoint, radius: CGFloat, startAngle: CGFloat, endAngle: CGFloat, alpha: CGFloat) {
        let path = NSBezierPath()
        path.appendArc(withCenter: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: false)
        path.lineWidth = 6
        path.lineCapStyle = .round
        NSColor.black.withAlphaComponent(alpha).setStroke()
        path.stroke()
    }

    // MARK: - Problem

    private static func drawProblemBadge(isTemplate: Bool) {
        if isTemplate {
            NSColor.black.setFill()
        } else {
            NSColor.systemRed.setFill()
        }

        let badge = NSBezierPath(ovalIn: NSRect(x: 103, y: 55, width: 24, height: 24))
        badge.fill()

        if isTemplate {
            NSGraphicsContext.current?.cgContext.setBlendMode(.clear)
        } else {
            NSColor.white.setFill()
        }

        let stem = NSBezierPath(roundedRect: NSRect(x: 113.4, y: 62, width: 3.2, height: 8.5), xRadius: 1.6, yRadius: 1.6)
        stem.fill()
        let dot = NSBezierPath(ovalIn: NSRect(x: 113.4, y: 58.3, width: 3.2, height: 3.2))
        dot.fill()

        if isTemplate {
            NSGraphicsContext.current?.cgContext.setBlendMode(.normal)
        }
    }

    // MARK: - Thinking

    /// Three dots inside the bubble pulsing in sequence, knocked out of the
    /// bubble fill so they read in template mode.
    private static func drawThinkingDots(phase: Double, isTemplate: Bool) {
        for index in 0 ..< 3 {
            let wave = 0.5 + 0.5 * sin(2 * .pi * (phase + Double(index) / 3) - .pi / 2)
            let radius = 3.4 + 1.6 * wave
            let alpha = 0.45 + 0.55 * wave
            let x = bubbleCenter.x + CGFloat(index - 1) * 13
            let dot = NSBezierPath(ovalIn: NSRect(
                x: x - radius,
                y: bubbleCenter.y - radius,
                width: 2 * radius,
                height: 2 * radius
            ))
            eraseFromBubble(alpha: alpha, isTemplate: isTemplate) { dot.fill() }
        }
    }

    // MARK: - Speaking

    /// Four rounded waveform bars inside the bubble, knocked out of its fill.
    /// Per-bar phase offsets plus sqrt easing keep the dance organic, and the
    /// constant offsets keep every frame periodic over one full phase cycle.
    private static let speakingBarPhaseOffsets = [0.0, 0.3, 0.6, 0.4]

    private static func drawSpeakingBars(phase: Double, isTemplate: Bool) {
        let barWidth: CGFloat = 7
        let barSpacing: CGFloat = 13
        let firstX = bubbleCenter.x - (3 * barSpacing + barWidth) / 2

        for (index, offset) in speakingBarPhaseOffsets.enumerated() {
            let wave = 0.5 + 0.5 * sin(2 * .pi * (phase + offset))
            let height = 7 + 20 * wave.squareRoot()
            let bar = NSBezierPath(roundedRect: NSRect(
                x: firstX + CGFloat(index) * barSpacing,
                y: bubbleCenter.y - height / 2,
                width: barWidth,
                height: height
            ), xRadius: 3.5, yRadius: 3.5)
            eraseFromBubble(alpha: 1, isTemplate: isTemplate) { bar.fill() }
        }
    }

    /// In template mode the bubble is solid black, so interior decorations are
    /// erased from it; on the white problem bubble they would be painted white.
    private static func eraseFromBubble(alpha: CGFloat, isTemplate: Bool, draw: () -> Void) {
        if isTemplate {
            NSColor.black.withAlphaComponent(alpha).setFill()
            NSGraphicsContext.current?.cgContext.setBlendMode(.clear)
            draw()
            NSGraphicsContext.current?.cgContext.setBlendMode(.normal)
        } else {
            NSColor.white.withAlphaComponent(alpha).setFill()
            draw()
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
