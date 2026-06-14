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
        XCTAssertEqual(MenuBarIconState(status: .checking), .loading)
        XCTAssertEqual(MenuBarIconState(status: .starting), .loading)
        XCTAssertEqual(MenuBarIconState(status: .stopping), .loading)
    }

    func testProblemStatusesUseProblemIcon() {
        XCTAssertEqual(MenuBarIconState(status: .loginRequired), .problem)
        XCTAssertEqual(MenuBarIconState(status: .needsAttention("Disconnected")), .problem)
    }

    func testActiveStatusesUseActiveIcon() {
        XCTAssertEqual(MenuBarIconState(status: .listening), .active)
        XCTAssertEqual(MenuBarIconState(status: .thinking), .active)
        XCTAssertEqual(MenuBarIconState(status: .speaking), .active)
        XCTAssertEqual(MenuBarIconState(status: .clickSent), .active)
        XCTAssertEqual(MenuBarIconState(status: .voiceActive), .active)
    }

    func testReadyStatusUsesReadyIcon() {
        XCTAssertEqual(MenuBarIconState(status: .ready), .ready)
    }

    func testVoiceToggleTitleStartsWhenInactive() {
        XCTAssertEqual(ProviderStatus.ready.voiceToggleTitle, "Start VoiceKey Voice")
        XCTAssertEqual(ProviderStatus.checking.voiceToggleTitle, "Start VoiceKey Voice")
        XCTAssertTrue(ProviderStatus.ready.allowsVoiceToggleWhileReady)
    }

    func testVoiceToggleTitleStopsWhenActive() {
        XCTAssertEqual(ProviderStatus.starting.voiceToggleTitle, "Stop VoiceKey Voice")
        XCTAssertEqual(ProviderStatus.listening.voiceToggleTitle, "Stop VoiceKey Voice")
        XCTAssertEqual(ProviderStatus.thinking.voiceToggleTitle, "Stop VoiceKey Voice")
        XCTAssertEqual(ProviderStatus.speaking.voiceToggleTitle, "Stop VoiceKey Voice")
        XCTAssertTrue(ProviderStatus.speaking.allowsVoiceToggleWhileReady)
    }

    func testVoiceToggleTitleDisablesWhileStopping() {
        XCTAssertEqual(ProviderStatus.stopping.voiceToggleTitle, "Stopping VoiceKey Voice")
        XCTAssertFalse(ProviderStatus.stopping.allowsVoiceToggleWhileReady)
    }
}

final class VoiceProviderSettingsStoreTests: XCTestCase {
    func testOpenAIRealtimeIsTheDefaultProvider() {
        XCTAssertEqual(VoiceSessionConfiguration.default.providerID, .openAIRealtime)
        XCTAssertEqual(VoiceSessionConfiguration.default.model, "gpt-realtime-2")
        XCTAssertEqual(VoiceProviderID.openAIRealtime.displayName, "OpenAI Realtime API")
        XCTAssertTrue(VoiceProviderID.openAIRealtime.requiresAPIKey)
    }

    func testChatGPTWebProviderUsesOAuthInsteadOfAPIKey() {
        XCTAssertTrue(VoiceProviderID.chatGPTWeb.isImplemented)
        XCTAssertFalse(VoiceProviderID.chatGPTWeb.requiresAPIKey)
        XCTAssertEqual(VoiceProviderID.chatGPTWeb.credentialLabel, "ChatGPT sign-in")
        XCTAssertFalse(VoiceProviderID.chatGPTWeb.supportsModelSetting)
        XCTAssertFalse(VoiceProviderID.chatGPTWeb.supportsVoiceSetting)
    }

    func testOpenAIReadinessRequiresAPIKey() {
        XCTAssertEqual(
            VoiceProviderID.openAIRealtime.readiness(hasAPIKey: false),
            .needsAPIKey("OpenAI API key required.")
        )
        XCTAssertEqual(VoiceProviderID.openAIRealtime.readiness(hasAPIKey: true), .ready)
    }

    func testChatGPTReadinessUsesProviderSignIn() {
        let readiness = VoiceProviderID.chatGPTWeb.readiness(hasAPIKey: false)
        XCTAssertEqual(readiness, .providerSignIn("Uses provider sign-in."))
        XCTAssertTrue(readiness.allowsVoiceToggle)
        XCTAssertEqual(readiness.menuSuffix, "Sign-in")
    }

    func testFutureProviderReadinessShowsComingSoon() {
        let readiness = VoiceProviderID.geminiLive.readiness(hasAPIKey: true)
        XCTAssertEqual(readiness, .unavailable("Gemini Live is coming soon."))
        XCTAssertFalse(readiness.allowsVoiceToggle)
        XCTAssertEqual(readiness.menuSuffix, "Coming soon")
    }

