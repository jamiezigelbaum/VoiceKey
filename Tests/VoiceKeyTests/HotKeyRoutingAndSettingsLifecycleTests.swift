@testable import VoiceKey
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
    func testSwitchingBackRestoresProviderSpecificModelAndVoice() {
        let profile = VoiceProfile(
            name: "Custom OpenAI",
            providerID: .openAIRealtime,
            model: "custom-model",
            voice: "custom-voice"
        )
        var cache = VoiceProfileProviderSettingsCache(profiles: [profile])

        var switchedProfile = profile
        switchedProfile.providerID = .openClaw
        switchedProfile.model = "openclaw-model"
        switchedProfile.voice = "openclaw-voice"
        cache.remember(switchedProfile)

        XCTAssertEqual(
            cache.settings(for: profile.id, provider: .openAIRealtime),
            VoiceProfileProviderSettings(model: "custom-model", voice: "custom-voice")
        )
        XCTAssertEqual(
            cache.settings(for: profile.id, provider: .openClaw),
            VoiceProfileProviderSettings(model: "openclaw-model", voice: "openclaw-voice")
        )
    }
}

final class VoiceProfileRuntimeLifecycleTests: XCTestCase {
    func testRecordingHotKeyRegistersUnsavedWorkingCopyProfile() {
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
        var savedProfiles = [savedProfile]
        var registeredProfiles: [VoiceProfile] = []
        var persistedProfiles: [[VoiceProfile]] = []

        let accepted = HotKeyRecordingLifecycle.record(
            .defaultVoiceToggle,
            for: unsavedProfile,
            savedProfiles: &savedProfiles,
            register: { profile in
                registeredProfiles.append(profile)
                return true
            },
            save: { profiles in
                persistedProfiles.append(profiles)
            }
        )

        XCTAssertTrue(accepted)
        XCTAssertEqual(registeredProfiles.count, 1)
        XCTAssertEqual(registeredProfiles.first?.id, unsavedProfile.id)
        XCTAssertEqual(registeredProfiles.first?.hotKey, .defaultVoiceToggle)
        XCTAssertEqual(savedProfiles, [savedProfile])
        XCTAssertTrue(persistedProfiles.isEmpty)
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
