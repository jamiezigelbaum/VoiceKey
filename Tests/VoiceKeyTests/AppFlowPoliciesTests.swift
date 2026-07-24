@testable import VoiceKey
import AppKit
import XCTest

final class ProfileActivationPolicyTests: XCTestCase {
    func testMissingHotKeyIsAnActivationFailure() {
        var profile = VoiceProfile.defaultOpenAI()
        profile.hotKey = nil

        XCTAssertEqual(
            ProfileActivationPolicy.failure(
                for: profile,
                hasAPIKey: true
            ),
            .missingHotKey
        )
    }

    func testMissingAPIKeyIsAnActivationFailure() {
        let profile = VoiceProfile.defaultOpenAI()

        XCTAssertEqual(
            ProfileActivationPolicy.failure(
                for: profile,
                hasAPIKey: false
            ),
            .providerNotReady("OpenAI API key required.")
        )
    }

    func testFailureForAnotherLiveChannelPreservesGlobalStatus() {
        let activeID = UUID()
        let requestedID = UUID()

        XCTAssertTrue(
            ProfileActivationPolicy.preservesGlobalStatus(
                requestedProfileID: requestedID,
                activeProfileID: activeID,
                currentStatus: .speaking
            )
        )
        XCTAssertFalse(
            ProfileActivationPolicy.preservesGlobalStatus(
                requestedProfileID: activeID,
                activeProfileID: activeID,
                currentStatus: .speaking
            )
        )
        XCTAssertFalse(
            ProfileActivationPolicy.preservesGlobalStatus(
                requestedProfileID: requestedID,
                activeProfileID: activeID,
                currentStatus: .ready
            )
        )
    }

    func testSettingsFocusShowsFailureOnRequestedChannel() {
        var first = VoiceProfile.defaultOpenAI(name: "First")
        first.hotKey = .defaultVoiceToggle
        var requested = VoiceProfile.defaultOpenAI(name: "Requested")
        requested.hotKey = nil
        let controller = SettingsWindowController(
            profiles: [first, requested],
            credentialStore: PolicyTestCredentialStore(),
            saveProfiles: { _ in }
        )

        controller.showActivationFailure(
            for: requested.id,
            failure: .missingHotKey
        )

        XCTAssertEqual(
            controller.selectedProfileIDSnapshot,
            requested.id
        )
        XCTAssertTrue(
            descendantTextFields(
                in: controller.window?.contentView
            ).contains(where: {
                $0.stringValue ==
                    "Record a global shortcut for this voice channel."
                    && $0.isHidden == false
            })
        )
    }

    private func descendantTextFields(
        in view: NSView?
    ) -> [NSTextField] {
        guard let view else { return [] }
        var fields = view.subviews.flatMap(
            descendantTextFields(in:)
        )
        if let field = view as? NSTextField {
            fields.append(field)
        }
        return fields
    }
}

final class StopWatchdogTests: XCTestCase {
    func testActiveStoppingMenuItemRemainsEnabled() {
        XCTAssertTrue(VoiceProfileMenuPolicy.isProfileItemEnabled(
            profileID: UUID(),
            activeProfileID: UUID(),
            status: .stopping
        ))
    }

    func testCurrentStoppingWatchdogFiresForCapturedProvider() {
        var scheduledAction: (() -> Void)?
        var scheduledDelay: TimeInterval?
        let watchdog = StopWatchdog(
            scheduler: { delay, action in
                scheduledDelay = delay
                scheduledAction = action
                return {}
            }
        )
        var timedOutProviders: [VoiceProviderID] = []

        watchdog.statusDidChange(
            .stopping,
            providerID: .openAIRealtime,
            onTimeout: { timedOutProviders.append($0) }
        )
        scheduledAction?()

        XCTAssertEqual(scheduledDelay, 10)
        XCTAssertEqual(timedOutProviders, [.openAIRealtime])
    }

    func testNonStoppingStatusCancelsStaleWatchdog() {
        var scheduledAction: (() -> Void)?
        var didCancel = false
        let watchdog = StopWatchdog(
            scheduler: { _, action in
                scheduledAction = action
                return { didCancel = true }
            }
        )
        var timeoutCount = 0
        watchdog.statusDidChange(
            .stopping,
            providerID: .openClaw,
            onTimeout: { _ in timeoutCount += 1 }
        )

        watchdog.statusDidChange(
            .ready,
            providerID: .openClaw,
            onTimeout: { _ in timeoutCount += 1 }
        )
        scheduledAction?()

        XCTAssertTrue(didCancel)
        XCTAssertEqual(timeoutCount, 0)
    }
}

