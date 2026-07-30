@testable import VoiceKey
import AppKit
import Carbon
import XCTest

final class VoiceProfileStoreTests: XCTestCase {
    func testSaveAndLoadRoundTrip() throws {
        let defaults = makeTestDefaults()

        let profiles = [
            VoiceProfile(
                name: "OpenAI",
                providerID: .openAIRealtime,
                hotKey: .defaultVoiceToggle,
                model: "gpt-realtime-2",
                voice: "marin",
                instructions: "Be brief.",
                endpointURL: "",
                mcpServers: [
                    MCPServerConfiguration(
                        id: UUID(uuidString: "B7E32B7D-1B12-497A-9F2C-C7837D5E758A")!,
                        label: "calendar",
                        urlString: "https://mcp.example.com/calendar",
                        allowedTools: ["search_events", "create_event"]
                    )
                ],
                speakerModePreference: .alwaysOn
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

        XCTAssertEqual(
            VoiceProfileStore.load(defaults: defaults),
            profiles
        )
        XCTAssertFalse(VoiceProfileStore.isFreshInstall(defaults: defaults))
    }

    func testLegacySavedProfileWithoutMCPServersDecodesWithEmptyList() throws {
        let defaults = makeTestDefaults()

        let profileID = UUID()
        let legacyProfile: [[String: Any]] = [[
            "id": profileID.uuidString,
            "name": "Legacy",
            "providerID": VoiceProviderID.openAIRealtime.rawValue,
            "model": "gpt-realtime-2",
            "voice": "marin",
            "instructions": "Be brief.",
            "endpointURL": ""
        ]]
        defaults.set(
            try JSONSerialization.data(withJSONObject: legacyProfile),
            forKey: "VoiceProfiles.v1"
        )

        let profiles = VoiceProfileStore.load(defaults: defaults)

        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles[0].id, profileID)
        XCTAssertEqual(profiles[0].mcpServers, [])
        XCTAssertTrue(profiles[0].webSearchEnabled)
        XCTAssertEqual(profiles[0].speakerModePreference, .automatic)
    }

    func testFreshInstallSeedsDefaultOpenAIProfile() throws {
        let defaults = makeTestDefaults()

        XCTAssertTrue(VoiceProfileStore.isFreshInstall(defaults: defaults))

        let profiles = VoiceProfileStore.load(defaults: defaults)

        XCTAssertEqual(profiles.count, 1)
        let profile = try XCTUnwrap(profiles.first)
        XCTAssertEqual(profile.name, "OpenAI")
        XCTAssertEqual(profile.providerID, .openAIRealtime)
        // WO-M ruling: a fresh install explains recording a shortcut
        // instead of silently claiming F16.
        XCTAssertNil(profile.hotKey)
        XCTAssertEqual(profile.model, VoiceProviderID.openAIRealtime.defaultModel)
        XCTAssertEqual(profile.voice, VoiceProviderID.openAIRealtime.defaultVoice)
        XCTAssertEqual(profile.instructions, VoiceSessionConfiguration.defaultInstructions)
        XCTAssertEqual(profile.endpointURL, "")
        XCTAssertTrue(profile.webSearchEnabled)
        XCTAssertEqual(profile.speakerModePreference, .automatic)

        // Loading must not persist anything; the install stays fresh until a save.
        XCTAssertTrue(VoiceProfileStore.isFreshInstall(defaults: defaults))
    }

    func testLegacySettingsMigrateIntoFirstProfile() throws {
        let defaults = makeTestDefaults()

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
        let defaults = makeTestDefaults()

        defaults.set("not-a-real-provider", forKey: "VoiceProvider.providerID")

        XCTAssertFalse(VoiceProfileStore.isFreshInstall(defaults: defaults))

        let profiles = VoiceProfileStore.load(defaults: defaults)

        XCTAssertEqual(profiles.count, 1)
        let profile = try XCTUnwrap(profiles.first)
        XCTAssertEqual(profile.providerID, .openAIRealtime)
        XCTAssertEqual(profile.name, VoiceProviderID.openAIRealtime.displayName)
        // Legacy installs already have a profile set, so they retain F16.
        XCTAssertEqual(profile.hotKey, HotKeyConfiguration.defaultVoiceToggle)
        XCTAssertEqual(profile.model, VoiceProviderID.openAIRealtime.defaultModel)
        XCTAssertEqual(profile.voice, VoiceProviderID.openAIRealtime.defaultVoice)
        XCTAssertEqual(profile.instructions, VoiceSessionConfiguration.defaultInstructions)
    }

    func testSavedProfilesWinOverLegacySettings() throws {
        let defaults = makeTestDefaults()

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

        XCTAssertEqual(
            VoiceProfileStore.load(defaults: defaults),
            saved
        )
        XCTAssertFalse(VoiceProfileStore.isFreshInstall(defaults: defaults))
    }

    func testOpenAISavePreservesExplicitWebSearchOptOut()
        throws {
        let defaults = makeTestDefaults()
        var profile = VoiceProfile.defaultOpenAI()
        profile.webSearchEnabled = false

        VoiceProfileStore.save(
            [profile],
            defaults: defaults
        )

        XCTAssertFalse(
            try XCTUnwrap(
                VoiceProfileStore.load(
                    defaults: defaults
                ).first
            ).webSearchEnabled
        )
    }

    func testPreWorkOrderFixtureRoundTripsWithoutRenamingStorage() throws {
        let defaults = makeTestDefaults()
        let fixture = Data(
            """
            [{
              "id":"EA546738-9D6D-4E04-B243-240D5E9F2CF1",
              "name":"Pre-WO channel",
              "providerID":"openai-realtime",
              "hotKey":{
                "keyCode":63,
                "carbonModifiers":256,
                "menuKeyEquivalent":"v",
                "menuModifierMask":1048576,
                "displayName":"⌘V",
                "mainKeyDisplayName":"V"
              },
              "model":"gpt-realtime-2",
              "voice":"marin",
              "instructions":"Be concise.",
              "endpointURL":"",
              "mcpServers":[],
              "webSearchEnabled":true,
              "speakerModePreference":"automatic"
            }]
            """.utf8
        )
        defaults.set(fixture, forKey: "VoiceProfiles.v1")

        let loaded = VoiceProfileStore.load(defaults: defaults)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].name, "Pre-WO channel")
        XCTAssertEqual(loaded[0].providerID, .openAIRealtime)
        XCTAssertEqual(loaded[0].hotKey?.displayName, "⌘V")
        XCTAssertTrue(loaded[0].webSearchEnabled)

