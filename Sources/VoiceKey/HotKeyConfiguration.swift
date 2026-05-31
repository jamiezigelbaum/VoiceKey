import AppKit
import Carbon

struct HotKeyConfiguration {
    let keyCode: UInt32
    let carbonModifiers: UInt32
    let menuKeyEquivalent: String
    let menuModifierMask: NSEvent.ModifierFlags
    let displayName: String

    static let voiceToggle = HotKeyConfiguration(
        keyCode: UInt32(kVK_F16),
        carbonModifiers: 0,
        menuKeyEquivalent: String(UnicodeScalar(NSF16FunctionKey)!),
        menuModifierMask: [],
        displayName: "F16"
    )
}