final class HotKeyFallbackPolicyTests: XCTestCase {
    func testTrustedPathHonestlyClaimsFallbackWithoutPrompt() {
        var promptCount = 0

        let diagnostic = HotKeyFallbackPolicy.diagnostic(
            hotKeyName: "F16",
            profileName: "OpenAI",
            isAccessibilityTrusted: true,
            requestAccessibilityTrust: { promptCount += 1 }
        )

        XCTAssertTrue(diagnostic.contains("fallback active"))
        XCTAssertEqual(promptCount, 0)
    }

    func testUntrustedPathPromptsAndSaysGlobalKeyCannotWork() {
        var promptCount = 0

        let diagnostic = HotKeyFallbackPolicy.diagnostic(
            hotKeyName: "F16",
            profileName: "OpenAI",
            isAccessibilityTrusted: false,
            requestAccessibilityTrust: { promptCount += 1 }
        )

        XCTAssertTrue(diagnostic.contains("cannot work globally"))
        XCTAssertTrue(diagnostic.contains("Accessibility"))
        XCTAssertFalse(diagnostic.contains("fallback active"))
        XCTAssertEqual(promptCount, 1)
    }
}

final class APIKeyStoreProfileScopeTests: XCTestCase {
    func testCustomKeyMigratesSilentlyFromLegacyOnFirstRead() throws {
        let backend = InMemoryKeychainAccountStore()
        backend.values["custom"] = "legacy-secret"
        let store = APIKeyStore(accountStore: backend)
        let profile = customProfile()

        XCTAssertEqual(store.apiKey(for: profile), "legacy-secret")
        XCTAssertEqual(
            backend.values[
                "custom.\(profile.id.uuidString.lowercased())"
            ],
            "legacy-secret"
        )
        XCTAssertEqual(backend.values["custom"], "legacy-secret")
    }

    func testCustomKeysAreIsolatedByProfileIncludingRemoval()
        throws {
        let backend = InMemoryKeychainAccountStore()
        backend.values["custom"] = "legacy-secret"
        let store = APIKeyStore(accountStore: backend)
        let first = customProfile()
        let second = customProfile()

        try store.setAPIKey("first-secret", for: first)
        try store.setAPIKey("second-secret", for: second)
        XCTAssertEqual(store.apiKey(for: first), "first-secret")
        XCTAssertEqual(store.apiKey(for: second), "second-secret")

        try store.deleteAPIKey(for: first)

        XCTAssertNil(store.apiKey(for: first))
        XCTAssertEqual(store.apiKey(for: second), "second-secret")
        XCTAssertEqual(backend.values["custom"], "legacy-secret")
    }

    func testNewCustomChannelDoesNotInheritRetainedLegacyKey()
        throws {
        let backend = InMemoryKeychainAccountStore()
        backend.values["custom"] = "legacy-secret"
        let store = APIKeyStore(accountStore: backend)
        let existing = customProfile()
        let newlyCreated = customProfile()

        XCTAssertEqual(
            store.apiKey(for: existing),
            "legacy-secret"
        )
        try store.initializeCredentialScope(for: newlyCreated)

        XCTAssertNil(store.apiKey(for: newlyCreated))
        XCTAssertEqual(
            store.apiKey(for: existing),
            "legacy-secret"
        )
        XCTAssertEqual(backend.values["custom"], "legacy-secret")
    }

    func testOpenAIAndOpenClawKeysRemainSharedByProvider() throws {
        let backend = InMemoryKeychainAccountStore()
        let store = APIKeyStore(accountStore: backend)
        var first = VoiceProfile.defaultOpenAI(name: "First")
        let second = VoiceProfile.defaultOpenAI(name: "Second")
        try store.setAPIKey("shared-openai", for: first)
        XCTAssertEqual(store.apiKey(for: second), "shared-openai")

        first.providerID = .openClaw
        var another = second
        another.providerID = .openClaw
        try store.setAPIKey("shared-openclaw", for: first)
        XCTAssertEqual(
            store.apiKey(for: another),
            "shared-openclaw"
        )
    }

    func testCustomProfileSwitchRequiresProviderReplacement() {
        let firstID = UUID()
        let secondID = UUID()
        let current = configuration(
            provider: .custom,
            profileID: firstID
        )
        let next = configuration(
            provider: .custom,
            profileID: secondID
        )

        XCTAssertTrue(
            ProviderReplacementPolicy.requiresReplacement(
                current: current,
                next: next,
                currentProviderID: .custom
            )
        )
        XCTAssertFalse(
            ProviderReplacementPolicy.requiresReplacement(
                current: current,
                next: current,
                currentProviderID: .custom
            )
        )
    }

    func testProviderFactoryResolvesActiveCustomProfileAccount()
        throws {
        let backend = InMemoryKeychainAccountStore()
        let store = APIKeyStore(accountStore: backend)
        let first = customProfile()
        let second = customProfile()
        try store.setAPIKey("first-secret", for: first)
        try store.setAPIKey("second-secret", for: second)
        let activeConfiguration = configuration(
            provider: .custom,
            profileID: second.id
        )

        XCTAssertEqual(
            VoiceProviderFactory.apiKey(
                for: activeConfiguration,
                store: store
            ),
            "second-secret"
        )
    }

