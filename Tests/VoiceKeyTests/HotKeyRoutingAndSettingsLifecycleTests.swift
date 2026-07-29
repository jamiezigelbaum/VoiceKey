@testable import VoiceKey
import Carbon
import XCTest

final class HotKeyDispatchTableTests: XCTestCase {
    func testDispatchRoutesEachIDToItsOwnRegistration() {
        let table = HotKeyDispatchTable()
        var calls: [String] = []

        XCTAssertTrue(table.register(id: 101) {
            calls.append("first")
        })
        XCTAssertTrue(table.register(id: 202) {
            calls.append("second")
        })

        XCTAssertTrue(table.dispatch(id: 202))
        XCTAssertTrue(table.dispatch(id: 101))
        XCTAssertEqual(calls, ["second", "first"])
    }

    func testDispatchRejectsUnknownAndUnregisteredIDs() {
        let table = HotKeyDispatchTable()
        var callCount = 0

        XCTAssertFalse(table.dispatch(id: 404))
        XCTAssertTrue(table.register(id: 7) {
            callCount += 1
        })
        XCTAssertFalse(table.register(id: 7) {
            callCount += 100
        })

        table.unregister(id: 7)

        XCTAssertFalse(table.dispatch(id: 7))
        XCTAssertEqual(callCount, 0)
    }
}

final class VoiceProfileProviderSettingsCacheTests: XCTestCase {
    func testSwitchingBackRestoresProviderSpecificSettings() {
        let profile = VoiceProfile(
            name: "Custom OpenAI",
            providerID: .openAIRealtime,
            model: "custom-model",
            voice: "custom-voice",
            endpointURL: "wss://openai.example/realtime"
        )
        var cache = VoiceProfileProviderSettingsCache(profiles: [profile])

        var switchedProfile = profile
        switchedProfile.providerID = .openClaw
        switchedProfile.model = "openclaw-model"
        switchedProfile.voice = "openclaw-voice"
        switchedProfile.endpointURL = "wss://openclaw.example/realtime"
        cache.remember(switchedProfile)

        XCTAssertEqual(
            cache.settings(for: profile.id, provider: .openAIRealtime),
            VoiceProfileProviderSettings(
                model: "custom-model",
                voice: "custom-voice",
                endpointURL: "wss://openai.example/realtime"
            )
        )
        XCTAssertEqual(
            cache.settings(for: profile.id, provider: .openClaw),
            VoiceProfileProviderSettings(
                model: "openclaw-model",
                voice: "openclaw-voice",
                endpointURL: "wss://openclaw.example/realtime"
            )
        )
    }
}

final class VoiceProfileRuntimeLifecycleTests: XCTestCase {
    func testRecordingHotKeyRejectsProfileAbsentFromCommittedList() {
        let savedProfile = VoiceProfile(
            name: "Saved",
            providerID: .openAIRealtime,
            hotKey: nil,
            model: VoiceProviderID.openAIRealtime.defaultModel,
            voice: VoiceProviderID.openAIRealtime.defaultVoice
        )
        let unsavedProfile = VoiceProfile(
            name: "Unsaved",
            providerID: .openAIRealtime,
            hotKey: nil,
            model: VoiceProviderID.openAIRealtime.defaultModel,
            voice: VoiceProviderID.openAIRealtime.defaultVoice
        )
        var registeredProfiles: [VoiceProfile] = []

        let accepted = HotKeyRecordingLifecycle.register(
            .defaultVoiceToggle,
            for: unsavedProfile,
            committedProfiles: [savedProfile],
            register: { profile in
                registeredProfiles.append(profile)
                return true
            }
        )

        XCTAssertFalse(accepted)
        XCTAssertTrue(registeredProfiles.isEmpty)
    }

    func testRecordingHotKeyRegistersCommittedProfileCandidate() {
        var profile = VoiceProfile.defaultOpenAI()
        profile.hotKey = nil
        var registeredProfiles: [VoiceProfile] = []

        let accepted = HotKeyRecordingLifecycle.register(
            .defaultVoiceToggle,
            for: profile,
            committedProfiles: [profile],
            register: {
                registeredProfiles.append($0)
                return true
            }
        )

        XCTAssertTrue(accepted)
        XCTAssertEqual(registeredProfiles.first?.id, profile.id)
        XCTAssertEqual(
            registeredProfiles.first?.hotKey,
            .defaultVoiceToggle
        )
    }

