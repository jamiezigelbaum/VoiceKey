@testable import VoiceKey
import AppKit
import Carbon
import XCTest

final class HotKeyConfigurationTests: XCTestCase {
    func testIconDisplayUsesMainKeyWithoutModifiers() {
        XCTAssertEqual(HotKeyConfiguration.defaultVoiceToggle.iconDisplayName, "F16")
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

    func testRecorderBuildsFunctionKeyShortcutWithModifiers() {
        let hotKey = HotKeyConfiguration(
            keyCode: UInt32(kVK_F16),
            charactersIgnoringModifiers: String(UnicodeScalar(NSF16FunctionKey)!),
            modifierFlags: [.shift]
        )

        XCTAssertEqual(hotKey?.keyCode, UInt32(kVK_F16))
        XCTAssertEqual(hotKey?.menuKeyEquivalent, String(UnicodeScalar(NSF16FunctionKey)!))
        XCTAssertEqual(hotKey?.menuModifierMask, [.shift])
        XCTAssertEqual(hotKey?.displayName, "⇧F16")
        XCTAssertEqual(hotKey?.iconDisplayName, "⇧F16")
    }

    func testRecorderBuildsCharacterShortcut() {
        let hotKey = HotKeyConfiguration(
            keyCode: UInt32(kVK_ANSI_V),
            charactersIgnoringModifiers: "v",
            modifierFlags: [.command]
        )

        XCTAssertEqual(hotKey?.menuKeyEquivalent, "v")
        XCTAssertEqual(hotKey?.menuModifierMask, [.command])
        XCTAssertEqual(hotKey?.displayName, "⌘V")
        XCTAssertEqual(hotKey?.mainKeyDisplayName, "V")
    }

    func testRecorderIgnoresModifierOnlyKeys() {
        let hotKey = HotKeyConfiguration(
            keyCode: UInt32(kVK_Command),
            charactersIgnoringModifiers: nil,
            modifierFlags: [.command]
        )

        XCTAssertNil(hotKey)
    }

    func testSavedVoiceToggleCanBeLoaded() throws {
        let suiteName = "VoiceKeyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let hotKey = HotKeyConfiguration(
            keyCode: UInt32(kVK_ANSI_V),
            carbonModifiers: UInt32(cmdKey),
            menuKeyEquivalent: "v",
            menuModifierMask: [.command],
            displayName: "⌘V",
            mainKeyDisplayName: "V"
        )

        hotKey.saveAsVoiceToggle(defaults: defaults)

        XCTAssertEqual(HotKeyConfiguration.loadVoiceToggle(defaults: defaults).displayName, "⌘V")
        XCTAssertEqual(HotKeyConfiguration.loadVoiceToggle(defaults: defaults).menuKeyEquivalent, "v")
    }
}

final class MenuBarIconStateTests: XCTestCase {
    func testLoadingStatusesUseLoadingIcon() {
        XCTAssertEqual(MenuBarIconState(status: .loading), .loading)
        XCTAssertEqual(MenuBarIconState(status: .starting), .loading)
        XCTAssertEqual(MenuBarIconState(status: .stopping), .loading)
    }

    func testProblemStatusesUseProblemIcon() {
        XCTAssertEqual(MenuBarIconState(status: .loginRequired), .problem)
        XCTAssertEqual(MenuBarIconState(status: .needsAttention("Disconnected")), .problem)
    }

    func testActiveStatusesUseActiveIcon() {
        XCTAssertEqual(MenuBarIconState(status: .clickSent), .active)
        XCTAssertEqual(MenuBarIconState(status: .voiceActive), .active)
    }

    func testReadyStatusUsesReadyIcon() {
        XCTAssertEqual(MenuBarIconState(status: .ready), .ready)
    }
}
