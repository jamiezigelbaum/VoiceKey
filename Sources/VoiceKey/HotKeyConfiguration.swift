import AppKit
import Carbon

struct HotKeyConfiguration {
    let keyCode: UInt32
    let carbonModifiers: UInt32
    let menuKeyEquivalent: String
    let menuModifierMask: NSEvent.ModifierFlags
    let displayName: String
    let mainKeyDisplayName: String

    static let voiceToggle = HotKeyConfiguration(
        keyCode: UInt32(kVK_F16),
        carbonModifiers: 0,
        menuKeyEquivalent: String(UnicodeScalar(NSF16FunctionKey)!),
        menuModifierMask: [],
        displayName: "F16",
        mainKeyDisplayName: "F16"
    )

    var iconDisplayName: String {
        let modifier = iconModifierDisplayName
        guard let modifier else { return mainKeyDisplayName }
        return "\(modifier)\(mainKeyDisplayName)"
    }

    private var iconModifierDisplayName: String? {
        let candidates: [(NSEvent.ModifierFlags, String)] = [
            (.command, "⌘"),
            (.option, "⌥"),
            (.shift, "⇧"),
            (.control, "⌃")
        ]
        let active = candidates.filter { menuModifierMask.contains($0.0) }
        return active.count == 1 ? active[0].1 : nil
    }
}