    func testSharedCredentialNoteIsOnlyVisibleForSharedProviders() {
        let shared = SettingsWindowController(
            profiles: [VoiceProfile.defaultOpenAI()],
            credentialStore: PolicyTestCredentialStore(),
            saveProfiles: { _ in }
        )
        XCTAssertTrue(
            descendantLabels(in: shared.window?.contentView)
                .contains(where: {
                    $0.stringValue ==
                        "Shared across channels of this provider."
                        && $0.isHidden == false
                })
        )

        let custom = SettingsWindowController(
            profiles: [customProfile()],
            credentialStore: PolicyTestCredentialStore(),
            saveProfiles: { _ in }
        )
        XCTAssertFalse(
            descendantLabels(in: custom.window?.contentView)
                .contains(where: {
                    $0.stringValue ==
                        "Shared across channels of this provider."
                        && $0.isHidden == false
                })
        )
    }

    private func customProfile() -> VoiceProfile {
        VoiceProfile(
            name: "Custom",
            providerID: .custom,
            hotKey: .defaultVoiceToggle,
            model: VoiceProviderID.custom.defaultModel,
            voice: VoiceProviderID.custom.defaultVoice,
            endpointURL: "wss://custom.example.com/realtime"
        )
    }

    private func configuration(
        provider: VoiceProviderID,
        profileID: UUID
    ) -> VoiceSessionConfiguration {
        VoiceSessionConfiguration(
            profileID: profileID,
            providerID: provider,
            model: provider.defaultModel,
            voice: provider.defaultVoice,
            instructions: VoiceSessionConfiguration.defaultInstructions
        )
    }

    private func descendantLabels(in view: NSView?) -> [NSTextField] {
        guard let view else { return [] }
        var labels = view.subviews.flatMap(descendantLabels(in:))
        if let label = view as? NSTextField {
            labels.append(label)
        }
        return labels
    }
}

final class CredentialAttentionPolicyTests: XCTestCase {
    func testResolvedCredentialAttentionClearsToReady() {
        let profile = VoiceProfile.defaultOpenAI()
        var attention: AppOwnedAttentionState? =
            AppOwnedAttentionState(
                profileID: profile.id,
                failure: .providerNotReady(
                    "OpenAI API key required."
                )
            )

        let status = CredentialAttentionPolicy.reconcile(
            attention: &attention,
            profile: profile,
            hasAPIKey: true,
            currentStatus: .needsAttention(
                "OpenAI API key required."
            )
        )

        XCTAssertEqual(status, .ready)
        XCTAssertNil(attention)
    }

    func testDifferentProviderCredentialChangeDoesNotClearAttention() {
        let profile = VoiceProfile.defaultOpenAI()
        var other = VoiceProfile.defaultOpenAI()
        other.id = UUID()
        other.providerID = .custom
        let attention: AppOwnedAttentionState? =
            AppOwnedAttentionState(
                profileID: profile.id,
                failure: .providerNotReady(
                    "OpenAI API key required."
                )
            )

        XCTAssertNil(
            CredentialAttentionPolicy
                .profileAffectedByCredentialChange(
                    attention: attention,
                    changedProfile: other,
                    profiles: [profile, other]
                )
        )
        XCTAssertEqual(attention?.profileID, profile.id)
    }

    func testSharedProviderSiblingCredentialChangeClearsAttention()
        throws {
        let profile = VoiceProfile.defaultOpenAI()
        var sibling = VoiceProfile.defaultOpenAI()
        sibling.id = UUID()
        var attention: AppOwnedAttentionState? =
            AppOwnedAttentionState(
                profileID: profile.id,
                failure: .providerNotReady(
                    "OpenAI API key required."
                )
            )
        let affectedProfile = CredentialAttentionPolicy
            .profileAffectedByCredentialChange(
                attention: attention,
                changedProfile: sibling,
                profiles: [profile, sibling]
            )

        let status = CredentialAttentionPolicy.reconcile(
            attention: &attention,
            profile: try XCTUnwrap(affectedProfile),
            hasAPIKey: true,
            currentStatus: .needsAttention(
                "OpenAI API key required."
            )
        )

        XCTAssertEqual(status, .ready)
        XCTAssertNil(attention)
    }

    func testProviderOriginatedAttentionWithoutAppOwnershipStays() {
        let profile = VoiceProfile.defaultOpenAI()
        var attention: AppOwnedAttentionState?

        XCTAssertNil(CredentialAttentionPolicy.reconcile(
            attention: &attention,
            profile: profile,
            hasAPIKey: true,
            currentStatus: .needsAttention("Provider disconnected")
        ))
        XCTAssertNil(attention)
    }

