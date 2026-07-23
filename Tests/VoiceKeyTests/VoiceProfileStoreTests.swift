@testable import VoiceKey
import AppKit
import Carbon
import XCTest

final class VoiceProfileStoreTests: XCTestCase {
    func testSaveAndLoadRoundTrip() throws {
        let suiteName = "VoiceKeyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let profiles = [
            VoiceProfile(
                name: "OpenAI",
                providerID: .openAIRealtime,
                hotKey: .defaultVoiceToggle,
                model: "gpt-realtime-2",
                voice: "marin",
                instructions: "Be brief.",
                endpointURL: ""
            ),
            VoiceProfile(
                name: "Self-hosted",
                providerID: .custom,
                hotKey: nil,
                model: "local-model",
                voice: "local-voice",
                instructions: "",
                endpointURL: "wss://assistant.local/v1/realtime"
            )
        ]

        VoiceProfileStore.save(profiles, defaults: defaults)

        XCTAssertEqual(VoiceProfileStore.load(defaults: defaults), profiles)
        XCTAssertFalse(VoiceProfileStore.isFreshInstall(defaults: defaults))
    }

    func testFreshInstallSeedsDefaultOpenAIProfile() throws {
        let suiteName = "VoiceKeyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        XCTAssertTrue(VoiceProfileStore.isFreshInstall(defaults: defaults))

        let profiles = VoiceProfileStore.load(defaults: defaults)

        XCTAssertEqual(profiles.count, 1)
        let profile = try XCTUnwrap(profiles.first)
        XCTAssertEqual(profile.name, "OpenAI")
        XCTAssertEqual(profile.providerID, .openAIRealtime)
        XCTAssertEqual(profile.hotKey, HotKeyConfiguration.defaultVoiceToggle)
        XCTAssertEqual(profile.hotKey?.keyCode, UInt32(kVK_F16))
        XCTAssertEqual(profile.model, VoiceProviderID.openAIRealtime.defaultModel)
        XCTAssertEqual(profile.voice, VoiceProviderID.openAIRealtime.defaultVoice)
        XCTAssertEqual(profile.instructions, VoiceSessionConfiguration.defaultInstructions)
        XCTAssertEqual(profile.endpointURL, "")

        // Loading must not persist anything; the install stays fresh until a save.
        XCTAssertTrue(VoiceProfileStore.isFreshInstall(defaults: defaults))
    }

    func testLegacySettingsMigrateIntoFirstProfile() throws {
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
        defaults.set(VoiceProviderID.chatGPTWeb.rawValue, forKey: "VoiceProvider.providerID")
        defaults.set("custom-model", forKey: "VoiceProvider.model")
        defaults.set("custom-voice", forKey: "VoiceProvider.voice")
        defaults.set("Be brief.", forKey: "VoiceProvider.instructions")

        XCTAssertFalse(VoiceProfileStore.isFreshInstall(defaults: defaults))

        let profiles = VoiceProfileStore.load(defaults: defaults)

        XCTAssertEqual(profiles.count, 1)
        let profile = try XCTUnwrap(profiles.first)
        XCTAssertEqual(profile.providerID, .chatGPTWeb)
        XCTAssertEqual(profile.name, VoiceProviderID.chatGPTWeb.displayName)
        XCTAssertEqual(profile.hotKey, hotKey)
        XCTAssertEqual(profile.model, "custom-model")
        XCTAssertEqual(profile.voice, "custom-voice")
        XCTAssertEqual(profile.instructions, "Be brief.")
        XCTAssertEqual(profile.endpointURL, "")

        // Legacy keys stay in place so a downgrade still finds them.
        XCTAssertEqual(defaults.string(forKey: "VoiceProvider.providerID"), VoiceProviderID.chatGPTWeb.rawValue)
        XCTAssertNotNil(defaults.object(forKey: "VoiceHotKey.keyCode"))
    }

    func testLegacyMigrationFallsBackToOpenAIForUnknownProvider() throws {
        let suiteName = "VoiceKeyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set("not-a-real-provider", forKey: "VoiceProvider.providerID")

        XCTAssertFalse(VoiceProfileStore.isFreshInstall(defaults: defaults))

        let profiles = VoiceProfileStore.load(defaults: defaults)

        XCTAssertEqual(profiles.count, 1)
        let profile = try XCTUnwrap(profiles.first)
        XCTAssertEqual(profile.providerID, .openAIRealtime)
        XCTAssertEqual(profile.name, VoiceProviderID.openAIRealtime.displayName)
        XCTAssertEqual(profile.hotKey, HotKeyConfiguration.defaultVoiceToggle)
        XCTAssertEqual(profile.model, VoiceProviderID.openAIRealtime.defaultModel)
        XCTAssertEqual(profile.voice, VoiceProviderID.openAIRealtime.defaultVoice)
        XCTAssertEqual(profile.instructions, VoiceSessionConfiguration.defaultInstructions)
    }

    func testSavedProfilesWinOverLegacySettings() throws {
        let suiteName = "VoiceKeyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        HotKeyConfiguration.defaultVoiceToggle.saveAsVoiceToggle(defaults: defaults)
        defaults.set(VoiceProviderID.geminiLive.rawValue, forKey: "VoiceProvider.providerID")

        let saved = [
            VoiceProfile(
                name: "Mine",
                providerID: .openAIRealtime,
                hotKey: nil,
                model: "saved-model",
                voice: "saved-voice",
                instructions: "",
                endpointURL: ""
            )
        ]
        VoiceProfileStore.save(saved, defaults: defaults)

        XCTAssertEqual(VoiceProfileStore.load(defaults: defaults), saved)
        XCTAssertFalse(VoiceProfileStore.isFreshInstall(defaults: defaults))
    }
}