    func testFailedHotKeyRegistrationRestoresPreviousRegistration() {
        let profile = VoiceProfile.defaultOpenAI()
        let replacement = HotKeyConfiguration(
            keyCode: UInt32(kVK_F17),
            carbonModifiers: 0,
            menuKeyEquivalent: "",
            menuModifierMask: [],
            displayName: "F17",
            mainKeyDisplayName: "F17"
        )
        var registrations: [VoiceProfile] = []

        let accepted = HotKeyRecordingLifecycle.register(
            replacement,
            for: profile,
            committedProfiles: [profile],
            register: { candidate in
                registrations.append(candidate)
                return candidate.hotKey != replacement
            }
        )

        XCTAssertFalse(accepted)
        XCTAssertEqual(
            registrations.map(\.hotKey),
            [replacement, .defaultVoiceToggle]
        )
    }

    func testDeletingActiveProfileStopsProviderBeforeReconfiguration() {
        let activeProfile = VoiceProfile(
            name: "Active",
            providerID: .openAIRealtime,
            hotKey: nil,
            model: "active-model",
            voice: "active-voice"
        )
        let replacementProfile = VoiceProfile(
            name: "Replacement",
            providerID: .openAIRealtime,
            hotKey: nil,
            model: "replacement-model",
            voice: "replacement-voice"
        )
        let provider = FakeRealtimeVoiceProvider(id: .openAIRealtime)

        let activeProfileID = ActiveVoiceProfileLifecycle.reconcile(
            activeProfileID: activeProfile.id,
            newProfiles: [replacementProfile],
            provider: provider
        )

        XCTAssertNil(activeProfileID)
        XCTAssertEqual(provider.operations.first, .stop)
        XCTAssertEqual(provider.operations, [.stop])
    }
}

final class SettingsHotKeyRecordingLifecycleTests: XCTestCase {
    func testWindowCloseEndsRecordingAndRequestsHotKeyReregistration() {
        let controller = SettingsWindowController(profiles: [VoiceProfile.defaultOpenAI()])
        let delegate = RecordingSettingsDelegate()
        controller.delegate = delegate

        controller.beginHotKeyRecording()
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))

        XCTAssertEqual(delegate.recordingStates, [true, false])
    }

    func testWindowResignKeyEndsRecordingAndRequestsHotKeyReregistration() {
        let controller = SettingsWindowController(profiles: [VoiceProfile.defaultOpenAI()])
        let delegate = RecordingSettingsDelegate()
        controller.delegate = delegate

        controller.beginHotKeyRecording()
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))

        XCTAssertEqual(delegate.recordingStates, [true, false])
    }
}

private final class RecordingSettingsDelegate: SettingsWindowControllerDelegate {
    private(set) var recordingStates: [Bool] = []

    func settingsController(
        _ controller: SettingsWindowController,
        didUpdateProfiles profiles: [VoiceProfile]
    ) {}

    func settingsController(
        _ controller: SettingsWindowController,
        didRecordHotKey hotKey: HotKeyConfiguration,
        for profile: VoiceProfile
    ) -> Bool {
        true
    }

    func settingsControllerDidUpdateCredentials(_ controller: SettingsWindowController) {}

    func settingsController(
        _ controller: SettingsWindowController,
        isRecordingHotKey: Bool
    ) {
        recordingStates.append(isRecordingHotKey)
    }
}

private final class FakeRealtimeVoiceProvider: RealtimeVoiceProvider {
    enum Operation: Equatable {
        case stop
    }

    let id: VoiceProviderID
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
    private(set) var operations: [Operation] = []

    init(id: VoiceProviderID) {
        self.id = id
    }

    func prepare() {}

    func update(configuration: VoiceSessionConfiguration) {}

    func toggleVoice() {}

    func stopVoice() {
        operations.append(.stop)
    }

    func showProviderInterface() {}

    func reloadProviderInterface() {}
}