    func testCredentialViewStateForMissingAPIKey() {
        let state = VoiceProviderCredentialViewState(provider: .openAIRealtime, hasAPIKey: false)

        XCTAssertEqual(state.statusMessage, "OpenAI API key required.")
        XCTAssertTrue(state.acceptsAPIKeyInput)
        XCTAssertFalse(state.canRemoveAPIKey)
    }

    func testCredentialViewStateForStoredAPIKey() {
        let state = VoiceProviderCredentialViewState(provider: .openAIRealtime, hasAPIKey: true)

        XCTAssertEqual(state.statusMessage, "Ready to use.")
        XCTAssertTrue(state.acceptsAPIKeyInput)
        XCTAssertTrue(state.canRemoveAPIKey)
    }

    func testCredentialViewStateForProviderSignIn() {
        let state = VoiceProviderCredentialViewState(provider: .chatGPTWeb, hasAPIKey: false)

        XCTAssertEqual(state.statusMessage, "Uses provider sign-in.")
        XCTAssertFalse(state.acceptsAPIKeyInput)
        XCTAssertFalse(state.canRemoveAPIKey)
    }

    func testCredentialViewStateForComingSoonProviderDoesNotAcceptNewKey() {
        let state = VoiceProviderCredentialViewState(provider: .geminiLive, hasAPIKey: false)

        XCTAssertEqual(state.statusMessage, "Gemini Live is coming soon.")
        XCTAssertFalse(state.acceptsAPIKeyInput)
        XCTAssertFalse(state.canRemoveAPIKey)
    }

    func testCredentialViewStateForComingSoonProviderAllowsStoredKeyRemoval() {
        let state = VoiceProviderCredentialViewState(provider: .geminiLive, hasAPIKey: true)

        XCTAssertEqual(state.statusMessage, "Gemini Live is coming soon.")
        XCTAssertFalse(state.acceptsAPIKeyInput)
        XCTAssertTrue(state.canRemoveAPIKey)
    }

    func testProviderMenuStateForReadyAPIProvider() {
        let state = VoiceProviderMenuState(
            provider: .openAIRealtime,
            readiness: .ready,
            supportsProviderInterface: false,
            supportsConnectionCheck: true,
            hasSessionLog: true
        )

        XCTAssertEqual(state.providerTitle, "Provider: OpenAI Realtime API")
        XCTAssertEqual(state.toggleTitle, "Start VoiceKey Voice")
        XCTAssertTrue(state.isToggleEnabled)
        XCTAssertEqual(state.setupTitle, "Provider Settings...")
        XCTAssertEqual(state.setupAction, .openSettings)
        XCTAssertTrue(state.isSetupEnabled)
        XCTAssertEqual(state.showProviderTitle, "Show Provider (API provider)")
        XCTAssertFalse(state.isProviderInterfaceEnabled)
        XCTAssertEqual(state.checkConnectionTitle, "Check API Connection")
        XCTAssertTrue(state.isCheckConnectionEnabled)
        XCTAssertTrue(state.isCopySessionLogEnabled)
        XCTAssertTrue(state.isClearSessionLogEnabled)
    }

    func testProviderMenuStateForMissingAPIKey() {
        let state = VoiceProviderMenuState(
            provider: .openAIRealtime,
            readiness: .needsAPIKey("OpenAI API key required."),
            supportsProviderInterface: false,
            supportsConnectionCheck: true,
            hasSessionLog: false
        )

        XCTAssertEqual(state.providerTitle, "Provider: OpenAI Realtime API - Needs key")
        XCTAssertEqual(state.toggleTitle, "Add API Key in Settings")
        XCTAssertFalse(state.isToggleEnabled)
        XCTAssertEqual(state.setupTitle, "Add API Key...")
        XCTAssertEqual(state.setupAction, .openSettings)
        XCTAssertTrue(state.isSetupEnabled)
        XCTAssertEqual(state.checkConnectionTitle, "Check API Connection")
        XCTAssertFalse(state.isCheckConnectionEnabled)
        XCTAssertFalse(state.isCopySessionLogEnabled)
        XCTAssertFalse(state.isClearSessionLogEnabled)
    }

    func testProviderMenuStateForActiveAPIProviderOffersStop() {
        let state = VoiceProviderMenuState(
            provider: .openAIRealtime,
            readiness: .ready,
            currentStatus: .speaking,
            supportsProviderInterface: false,
            supportsConnectionCheck: true,
            hasSessionLog: true
        )

        XCTAssertEqual(state.toggleTitle, "Stop VoiceKey Voice")
        XCTAssertTrue(state.isToggleEnabled)
    }

    func testProviderMenuStateForStoppingAPIProviderDisablesToggle() {
        let state = VoiceProviderMenuState(
            provider: .openAIRealtime,
            readiness: .ready,
            currentStatus: .stopping,
            supportsProviderInterface: false,
            supportsConnectionCheck: true,
            hasSessionLog: true
        )

        XCTAssertEqual(state.toggleTitle, "Stopping VoiceKey Voice")
        XCTAssertFalse(state.isToggleEnabled)
    }