        VoiceProfileStore.save(loaded, defaults: defaults)

        let savedData = try XCTUnwrap(
            defaults.data(forKey: "VoiceProfiles.v1")
        )
        XCTAssertNil(defaults.object(forKey: "VoiceChannels.v1"))
        let savedArray = try XCTUnwrap(
            JSONSerialization.jsonObject(with: savedData)
                as? [[String: Any]]
        )
        let keys = Set(try XCTUnwrap(savedArray.first).keys)
        XCTAssertEqual(keys, [
            "id",
            "name",
            "providerID",
            "hotKey",
            "model",
            "voice",
            "instructions",
            "endpointURL",
            "mcpServers",
            "webSearchEnabled",
            "speakerModePreference"
        ])
    }
}

final class OpenClawCredentialStateTests: XCTestCase {
    // The caption reflects credential PRESENCE, never channel readiness:
    // OpenClaw readiness always passes, which made a token-less machine
    // with no OpenClaw pairing claim "Ready to use." (fresh Air, 2026-07-24).
    // It also names the SOURCE in effect, because an entered token silently
    // outranks a working pairing (2026-07-25).
    func testStoredTokenState() {
        let state = VoiceProviderCredentialViewState(
            provider: .openClaw, hasAPIKey: true, hasDiscoveredGatewayToken: false
        )
        XCTAssertEqual(state.statusMessage, "Using the token you entered.")
        XCTAssertTrue(state.canRemoveAPIKey)
    }

    func testStoredTokenStateSaysItOverridesThisMacsPairing() {
        let state = VoiceProviderCredentialViewState(
            provider: .openClaw, hasAPIKey: true, hasDiscoveredGatewayToken: true
        )
        XCTAssertEqual(
            state.statusMessage,
            "Using the token you entered — it overrides this Mac's OpenClaw pairing."
        )
    }

    func testDiscoveredPairingState() {
        let state = VoiceProviderCredentialViewState(
            provider: .openClaw, hasAPIKey: false, hasDiscoveredGatewayToken: true
        )
        XCTAssertEqual(
            state.statusMessage,
            "Using this Mac's OpenClaw pairing."
        )
    }

    func testNoCredentialStateNeverClaimsReady() {
        let state = VoiceProviderCredentialViewState(
            provider: .openClaw, hasAPIKey: false, hasDiscoveredGatewayToken: false
        )
        XCTAssertEqual(
            state.statusMessage,
            "No gateway token found — paste one, or pair this Mac with OpenClaw."
        )
        XCTAssertFalse(state.statusMessage.contains("Ready"))
    }
}
