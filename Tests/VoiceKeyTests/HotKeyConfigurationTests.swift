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

        XCTAssertEqual(HotKeyConfiguration.loadVoiceToggle(defaults: defaults).displayName, "⌘V")
        XCTAssertEqual(HotKeyConfiguration.loadVoiceToggle(defaults: defaults).menuKeyEquivalent, "v")
    }

    func testHotKeyMatchingIgnoresFunctionFlag() {
        XCTAssertTrue(HotKeyConfiguration.defaultVoiceToggle.matches(
            keyCode: UInt16(kVK_F16),
            modifierFlags: [.function]
        ))
    }

    func testHotKeyMatchingRequiresConfiguredShortcutModifiers() {
        let hotKey = HotKeyConfiguration(
            keyCode: UInt32(kVK_ANSI_V),
            carbonModifiers: UInt32(cmdKey),
            menuKeyEquivalent: "v",
            menuModifierMask: [.command],
            displayName: "⌘V",
            mainKeyDisplayName: "V"
        )

        XCTAssertTrue(hotKey.matches(keyCode: UInt16(kVK_ANSI_V), modifierFlags: [.command]))
        XCTAssertFalse(hotKey.matches(keyCode: UInt16(kVK_ANSI_V), modifierFlags: []))
        XCTAssertFalse(hotKey.matches(keyCode: UInt16(kVK_ANSI_B), modifierFlags: [.command]))
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

    func testActiveStatusesMapToTheirSpecificIcons() {
        XCTAssertEqual(MenuBarIconState(status: .listening), .listening)
        XCTAssertEqual(MenuBarIconState(status: .thinking), .thinking)
        XCTAssertEqual(MenuBarIconState(status: .speaking), .speaking)
        XCTAssertEqual(MenuBarIconState(status: .clickSent), .speaking)
        XCTAssertEqual(MenuBarIconState(status: .voiceActive), .speaking)
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

    func testVoiceToggleRemainsEnabledWhileStopping() {
        XCTAssertEqual(ProviderStatus.stopping.voiceToggleTitle, "Stopping VoiceKey Voice")
        XCTAssertTrue(ProviderStatus.stopping.allowsVoiceToggleWhileReady)
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

    func testEveryAPIKeyProviderUsesPastePlaceholder() {
        for provider in VoiceProviderID.allCases
            where provider != .chatGPTWeb {
            XCTAssertEqual(
                provider.credentialPlaceholder,
                "Paste key here"
            )
            XCTAssertNotEqual(
                provider.credentialPlaceholder,
                "Stored in macOS Keychain"
            )
        }
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

    func testCredentialViewStateForCustomEndpointAcceptsOptionalKey() {
        let withoutKey = VoiceProviderCredentialViewState(provider: .custom, hasAPIKey: false)

        XCTAssertEqual(withoutKey.statusMessage, "Ready to use.")
        XCTAssertTrue(withoutKey.acceptsAPIKeyInput)
        XCTAssertFalse(withoutKey.canRemoveAPIKey)

        let withKey = VoiceProviderCredentialViewState(provider: .custom, hasAPIKey: true)

        XCTAssertEqual(withKey.statusMessage, "Ready to use.")
        XCTAssertTrue(withKey.acceptsAPIKeyInput)
        XCTAssertTrue(withKey.canRemoveAPIKey)
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

    func testProviderMenuStateForStoppingAPIProviderKeepsToggleEnabled() {
        let state = VoiceProviderMenuState(
            provider: .openAIRealtime,
            readiness: .ready,
            currentStatus: .stopping,
            supportsProviderInterface: false,
            supportsConnectionCheck: true,
            hasSessionLog: true
        )

        XCTAssertEqual(state.toggleTitle, "Stopping VoiceKey Voice")
        XCTAssertTrue(state.isToggleEnabled)
    }

    func testProviderMenuStateForProviderSignIn() {
        let state = VoiceProviderMenuState(
            provider: .chatGPTWeb,
            readiness: .providerSignIn("Uses provider sign-in."),
            supportsProviderInterface: true,
            supportsConnectionCheck: false,
            hasSessionLog: false
        )

        XCTAssertEqual(state.providerTitle, "Provider: ChatGPT (web) - Sign-in")
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
}

extension HotKeyConfigurationTests {
    func testEffectiveMenuKeyEquivalentDerivesFromKeyCodeNotStoredGlyph() {
        // Live incident 2026-07-24: a legacy F16 profile carried the F18
        // glyph, so the menu displayed the wrong shortcut for a correct
        // binding. The derived glyph must win.
        let staleF16 = HotKeyConfiguration(
            keyCode: 106, // kVK_F16
            carbonModifiers: 0,
            menuKeyEquivalent: String(UnicodeScalar(NSF18FunctionKey)!),
            menuModifierMask: [],
            displayName: "F16",
            mainKeyDisplayName: "F16"
        )
        XCTAssertEqual(
            staleF16.effectiveMenuKeyEquivalent,
            String(UnicodeScalar(NSF16FunctionKey)!)
        )

        let emptyF18 = HotKeyConfiguration(
            keyCode: 79, // kVK_F18
            carbonModifiers: 0,
            menuKeyEquivalent: "",
            menuModifierMask: [],
            displayName: "F18",
            mainKeyDisplayName: "F18"
        )
        XCTAssertEqual(
            emptyF18.effectiveMenuKeyEquivalent,
            String(UnicodeScalar(NSF18FunctionKey)!)
        )
    }

    func testProfilesSortByHotKeyWithUnassignedLast() {
        func profile(_ name: String, keyCode: UInt32?, display: String) -> VoiceProfile {
            let hotKey = keyCode.map {
                HotKeyConfiguration(
                    keyCode: $0, carbonModifiers: 0,
                    menuKeyEquivalent: "", menuModifierMask: [],
                    displayName: display, mainKeyDisplayName: display
                )
            }
            return VoiceProfile(
                name: name, providerID: .openAIRealtime,
                hotKey: hotKey, model: "", voice: ""
            )
        }
        // Deliberately out of order; F-key key codes are non-monotonic
        // (F16=106, F17=64, F18=79) so this proves numeric F-key ordering.
        let sorted = VoiceProfileStore.sortedByHotKey([
            profile("ChatGPT", keyCode: 79, display: "F18"),
            profile("NoKey", keyCode: nil, display: ""),
            profile("OpenAI", keyCode: 106, display: "F16"),
            profile("Castor", keyCode: 64, display: "F17")
        ])
        XCTAssertEqual(sorted.map(\.name), ["OpenAI", "Castor", "ChatGPT", "NoKey"])
    }
}