    func testProviderMenuStateForProviderSignIn() {
        let state = VoiceProviderMenuState(
            provider: .chatGPTWeb,
            readiness: .providerSignIn("Uses provider sign-in."),
            supportsProviderInterface: true,
            supportsConnectionCheck: false,
            hasSessionLog: false
        )

        XCTAssertEqual(state.providerTitle, "Provider: ChatGPT Web (OAuth) - Sign-in")
        XCTAssertEqual(state.toggleTitle, "Start VoiceKey Voice")
        XCTAssertTrue(state.isToggleEnabled)
        XCTAssertEqual(state.setupTitle, "Sign In with Provider...")
        XCTAssertEqual(state.setupAction, .showProviderInterface)
        XCTAssertTrue(state.isSetupEnabled)
        XCTAssertEqual(state.showProviderTitle, "Show Provider")
        XCTAssertEqual(state.reloadProviderTitle, "Reload Provider")
        XCTAssertTrue(state.isProviderInterfaceEnabled)
        XCTAssertEqual(state.checkConnectionTitle, "Check Provider Connection")
        XCTAssertFalse(state.isCheckConnectionEnabled)
        XCTAssertFalse(state.isCopySessionLogEnabled)
    }

    func testProviderMenuStateForComingSoonProvider() {
        let state = VoiceProviderMenuState(
            provider: .geminiLive,
            readiness: .unavailable("Gemini Live is coming soon."),
            supportsProviderInterface: false,
            supportsConnectionCheck: false,
            hasSessionLog: false
        )

        XCTAssertEqual(state.providerTitle, "Provider: Gemini Live - Coming soon")
        XCTAssertEqual(state.toggleTitle, "Gemini Live Coming Soon")
        XCTAssertFalse(state.isToggleEnabled)
        XCTAssertEqual(state.setupTitle, "Gemini Live Coming Soon")
        XCTAssertEqual(state.setupAction, .none)
        XCTAssertFalse(state.isSetupEnabled)
        XCTAssertEqual(state.showProviderTitle, "Show Provider (coming soon)")
        XCTAssertEqual(state.reloadProviderTitle, "Reload Provider (coming soon)")
        XCTAssertFalse(state.isProviderInterfaceEnabled)
        XCTAssertEqual(state.checkConnectionTitle, "Check API Connection")
        XCTAssertFalse(state.isCheckConnectionEnabled)
        XCTAssertFalse(state.isCopySessionLogEnabled)
    }

    func testGeminiLiveProviderCapabilitiesMatchRealtimeVoiceAndVisionSlot() {
        let provider = GeminiLiveProvider()

        XCTAssertEqual(provider.id, .geminiLive)
        XCTAssertTrue(provider.capabilities.supportsSpeechToSpeech)
        XCTAssertTrue(provider.capabilities.supportsTextInput)
        XCTAssertTrue(provider.capabilities.supportsInterruptions)
        XCTAssertTrue(provider.capabilities.supportsFunctionCalling)
        XCTAssertTrue(provider.capabilities.supportsVisionInput)
        XCTAssertFalse(provider.capabilities.supportsConnectionCheck)
    }

    func testDeepgramVoiceAgentProviderCapabilitiesMatchVoiceAgentSlot() {
        let provider = DeepgramVoiceAgentProvider()

        XCTAssertEqual(provider.id, .deepgramVoiceAgent)
        XCTAssertTrue(provider.capabilities.supportsSpeechToSpeech)
        XCTAssertTrue(provider.capabilities.supportsTextInput)
        XCTAssertTrue(provider.capabilities.supportsInterruptions)
        XCTAssertTrue(provider.capabilities.supportsFunctionCalling)
        XCTAssertFalse(provider.capabilities.supportsVisionInput)
        XCTAssertFalse(provider.capabilities.supportsConnectionCheck)
    }

    func testFactoryCreatesPlannedProviderAdapters() {
        XCTAssertTrue(
            VoiceProviderFactory.makeProvider(
                for: VoiceProviderID.geminiLive.defaultConfiguration
            ) is GeminiLiveProvider
        )
        XCTAssertTrue(
            VoiceProviderFactory.makeProvider(
                for: VoiceProviderID.deepgramVoiceAgent.defaultConfiguration
            ) is DeepgramVoiceAgentProvider
        )
    }

    func testLoadsDefaultsWhenNoProviderSettingsAreSaved() throws {
        let suiteName = "VoiceKeyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        XCTAssertEqual(VoiceProviderSettingsStore.load(defaults: defaults), .default)
    }

    func testSavesAndLoadsProviderSettings() throws {
        let suiteName = "VoiceKeyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let configuration = VoiceSessionConfiguration(
            providerID: .geminiLive,
            model: "gemini-live-2.5-flash-preview",
            voice: "Puck",
            instructions: "Be brief."
        )

        VoiceProviderSettingsStore.save(configuration, defaults: defaults)

        XCTAssertEqual(VoiceProviderSettingsStore.load(defaults: defaults), configuration)
    }
}
