@testable import VoiceKey
import XCTest

final class HotKeyConfigurationTests: XCTestCase {
    func testIconDisplayUsesMainKeyWithoutModifiers() {
        XCTAssertEqual(HotKeyConfiguration.voiceToggle.iconDisplayName, "F16")
    }

    func testIconDisplayIncludesOneModifier() {
        let hotKey = HotKeyConfiguration(
            keyCode: 9,
            carbonModifiers: 0,
            menuKeyEquivalent: "v",
            menuModifierMask: [.command],
            displayName: "⌘V",
            mainKeyDisplayName: "V"
        )

        XCTAssertEqual(hotKey.iconDisplayName, "⌘V")
    }

    func testIconDisplayOmitsMultipleModifiers() {
        let hotKey = HotKeyConfiguration(
            keyCode: 111,
            carbonModifiers: 0,
            menuKeyEquivalent: String(UnicodeScalar(NSF16FunctionKey)!),
            menuModifierMask: [.command, .shift],
            displayName: "⌘⇧F16",
            mainKeyDisplayName: "F16"
        )

        XCTAssertEqual(hotKey.iconDisplayName, "F16")
    }
}