    func testCredentialResolutionKeepsRemainingHotKeyFailure() {
        var profile = VoiceProfile.defaultOpenAI()
        profile.hotKey = nil
        var attention: AppOwnedAttentionState? =
            AppOwnedAttentionState(
                profileID: profile.id,
                failure: .providerNotReady(
                    "OpenAI API key required."
                )
            )

        let status = CredentialAttentionPolicy.reconcile(
            attention: &attention,
            profile: profile,
            hasAPIKey: true,
            currentStatus: .needsAttention(
                "OpenAI API key required."
            )
        )

        XCTAssertEqual(
            status,
            .needsAttention(
                "Record a global shortcut for this voice channel."
            )
        )
        XCTAssertEqual(attention?.failure, .missingHotKey)
    }
}

final class ProviderEventAttributionTests: XCTestCase {
    func testHandlerKeepsWiringTimeProviderAttribution() {
        var received: [(VoiceProviderEvent, VoiceProviderID)] = []
        let handler = ProviderEventAttribution.handler(
            providerID: .openAIRealtime
        ) {
            received.append(($0, $1))
        }
        var laterConfigurationProvider = VoiceProviderID.openClaw

        handler(.diagnostic("teardown"))
        laterConfigurationProvider = .custom

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.0, .diagnostic("teardown"))
        XCTAssertEqual(received.first?.1, .openAIRealtime)
        XCTAssertEqual(laterConfigurationProvider, .custom)
    }

    func testStaleProviderGenerationDoesNotAdoptStatus() {
        let wiredGeneration = UUID()

        XCTAssertTrue(
            ProviderStatusAdoptionPolicy.shouldAdopt(
                wiredGeneration: wiredGeneration,
                currentGeneration: wiredGeneration
            )
        )
        XCTAssertFalse(
            ProviderStatusAdoptionPolicy.shouldAdopt(
                wiredGeneration: wiredGeneration,
                currentGeneration: UUID()
            )
        )
    }
}

final class EmptyProfileRuntimeTests: XCTestCase {
    func testEmptySettingsDoesNotManufactureChannel() {
        let controller = SettingsWindowController(
            profiles: [],
            credentialStore: PolicyTestCredentialStore(),
            saveProfiles: { _ in }
        )

        XCTAssertEqual(controller.profiles, [])
        XCTAssertFalse(
            VoiceProfileMenuPolicy.providerTargetsEnabled(
                hasProfiles: false
            )
        )
    }

    func testEmptyRuntimeStopsProviderAndReturnsSafeDefault() {
        let provider = EmptyProfileFakeProvider()

        let configuration = EmptyProfileRuntimeLifecycle.reset(
            provider: provider
        )

        XCTAssertEqual(provider.stopCount, 1)
        XCTAssertEqual(configuration, .default)
    }
}

private final class InMemoryKeychainAccountStore:
    KeychainAccountStoring {
    var values: [String: String] = [:]

    func value(service: String, account: String) -> String? {
        values[account]
    }

    func setValue(
        _ value: String,
        service: String,
        account: String
    ) throws {
        values[account] = value
    }

    func deleteValue(service: String, account: String) throws {
        values[account] = nil
    }
}

private final class PolicyTestCredentialStore:
    VoiceCredentialStoring {
    func hasAPIKey(for profile: VoiceProfile) -> Bool { false }
    func apiKey(for profile: VoiceProfile) -> String? { nil }
    func setAPIKey(
        _ apiKey: String,
        for profile: VoiceProfile
    ) throws {}
    func deleteAPIKey(for profile: VoiceProfile) throws {}
    func authorizationToken(forMCPServer id: UUID) -> String? {
        nil
    }
    func setAuthorizationToken(
        _ token: String,
        forMCPServer id: UUID
    ) throws {}
    func deleteAuthorizationToken(forMCPServer id: UUID) throws {}
}

private final class EmptyProfileFakeProvider:
    RealtimeVoiceProvider {
    let id = VoiceProviderID.openAIRealtime
    let capabilities = VoiceProviderCapabilities(
        supportsSpeechToSpeech: true,
        supportsTextInput: true,
        supportsInterruptions: true,
        supportsFunctionCalling: false,
        supportsVisionInput: false,
        supportsProviderInterface: false,
        supportsConnectionCheck: false
    )
    var onEvent: ((VoiceProviderEvent) -> Void)?
    var stopCount = 0

    func prepare() {}
    func update(configuration: VoiceSessionConfiguration) {}
    func toggleVoice() {}
    func stopVoice() { stopCount += 1 }
    func showProviderInterface() {}
    func reloadProviderInterface() {}
}
