@testable import VoiceKey
import AppKit
import Carbon
import XCTest

final class SettingsAutoApplyTests: XCTestCase {
    func testEveryProfileFieldAutoAppliesAndRoundTripsAfterClose() throws {
        let defaults = try makeDefaults()
        var profile = VoiceProfile.defaultOpenAI()
        profile.hotKey = nil
        let controller = makeController(
            profiles: [profile],
            defaults: defaults
        )

        XCTAssertTrue(controller.apply(.name("Research")))
        XCTAssertTrue(controller.apply(.model("gpt-realtime-custom")))
        XCTAssertTrue(controller.apply(.voice("coral")))
        XCTAssertTrue(controller.apply(.instructions("Be exact.")))
        XCTAssertTrue(controller.apply(
            .endpointURL("wss://api.example.com/realtime")
        ))
        XCTAssertTrue(controller.apply(.webSearchEnabled(true)))
        XCTAssertTrue(controller.apply(
            .speakerModePreference(.alwaysOn)
        ))
        controller.windowWillClose(
            Notification(name: NSWindow.willCloseNotification)
        )

        let reopened = try XCTUnwrap(
            VoiceProfileStore.load(defaults: defaults).first
        )
        XCTAssertEqual(reopened.name, "Research")
        XCTAssertEqual(reopened.model, "gpt-realtime-custom")
        XCTAssertEqual(reopened.voice, "coral")
        XCTAssertEqual(reopened.instructions, "Be exact.")
        XCTAssertEqual(
            reopened.endpointURL,
            "wss://api.example.com/realtime"
        )
        XCTAssertTrue(reopened.webSearchEnabled)
        XCTAssertEqual(reopened.speakerModePreference, .alwaysOn)
    }

    func testProviderPopupChangeAutoAppliesAndRoundTrips() throws {
        let defaults = try makeDefaults()
        let profile = VoiceProfile.defaultOpenAI()
        let controller = makeController(
            profiles: [profile],
            defaults: defaults
        )

        XCTAssertTrue(controller.apply(.provider(.custom)))
        XCTAssertTrue(controller.apply(
            .endpointURL("wss://custom.example.com/realtime")
        ))
        controller.windowWillClose(
            Notification(name: NSWindow.willCloseNotification)
        )

        let reopened = try XCTUnwrap(
            VoiceProfileStore.load(defaults: defaults).first
        )
        XCTAssertEqual(reopened.providerID, .custom)
        XCTAssertEqual(
            reopened.endpointURL,
            "wss://custom.example.com/realtime"
        )
    }

    func testAppKitControlEventsAutoApplyBeforeWindowClose() throws {
        let defaults = try makeDefaults()
        var openAI = VoiceProfile.defaultOpenAI(name: "OpenAI")
        openAI.hotKey = .defaultVoiceToggle
        var providerTarget = VoiceProfile.defaultOpenAI(
            name: "Provider target"
        )
        providerTarget.hotKey = nil
        let credentials = InMemoryCredentialStore()
        let controller = makeController(
            profiles: [openAI, providerTarget],
            defaults: defaults,
            credentials: credentials
        )
        let views = descendantViews(in: controller.window?.contentView)
        let name = try XCTUnwrap(views.compactMap {
            $0 as? NSTextField
        }.first(where: {
            $0.placeholderString ==
                VoiceChannelUIStrings.channelNamePlaceholder
        }))
        let model = try XCTUnwrap(views.compactMap {
            $0 as? NSTextField
        }.first(where: {
            $0.placeholderString ==
                VoiceProviderID.openAIRealtime.defaultModel
        }))
        let voice = try XCTUnwrap(views.compactMap {
            $0 as? NSComboBox
        }.first)
        let endpoint = try XCTUnwrap(views.compactMap {
            $0 as? NSTextField
        }.first(where: {
            $0.placeholderString == "wss://localhost:8080"
        }))
        let key = try XCTUnwrap(views.compactMap {
            $0 as? NSSecureTextField
        }.first)
        let instructions = try XCTUnwrap(views.compactMap {
            $0 as? NSTextView
        }.first(where: { $0.isRichText == false }))
        let speaker = try XCTUnwrap(views.compactMap {
            $0 as? NSPopUpButton
        }.first(where: { popup in
            popup.itemArray.contains(where: {
                ($0.representedObject as? String) ==
                    OpenAISpeakerModePreference.alwaysOn.rawValue
            })
        }))

        name.stringValue = "Event-driven"
        controller.controlTextDidEndEditing(
            Notification(name: NSControl.textDidEndEditingNotification,
                         object: name)
        )
        model.stringValue = "event-model"
        controller.controlTextDidEndEditing(
            Notification(name: NSControl.textDidEndEditingNotification,
                         object: model)
        )
        voice.stringValue = "echo"
        controller.comboBoxSelectionDidChange(
            Notification(name: NSComboBox.selectionDidChangeNotification,
                         object: voice)
        )
        endpoint.stringValue = "wss://events.example.com/realtime"
        controller.controlTextDidEndEditing(
            Notification(name: NSControl.textDidEndEditingNotification,
                         object: endpoint)
        )
        instructions.string = "Commit from the text view."
        controller.textDidEndEditing(
            Notification(name: NSText.didEndEditingNotification,
                         object: instructions)
        )
        speaker.selectItem(withTitle: "Always on")
        sendAction(for: speaker)
        key.stringValue = "openai-secret"
        controller.controlTextDidEndEditing(
            Notification(name: NSControl.textDidEndEditingNotification,
                         object: key)
        )

        let profilePopup = try XCTUnwrap(views.compactMap {
            $0 as? NSPopUpButton
        }.first(where: { popup in
            popup.itemArray.contains(where: {
                ($0.representedObject as? String) ==
                    providerTarget.id.uuidString
            })
        }))
        profilePopup.selectItem(withTitle: "Provider target")
        sendAction(for: profilePopup)
        let providerPopup = try XCTUnwrap(views.compactMap {
            $0 as? NSPopUpButton
        }.first(where: { popup in
            popup.itemArray.contains(where: {
                ($0.representedObject as? String) ==
                    VoiceProviderID.custom.rawValue
            })
        }))
        let customIndex = try XCTUnwrap(
            providerPopup.itemArray.firstIndex(where: {
                ($0.representedObject as? String) ==
                    VoiceProviderID.custom.rawValue
            })
        )
        providerPopup.selectItem(at: customIndex)
        sendAction(for: providerPopup)
        controller.windowWillClose(
            Notification(name: NSWindow.willCloseNotification)
        )

        let reopened = VoiceProfileStore.load(defaults: defaults)
        let reopenedOpenAI = try XCTUnwrap(reopened.first(where: {
            $0.id == openAI.id
        }))
        XCTAssertEqual(reopenedOpenAI.name, "Event-driven")
        XCTAssertEqual(reopenedOpenAI.model, "event-model")
        XCTAssertEqual(reopenedOpenAI.voice, "echo")
        XCTAssertEqual(
            reopenedOpenAI.endpointURL,
            "wss://events.example.com/realtime"
        )
        XCTAssertEqual(
            reopenedOpenAI.instructions,
            "Commit from the text view."
        )
        XCTAssertTrue(reopenedOpenAI.webSearchEnabled)
        XCTAssertEqual(
            reopenedOpenAI.speakerModePreference,
            .alwaysOn
        )
        XCTAssertEqual(
            credentials.apiKey(for: reopenedOpenAI),
            "openai-secret"
        )
        XCTAssertEqual(
            reopened.first(where: {
                $0.id == providerTarget.id
            })?.providerID,
            .custom
        )
    }

    func testCredentialFieldUsesOwnerCopyAndMasksStoredKeyUntilChange()
        throws {
        let profile = VoiceProfile.defaultOpenAI()
        let credentials = InMemoryCredentialStore()
        credentials.apiKeys[profile.id] = "raw-secret"
        let controller = SettingsWindowController(
            profiles: [profile],
            credentialStore: credentials,
            saveProfiles: { _ in }
        )

        XCTAssertEqual(
            controller.credentialFieldSnapshot,
            CredentialFieldSnapshot(
                placeholder: "Paste key here",
                caption:
                    "API keys are stored in Apple keychain and shared across channels of this provider.",
                renderedValue: "••••••••••••",
                isEnabled: false,
                isChangeVisible: true
            )
        )
        XCTAssertFalse(
            controller.credentialFieldSnapshot.renderedValue
                .contains("raw-secret")
        )

        let change = try XCTUnwrap(
            descendantButtons(
                in: controller.window?.contentView
            ).first(where: {
                $0.title == "Change"
                    && $0.isHidden == false
            })
        )
        sendAction(for: change)

        XCTAssertEqual(
            controller.credentialFieldSnapshot.renderedValue,
            ""
        )
        XCTAssertTrue(
            controller.credentialFieldSnapshot.isEnabled
        )
        XCTAssertFalse(
            controller.credentialFieldSnapshot
                .isChangeVisible
        )
    }

    func testToolsAreRemovedAndAdvancedMCPIsCollapsedByDefault()
        throws {
        let controller = SettingsWindowController(
            profiles: [VoiceProfile.defaultOpenAI()],
            credentialStore: InMemoryCredentialStore(),
            saveProfiles: { _ in }
        )
        let views = descendantViews(
            in: controller.window?.contentView
        )
        let visibleText = views.compactMap {
            ($0 as? NSTextField)?.stringValue
        }
        let buttonTitles = views.compactMap {
            ($0 as? NSButton)?.title
        }

        XCTAssertEqual(
            controller.advancedDisclosureSnapshot,
            AdvancedDisclosureSnapshot(
                isVisible: true,
                isExpanded: false
            )
        )
        XCTAssertFalse(visibleText.contains("Tools"))
        XCTAssertFalse(
            buttonTitles.contains(
                "Enable OpenAI web search (hosted tool)"
            )
        )

        let advanced = try XCTUnwrap(
            views.compactMap { $0 as? NSButton }
                .first(where: { $0.title == "Advanced" })
        )
        advanced.state = .on
        sendAction(for: advanced)
        XCTAssertTrue(
            controller.advancedDisclosureSnapshot
                .isExpanded
        )
    }

    func testPermissionsSnapshotIsDerivedLive() {
        var microphone =
            MicrophoneAuthorizationState.notDetermined
        var accessibility = false
        let controller = SettingsWindowController(
            profiles: [VoiceProfile.defaultOpenAI()],
            credentialStore: InMemoryCredentialStore(),
            saveProfiles: { _ in },
            microphoneAuthorizationProvider: {
                microphone
            },
            requestMicrophoneAccess: { _ in },
            isAccessibilityTrusted: {
                accessibility
            },
            requestAccessibilityAccess: {},
            openSystemSettingsURL: { _ in }
        )

        XCTAssertEqual(
            controller.permissionsSnapshot,
            SettingsPermissionsSnapshot(
                microphone: PermissionRowSnapshot(
                    isReady: false,
                    status: "Needs access",
                    actionTitle: "Enable"
                ),
                accessibility: PermissionRowSnapshot(
                    isReady: false,
                    status: "Needs access",
                    actionTitle: "Open Settings"
                )
            )
        )

        microphone = .authorized
        accessibility = true
        XCTAssertEqual(
            controller.permissionsSnapshot,
            SettingsPermissionsSnapshot(
                microphone: PermissionRowSnapshot(
                    isReady: true,
                    status: "Ready",
                    actionTitle: nil
                ),
                accessibility: PermissionRowSnapshot(
                    isReady: true,
                    status: "Ready",
                    actionTitle: nil
                )
            )
        )
    }

    func testPermissionPolicyDistinguishesDeniedAndRestricted() {
        XCTAssertEqual(
            SettingsPermissionPolicy.microphone(.denied),
            PermissionRowSnapshot(
                isReady: false,
                status: "Turned off",
                actionTitle: "Open Settings"
            )
        )
        XCTAssertEqual(
            SettingsPermissionPolicy.microphone(.restricted),
            PermissionRowSnapshot(
                isReady: false,
                status: "Blocked by account or MDM",
                actionTitle: "Open Settings"
            )
        )
    }

    func testPermissionRowsRequestOrOpenTheirExactPane()
        throws {
        var microphone =
            MicrophoneAuthorizationState.notDetermined
        var microphoneRequestCount = 0
        var accessibilityRequestCount = 0
        var openedURLs: [URL] = []
        var accessibility = true
        let controller = SettingsWindowController(
            profiles: [VoiceProfile.defaultOpenAI()],
            credentialStore: InMemoryCredentialStore(),
            saveProfiles: { _ in },
            microphoneAuthorizationProvider: {
                microphone
            },
            requestMicrophoneAccess: { _ in
                microphoneRequestCount += 1
            },
            isAccessibilityTrusted: {
                accessibility
            },
            requestAccessibilityAccess: {
                accessibilityRequestCount += 1
            },
            openSystemSettingsURL: {
                openedURLs.append($0)
            }
        )
        // The accessibility row now appears only for a shortcut that fell back
        // to the untrusted event monitor, and only the delegate knows that.
        // `delegate` is weak, so the double is held for the whole test.
        let delegate = ChannelSetupSettingsDelegate()
        delegate.registration = .eventMonitorFallback
        controller.delegate = delegate

        var visibleButtons = descendantButtons(
            in: controller.window?.contentView
        ).filter {
            $0.isHidden == false
                && ["Enable", "Open Settings"].contains(
                    $0.title
                )
        }
        sendAction(for: try XCTUnwrap(
            visibleButtons.first(where: {
                $0.title == "Enable"
            })
        ))
        XCTAssertEqual(microphoneRequestCount, 1)

        microphone = .denied
        controller.showAndFocus()
        visibleButtons = descendantButtons(
            in: controller.window?.contentView
        ).filter {
            $0.isHidden == false
                && $0.title == "Open Settings"
        }
        sendAction(for: try XCTUnwrap(
            visibleButtons.first
        ))
        XCTAssertEqual(
            openedURLs.last?.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        )

        microphone = .authorized
        accessibility = false
        controller.showAndFocus()
        visibleButtons = descendantButtons(
            in: controller.window?.contentView
        ).filter {
            $0.isHidden == false
                && $0.title == "Open Settings"
        }
        sendAction(for: try XCTUnwrap(
            visibleButtons.first
        ))
        XCTAssertEqual(accessibilityRequestCount, 1)
        XCTAssertEqual(
            openedURLs.last?.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )
        controller.close()
    }

    func testFocusedTextFieldCommitsLatestFieldEditorValueOnClose() throws {
        let defaults = try makeDefaults()
        let profile = VoiceProfile.defaultOpenAI()
        let controller = makeController(
            profiles: [profile],
            defaults: defaults
        )
        controller.showWindow(nil)
        let nameField = try XCTUnwrap(
            findTextField(
                in: controller.window?.contentView,
                placeholder: VoiceChannelUIStrings.channelNamePlaceholder
            )
        )
        nameField.selectText(nil)
        let editor = try XCTUnwrap(nameField.currentEditor())
        editor.string = "Focused close value"

        controller.windowWillClose(
            Notification(name: NSWindow.willCloseNotification)
        )

        XCTAssertEqual(
            VoiceProfileStore.load(defaults: defaults).first?.name,
            "Focused close value"
        )
    }

    func testInvalidEndpointStaysInlineAndDoesNotOverwriteCommittedValue()
        throws {
        let defaults = try makeDefaults()
        var profile = VoiceProfile.defaultOpenAI()
        profile.providerID = .custom
        profile.endpointURL = "wss://working.example.com/realtime"
        VoiceProfileStore.save([profile], defaults: defaults)
        let controller = makeController(
            profiles: [profile],
            defaults: defaults
        )

        XCTAssertFalse(controller.apply(.endpointURL("not a URL")))

        XCTAssertEqual(
            VoiceProfileStore.load(defaults: defaults).first?.endpointURL,
            "wss://working.example.com/realtime"
        )
        XCTAssertTrue(
            descendantViews(in: controller.window?.contentView)
                .compactMap { $0 as? NSTextField }
                .contains(where: {
                    $0.stringValue ==
                        "Use ws://, wss://, http://, or https:// with a host."
                        && $0.isHidden == false
                })
        )
    }

    func testAddDuplicateDeleteEachAutoApply() throws {
        let defaults = try makeDefaults()
        let original = VoiceProfile.defaultOpenAI(name: "Original")
        let controller = makeController(
            profiles: [original],
            defaults: defaults
        )
        let added = VoiceChannelOperations.makeChannel(
            provider: .openClaw,
            existingNames: [original.name]
        )

        XCTAssertTrue(controller.commitNewProfile(added))
        let duplicate = try XCTUnwrap(
            controller.commitDuplicateProfile(added.id)
        )
        XCTAssertTrue(controller.commitDeleteProfile(added.id))

        let reopened = VoiceProfileStore.load(defaults: defaults)
        XCTAssertEqual(
            Set(reopened.map(\.id)),
            Set([original.id, duplicate.id])
        )
        XCTAssertFalse(reopened.contains(where: { $0.id == added.id }))
    }

    func testHotKeyCommitUsesSortedProfileArrayForSaveAndDelegate() {
        var f18 = VoiceProfile.defaultOpenAI(name: "F18")
        f18.hotKey = makeFunctionHotKey(
            keyCode: UInt32(kVK_F18),
            number: 18
        )
        var unassigned = VoiceProfile.defaultOpenAI(name: "Unassigned")
        unassigned.hotKey = nil
        let recorder = SettingsCommitRecorder()
        let controller = SettingsWindowController(
            profiles: [unassigned, f18],
            credentialStore: InMemoryCredentialStore(),
            saveProfiles: { recorder.savedProfiles.append($0) }
        )
        let delegate = AutoApplySettingsDelegate()
        controller.delegate = delegate

        controller.handleRecordedHotKey(
            .defaultVoiceToggle,
            forProfileID: unassigned.id
        )

        let saved = recorder.savedProfiles.last
        let delivered = delegate.profileUpdates.last
        XCTAssertEqual(saved?.map(\.id), [unassigned.id, f18.id])
        XCTAssertEqual(delivered, saved)
        XCTAssertEqual(controller.profiles, saved)
    }

    func testAPIKeyEntryAndRemovalTargetCommittedProviderProfile() {
        var profile = VoiceProfile.defaultOpenAI()
        profile.hotKey = nil
        let credentials = InMemoryCredentialStore()
        let controller = SettingsWindowController(
            profiles: [profile],
            credentialStore: credentials,
            saveProfiles: { _ in }
        )

        XCTAssertTrue(controller.apply(.provider(.custom)))
        XCTAssertTrue(controller.commitAPIKey("custom-secret", for: profile.id))
        XCTAssertEqual(credentials.apiKeyWrites.last?.provider, .custom)
        XCTAssertEqual(credentials.apiKeyWrites.last?.profileID, profile.id)
        XCTAssertTrue(controller.commitRemoveAPIKey(for: profile.id))
        XCTAssertNil(credentials.apiKey(for: controller.profiles[0]))
    }

    func testMCPAddEditRemoveEachAutoApplyAndRoundTrip() throws {
        let defaults = try makeDefaults()
        let credentials = InMemoryCredentialStore()
        let profile = VoiceProfile.defaultOpenAI()
        let controller = makeController(
            profiles: [profile],
            defaults: defaults,
            credentials: credentials
        )
        let serverID = UUID()

        XCTAssertTrue(controller.commitMCPServer(
            MCPServerConfiguration(
                id: serverID,
                label: "calendar",
                urlString: "https://mcp.example.com"
            ),
            authorization: "first-token",
            profileID: profile.id
        ))
        XCTAssertEqual(
            VoiceProfileStore.load(defaults: defaults)
                .first?.mcpServers.first?.label,
            "calendar"
        )
        XCTAssertEqual(
            credentials.authorizationToken(forMCPServer: serverID),
            "first-token"
        )

        XCTAssertTrue(controller.commitMCPServer(
            MCPServerConfiguration(
                id: serverID,
                label: "calendar edited",
                urlString: "https://mcp.example.com/v2",
                allowedTools: ["search"]
            ),
            authorization: "second-token",
            profileID: profile.id
        ))
        XCTAssertEqual(
            VoiceProfileStore.load(defaults: defaults)
                .first?.mcpServers.first?.label,
            "calendar edited"
        )
        XCTAssertEqual(
            credentials.authorizationToken(forMCPServer: serverID),
            "second-token"
        )

        XCTAssertTrue(controller.commitRemoveMCPServer(
            serverID,
            profileID: profile.id
        ))
        XCTAssertEqual(
            VoiceProfileStore.load(defaults: defaults).first?.mcpServers,
            []
        )
        XCTAssertNil(
            credentials.authorizationToken(forMCPServer: serverID)
        )
    }

    func testMCPBatchWritesProfilesBeforeTokens() {
        let events = SettingsCommitRecorder()
        let credentials = InMemoryCredentialStore()
        credentials.events = events
        var profile = VoiceProfile.defaultOpenAI()
        // WO-N ruling: compatibility storage is always true for OpenAI.
        profile.webSearchEnabled = true
        var next = profile
        let serverID = UUID()
        next.mcpServers = [
            MCPServerConfiguration(
                id: serverID,
                label: "tools",
                urlString: "https://mcp.example.com"
            )
        ]

        XCTAssertNoThrow(try SettingsAutoApplyPersistence.commit(
            previousProfiles: [profile],
            nextProfiles: [next],
            authorizationMutations: [
                MCPAuthorizationMutation(
                    serverID: serverID,
                    token: "token"
                )
            ],
            saveProfiles: {
                events.savedProfiles.append($0)
                events.events.append("profiles")
            },
            credentialStore: credentials
        ))
        XCTAssertEqual(events.events, ["profiles", "token.set"])
    }

    func testMCPTokenFailureRollsBackProfileAndTokenBatch() {
        let events = SettingsCommitRecorder()
        let credentials = InMemoryCredentialStore()
        credentials.events = events
        var profile = VoiceProfile.defaultOpenAI()
        // WO-N ruling: rollback storage also keeps web search true.
        profile.webSearchEnabled = true
        var next = profile
        let firstServerID = UUID()
        let failingServerID = UUID()
        next.mcpServers = [
            MCPServerConfiguration(
                id: firstServerID,
                label: "first",
                urlString: "https://first.example.com"
            ),
            MCPServerConfiguration(
                id: failingServerID,
                label: "second",
                urlString: "https://second.example.com"
            )
        ]
        credentials.tokens[firstServerID] = "old-first"
        credentials.tokens[failingServerID] = "old-second"
        credentials.failingToken = "new-second"

        XCTAssertThrowsError(try SettingsAutoApplyPersistence.commit(
            previousProfiles: [profile],
            nextProfiles: [next],
            authorizationMutations: [
                MCPAuthorizationMutation(
                    serverID: firstServerID,
                    token: "new-first"
                ),
                MCPAuthorizationMutation(
                    serverID: failingServerID,
                    token: "new-second"
                )
            ],
            saveProfiles: {
                events.savedProfiles.append($0)
                events.events.append("profiles")
            },
            credentialStore: credentials
        ))
        XCTAssertEqual(events.savedProfiles, [[next], [profile]])
        XCTAssertEqual(
            credentials.authorizationToken(
                forMCPServer: firstServerID
            ),
            "old-first"
        )
        XCTAssertEqual(
            credentials.authorizationToken(
                forMCPServer: failingServerID
            ),
            "old-second"
        )
    }

    func testInvalidMCPFieldsDoNotCommit() {
        let profile = VoiceProfile.defaultOpenAI()
        let recorder = SettingsCommitRecorder()
        let controller = SettingsWindowController(
            profiles: [profile],
            credentialStore: InMemoryCredentialStore(),
            saveProfiles: { recorder.savedProfiles.append($0) }
        )

        XCTAssertFalse(controller.commitMCPServer(
            MCPServerConfiguration(
                label: "",
                urlString: "https://mcp.example.com"
            ),
            authorization: nil,
            profileID: profile.id
        ))
        XCTAssertFalse(controller.commitMCPServer(
            MCPServerConfiguration(
                label: "tools",
                urlString: "not-a-url"
            ),
            authorization: nil,
            profileID: profile.id
        ))
        XCTAssertTrue(recorder.savedProfiles.isEmpty)
        XCTAssertEqual(controller.profiles.first?.mcpServers, [])
    }

    func testOpenClawLoadAndApplyUseSameCommittedEndpoint() throws {
        let defaults = try makeDefaults()
        var profile = VoiceProfile(
            name: "OpenClaw",
            providerID: .openClaw,
            model: "",
            voice: "",
            endpointURL: "ws://old.example.com"
        )
        let firstService = EndpointRecordingRuntimeService()
        let first = SettingsWindowController(
            profiles: [profile],
            openClawRuntimeService: firstService,
            credentialStore: InMemoryCredentialStore(),
            saveProfiles: { VoiceProfileStore.save($0, defaults: defaults) }
        )
        XCTAssertTrue(first.apply(
            .endpointURL("ws://new.example.com")
        ))

        profile = try XCTUnwrap(
            VoiceProfileStore.load(defaults: defaults).first
        )
        let reopenedService = EndpointRecordingRuntimeService()
        let reopened = SettingsWindowController(
            profiles: [profile],
            openClawRuntimeService: reopenedService,
            credentialStore: InMemoryCredentialStore(),
            saveProfiles: { VoiceProfileStore.save($0, defaults: defaults) }
        )
        reopened.applyOpenClawRuntimeSettings()

        XCTAssertEqual(
            reopenedService.loadEndpoints,
            ["ws://new.example.com"]
        )
        XCTAssertEqual(
            reopenedService.applyEndpoints,
            ["ws://new.example.com"]
        )
    }

    func testOpenClawConnectionTestRowUsesSharedTypedTester() throws {
        let profile = VoiceProfile(
            name: "OpenClaw",
            providerID: .openClaw,
            model: "",
            voice: "",
            endpointURL: "https://gateway.example.com"
        )
        let tester = SettingsOpenClawConnectionTester()
        var savedFacts: [Bool] = []
        let controller = SettingsWindowController(
            profiles: [profile],
            openClawConnectionTester: tester,
            saveOpenClawConnectionFact: {
                savedFacts.append($0)
            },
            credentialStore: InMemoryCredentialStore(),
            saveProfiles: { _ in }
        )

        XCTAssertTrue(
            controller.openClawConnectionTestSnapshot
                .isVisible
        )
        let button = try XCTUnwrap(
            descendantButtons(
                in: controller.window?.contentView
            ).first {
                $0.title == "Test Connection"
            }
        )
        sendAction(for: button)
        XCTAssertEqual(
            controller.openClawConnectionTestSnapshot,
            OpenClawConnectionTestSnapshot(
                isVisible: true,
                isTesting: true,
                status: "Testing…"
            )
        )
        XCTAssertEqual(
            tester.endpoints,
            ["https://gateway.example.com"]
        )

        tester.complete(.ok(
            serverVersion: "2026.7.1-2",
            scopes: ["operator.read"]
        ))
        XCTAssertEqual(
            controller.openClawConnectionTestSnapshot,
            OpenClawConnectionTestSnapshot(
                isVisible: true,
                isTesting: false,
                status:
                    "Connected to OpenClaw (gateway 2026.7.1-2) using the token you entered."
            )
        )
        XCTAssertEqual(savedFacts, [true])

        sendAction(for: button)
        tester.complete(.unreachable(
            endpointsTried: ["wss://gateway.example.com"]
        ))
        XCTAssertEqual(
            controller.openClawConnectionTestSnapshot.status,
            "Gateway unreachable (1 addresses tried)."
        )
        XCTAssertEqual(
            savedFacts,
            [true],
            "A failed test must not downgrade a prior connection fact."
        )

        sendAction(for: button)
        tester.complete(.deviceTokenMismatch)
        XCTAssertEqual(
            controller.openClawConnectionTestSnapshot.status,
            "OpenClaw’s saved device approval is no longer valid. Re-pair this Mac in OpenClaw, then try again."
        )
        XCTAssertEqual(savedFacts, [true])

        controller.profiles = [
            VoiceProfile.defaultOpenAI()
        ]
        XCTAssertFalse(
            controller.openClawConnectionTestSnapshot
                .isVisible
        )
    }

    /// The 2026-07-25 incident, end to end in Settings: a pasted token is
    /// rejected, the failure says so, and one click removes it and re-tests.
    func testRejectedEnteredTokenOffersInlineRemovalAndRetests() throws {
        let profile = VoiceProfile(
            name: "OpenClaw",
            providerID: .openClaw,
            model: "",
            voice: "",
            endpointURL: "ws://127.0.0.1:18790"
        )
        let credentials = InMemoryCredentialStore()
        credentials.apiKeys[profile.id] = "stale-entered-token"
        let tester = SettingsOpenClawConnectionTester()
        tester.tokenSource = .enteredToken
        tester.discoveryWouldSupplyDifferentToken = true
        let controller = SettingsWindowController(
            profiles: [profile],
            openClawConnectionTester: tester,
            saveOpenClawConnectionFact: { _ in },
            credentialStore: credentials,
            saveProfiles: { _ in },
            hasDiscoveredGatewayToken: { true }
        )

        let testButton = try XCTUnwrap(
            descendantButtons(in: controller.window?.contentView)
                .first { $0.title == "Test Connection" }
        )
        sendAction(for: testButton)
        tester.complete(.gatewayTokenMismatch)

        XCTAssertEqual(
            controller.openClawConnectionTestSnapshot,
            OpenClawConnectionTestSnapshot(
                isVisible: true,
                isTesting: false,
                status: """
                    OpenClaw rejected the token you entered. Remove it and VoiceKey \
                    will use this Mac's OpenClaw pairing instead.
                    """,
                recoveryActionTitle: "Use This Mac's Pairing"
            )
        )

        let recovery = try XCTUnwrap(
            descendantButtons(in: controller.window?.contentView)
                .first {
                    $0.title == "Use This Mac's Pairing"
                        && $0.isHidden == false
                }
        )
        tester.tokenSource = .secretsJSON
        tester.discoveryWouldSupplyDifferentToken = false
        sendAction(for: recovery)

        XCTAssertNil(
            credentials.apiKeys[profile.id],
            "The rejected token must be removed."
        )
        XCTAssertEqual(
            tester.endpoints.count,
            2,
            "Removing the token must immediately re-test."
        )
        tester.complete(.ok(
            serverVersion: "2026.7.1-2",
            scopes: ["operator.talk"]
        ))
        XCTAssertEqual(
            controller.openClawConnectionTestSnapshot.status,
            "Connected to OpenClaw (gateway 2026.7.1-2) using this Mac's OpenClaw pairing."
        )
        XCTAssertNil(
            controller.openClawConnectionTestSnapshot
                .recoveryActionTitle
        )
    }

    func testRejectedTokenWithoutADiscoveredFallbackOffersNoInlineAction() throws {
        let profile = VoiceProfile(
            name: "OpenClaw",
            providerID: .openClaw,
            model: "",
            voice: "",
            endpointURL: "ws://127.0.0.1:18790"
        )
        let credentials = InMemoryCredentialStore()
        credentials.apiKeys[profile.id] = "wrong-token"
        let tester = SettingsOpenClawConnectionTester()
        tester.tokenSource = .enteredToken
        tester.discoveryWouldSupplyDifferentToken = false
        let controller = SettingsWindowController(
            profiles: [profile],
            openClawConnectionTester: tester,
            saveOpenClawConnectionFact: { _ in },
            credentialStore: credentials,
            saveProfiles: { _ in },
            hasDiscoveredGatewayToken: { false }
        )

        let testButton = try XCTUnwrap(
            descendantButtons(in: controller.window?.contentView)
                .first { $0.title == "Test Connection" }
        )
        sendAction(for: testButton)
        tester.complete(.gatewayTokenMismatch)

        XCTAssertEqual(
            controller.openClawConnectionTestSnapshot.status,
            """
            OpenClaw rejected the token you entered. Check it, or remove it and \
            pair this Mac with OpenClaw.
            """
        )
        XCTAssertNil(
            controller.openClawConnectionTestSnapshot
                .recoveryActionTitle
        )
    }

    // MARK: - Credential entry is demoted while a pairing already works

    func testDiscoveredPairingHidesTheTokenFieldUntilAsked() throws {
        let profile = VoiceProfile(
            name: "OpenClaw",
            providerID: .openClaw,
            model: "",
            voice: "",
            endpointURL: ""
        )
        let controller = SettingsWindowController(
            profiles: [profile],
            credentialStore: InMemoryCredentialStore(),
            saveProfiles: { _ in },
            hasDiscoveredGatewayToken: { true }
        )

        let snapshot = controller.credentialFieldSnapshot
        XCTAssertFalse(
            snapshot.isFieldVisible,
            "A working pairing must not present an empty field to fill."
        )
        XCTAssertTrue(snapshot.isUseDifferentTokenVisible)
        XCTAssertEqual(
            controller.credentialStatusSnapshot,
            "Using this Mac's OpenClaw pairing."
        )

        let reveal = try XCTUnwrap(
            descendantButtons(in: controller.window?.contentView)
                .first {
                    $0.title == "Use a Different Token"
                        && $0.isHidden == false
                }
        )
        sendAction(for: reveal)

        XCTAssertTrue(
            controller.credentialFieldSnapshot.isFieldVisible
        )
        XCTAssertTrue(
            controller.credentialFieldSnapshot.isEnabled
        )
        XCTAssertFalse(
            controller.credentialFieldSnapshot
                .isUseDifferentTokenVisible
        )
        XCTAssertEqual(
            controller.credentialFieldSnapshot.placeholder,
            "Paste an OpenClaw gateway token"
        )
        XCTAssertEqual(
            controller.credentialFieldSnapshot.caption,
            """
            A token you enter is stored in Apple keychain and replaces this Mac's \
            OpenClaw pairing.
            """,
            "Revealing the field must warn what entering a token does."
        )
    }

    func testWithoutAnyPairingTheTokenFieldIsPrimary() {
        let profile = VoiceProfile(
            name: "OpenClaw",
            providerID: .openClaw,
            model: "",
            voice: "",
            endpointURL: ""
        )
        let controller = SettingsWindowController(
            profiles: [profile],
            credentialStore: InMemoryCredentialStore(),
            saveProfiles: { _ in },
            hasDiscoveredGatewayToken: { false }
        )

        let snapshot = controller.credentialFieldSnapshot
        XCTAssertTrue(snapshot.isFieldVisible)
        XCTAssertTrue(snapshot.isEnabled)
        XCTAssertFalse(snapshot.isUseDifferentTokenVisible)
        XCTAssertEqual(
            snapshot.placeholder,
            "Paste an OpenClaw gateway token"
        )
        XCTAssertEqual(
            snapshot.caption,
            """
            Gateway tokens are stored in Apple keychain and shared across OpenClaw \
            channels.
            """,
            "With nothing to override, the caption must not warn about a pairing."
        )
        XCTAssertEqual(
            controller.credentialStatusSnapshot,
            "No gateway token found — paste one, or pair this Mac with OpenClaw."
        )
    }

    func testEnteredTokenSaysItOverridesThisMacsPairing() {
        let profile = VoiceProfile(
            name: "OpenClaw",
            providerID: .openClaw,
            model: "",
            voice: "",
            endpointURL: ""
        )
        let credentials = InMemoryCredentialStore()
        credentials.apiKeys[profile.id] = "entered-token"
        let controller = SettingsWindowController(
            profiles: [profile],
            credentialStore: credentials,
            saveProfiles: { _ in },
            hasDiscoveredGatewayToken: { true }
        )

        XCTAssertEqual(
            controller.credentialStatusSnapshot,
            "Using the token you entered — it overrides this Mac's OpenClaw pairing."
        )
        let snapshot = controller.credentialFieldSnapshot
        XCTAssertTrue(snapshot.isFieldVisible)
        XCTAssertEqual(snapshot.renderedValue, "••••••••••••")
        XCTAssertFalse(snapshot.renderedValue.contains("entered-token"))
        XCTAssertFalse(snapshot.isUseDifferentTokenVisible)
    }

    func testWindowDefaultsTallEnoughAndHasNoSaveButton() {
        var profile = VoiceProfile.defaultOpenAI()
        profile.mcpServers = [
            MCPServerConfiguration(
                label: "tools",
                urlString: "https://mcp.example.com"
            )
        ]
        let controller = SettingsWindowController(
            profiles: [profile],
            credentialStore: InMemoryCredentialStore(),
            saveProfiles: { _ in }
        )
        let sizing = controller.windowSizingSnapshot

        XCTAssertGreaterThanOrEqual(
            sizing.contentHeight,
            sizing.formHeight
        )
        XCTAssertFalse(
            descendantButtons(in: controller.window?.contentView)
                .contains(where: { $0.title == "Save" })
        )
        XCTAssertTrue(
            controller.window?.styleMask.contains(.resizable) == true
        )
    }

    // MARK: - Channel setup section

    func testChannelSetupSnapshotIsDerivedLive() {
        var microphone = MicrophoneAuthorizationState.denied
        var accessibility = false
        var profile = VoiceProfile.defaultOpenAI()
        profile.hotKey = nil
        let credentials = InMemoryCredentialStore()
        let controller = SettingsWindowController(
            profiles: [profile],
            credentialStore: credentials,
            saveProfiles: { _ in },
            microphoneAuthorizationProvider: { microphone },
            requestMicrophoneAccess: { _ in },
            isAccessibilityTrusted: { accessibility },
            requestAccessibilityAccess: {},
            openSystemSettingsURL: { _ in }
        )

        let before = controller.channelSetupSnapshot
        XCTAssertEqual(
            before.outstanding.map(\.id),
            [.activation, .microphone]
        )
        XCTAssertFalse(before.isReady)

        microphone = .authorized
        accessibility = true
        let after = controller.channelSetupSnapshot
        XCTAssertNotEqual(before, after)
        XCTAssertEqual(after.outstanding.map(\.id), [.activation])
    }

    func testReadyChannelCollapsesToTheSummaryLine() throws {
        let profile = VoiceProfile.defaultOpenAI()
        let credentials = InMemoryCredentialStore()
        credentials.apiKeys[profile.id] = "sk-test"
        let controller = SettingsWindowController(
            profiles: [profile],
            credentialStore: credentials,
            saveProfiles: { _ in },
            microphoneAuthorizationProvider: { .authorized },
            requestMicrophoneAccess: { _ in },
            isAccessibilityTrusted: { false },
            requestAccessibilityAccess: {},
            openSystemSettingsURL: { _ in }
        )

        XCTAssertTrue(controller.channelSetupSnapshot.isReady)
        assertEverySetupRowIsHidden(in: controller)
        let summary = try XCTUnwrap(
            descendantViews(in: controller.window?.contentView)
                .compactMap { $0 as? NSTextField }
                .first(where: {
                    $0.stringValue == ChannelSetupPolicy.readySummary
                })
        )
        XCTAssertFalse(summary.isHidden)
    }

    func testEmptyFormShowsTheAddAChannelSummary() throws {
        let controller = SettingsWindowController(
            profiles: [],
            credentialStore: InMemoryCredentialStore(),
            saveProfiles: { _ in },
            microphoneAuthorizationProvider: { .denied },
            requestMicrophoneAccess: { _ in },
            isAccessibilityTrusted: { false },
            requestAccessibilityAccess: {},
            openSystemSettingsURL: { _ in }
        )

        XCTAssertEqual(
            controller.channelSetupSnapshot.summary,
            ChannelSetupPolicy.noChannelSummary
        )
        XCTAssertTrue(controller.channelSetupSnapshot.outstanding.isEmpty)
        assertEverySetupRowIsHidden(in: controller)
        XCTAssertTrue(
            descendantViews(in: controller.window?.contentView)
                .compactMap { $0 as? NSTextField }
                .contains(where: {
                    $0.stringValue == ChannelSetupPolicy.noChannelSummary
                        && $0.isHidden == false
                })
        )
    }

    func testSwitchingChannelsResyncsSetup() throws {
        var carbon = VoiceProfile.defaultOpenAI(name: "Carbon")
        carbon.hotKey = .defaultVoiceToggle
        var fallback = VoiceProfile.defaultOpenAI(name: "Fallback")
        fallback.hotKey = makeFunctionHotKey(keyCode: 122, number: 1)
        let credentials = InMemoryCredentialStore()
        credentials.apiKeys[carbon.id] = "sk-test"
        credentials.apiKeys[fallback.id] = "sk-test"
        let controller = SettingsWindowController(
            profiles: [carbon, fallback],
            credentialStore: credentials,
            saveProfiles: { _ in },
            microphoneAuthorizationProvider: { .authorized },
            requestMicrophoneAccess: { _ in },
            isAccessibilityTrusted: { false },
            requestAccessibilityAccess: {},
            openSystemSettingsURL: { _ in }
        )
        let delegate = ChannelSetupSettingsDelegate()
        delegate.registrationsByProfile = [
            carbon.id: .carbonRegistered,
            fallback.id: .eventMonitorFallback
        ]
        controller.delegate = delegate

        let popup = try XCTUnwrap(
            descendantViews(in: controller.window?.contentView)
                .compactMap { $0 as? NSPopUpButton }
                .first(where: { popup in
                    popup.itemArray.contains(where: {
                        ($0.representedObject as? String)
                            == fallback.id.uuidString
                    })
                })
        )

        popup.selectItem(withTitle: "Carbon")
        sendAction(for: popup)
        XCTAssertFalse(
            controller.channelSetupSnapshot.outstanding.contains(where: {
                $0.id == .accessibility
            })
        )

        popup.selectItem(withTitle: "Fallback")
        sendAction(for: popup)
        XCTAssertTrue(
            controller.channelSetupSnapshot.outstanding.contains(where: {
                $0.id == .accessibility
            })
        )
        XCTAssertTrue(
            descendantButtons(in: controller.window?.contentView)
                .contains(where: {
                    $0.identifier?.rawValue
                        == ChannelSetupRequirementID.accessibility.rawValue
                        && $0.isHidden == false
                })
        )
    }

    func testAddingAChannelNeverRequestsMicrophoneAccess() {
        var microphoneRequestCount = 0
        var accessibilityRequestCount = 0
        let controller = SettingsWindowController(
            profiles: [VoiceProfile.defaultOpenAI()],
            credentialStore: InMemoryCredentialStore(),
            saveProfiles: { _ in },
            microphoneAuthorizationProvider: { .notDetermined },
            requestMicrophoneAccess: { _ in
                microphoneRequestCount += 1
            },
            isAccessibilityTrusted: { false },
            requestAccessibilityAccess: {
                accessibilityRequestCount += 1
            },
            openSystemSettingsURL: { _ in }
        )

        let added = VoiceChannelOperations.makeChannel(
            provider: .openAIRealtime,
            existingNames: []
        )
        XCTAssertTrue(controller.commitNewProfile(added))

        XCTAssertEqual(microphoneRequestCount, 0)
        XCTAssertEqual(accessibilityRequestCount, 0)
    }

    /// Rendering the section — repeatedly, in every registration state — must
    /// never ask the OS for anything. A 1 Hz permission prompt would be a
    /// serious regression.
    func testRepeatedRenderingNeverRequestsPermissions() {
        var microphoneRequestCount = 0
        var accessibilityRequestCount = 0
        let profile = VoiceProfile.defaultOpenAI()
        let controller = SettingsWindowController(
            profiles: [profile],
            credentialStore: InMemoryCredentialStore(),
            saveProfiles: { _ in },
            microphoneAuthorizationProvider: { .notDetermined },
            requestMicrophoneAccess: { _ in
                microphoneRequestCount += 1
            },
            isAccessibilityTrusted: { false },
            requestAccessibilityAccess: {
                accessibilityRequestCount += 1
            },
            openSystemSettingsURL: { _ in }
        )
        let delegate = ChannelSetupSettingsDelegate()
        controller.delegate = delegate

        for registration: ChannelHotKeyRegistration in [
            .noHotKey, .carbonRegistered, .eventMonitorFallback, .unknown
        ] {
            delegate.registration = registration
            for _ in 0..<25 {
                controller.showAndFocus()
                _ = controller.channelSetupSnapshot
            }
        }
        controller.close()

        XCTAssertEqual(microphoneRequestCount, 0)
        XCTAssertEqual(accessibilityRequestCount, 0)
    }

    func testAddingAChannelSurfacesTheMissingShortcut() throws {
        let controller = SettingsWindowController(
            profiles: [VoiceProfile.defaultOpenAI()],
            credentialStore: InMemoryCredentialStore(),
            saveProfiles: { _ in },
            microphoneAuthorizationProvider: { .denied },
            requestMicrophoneAccess: { _ in },
            isAccessibilityTrusted: { false },
            requestAccessibilityAccess: {},
            openSystemSettingsURL: { _ in }
        )

        let added = VoiceChannelOperations.makeChannel(
            provider: .openAIRealtime,
            existingNames: []
        )
        XCTAssertTrue(controller.commitNewProfile(added))
        let popup = try XCTUnwrap(
            descendantViews(in: controller.window?.contentView)
                .compactMap { $0 as? NSPopUpButton }
                .first(where: { popup in
                    popup.itemArray.contains(where: {
                        ($0.representedObject as? String)
                            == added.id.uuidString
                    })
                })
        )
        popup.selectItem(withTitle: added.name)
        sendAction(for: popup)

        let outstanding = controller.channelSetupSnapshot.outstanding
        XCTAssertEqual(outstanding.map(\.id), [.activation, .microphone])
        let activation = try XCTUnwrap(outstanding.first)
        XCTAssertEqual(activation.title, "Shortcut")
        XCTAssertEqual(activation.row.status, "Not set")
        XCTAssertEqual(
            activation.reason,
            ProfileActivationFailure.missingHotKey.settingsMessage
        )
    }

    func testChangingProviderRebuildsRequirements() throws {
        let profile = VoiceProfile.defaultOpenAI()
        let controller = SettingsWindowController(
            profiles: [profile],
            credentialStore: InMemoryCredentialStore(),
            saveProfiles: { _ in },
            microphoneAuthorizationProvider: { .denied },
            requestMicrophoneAccess: { _ in },
            isAccessibilityTrusted: { false },
            requestAccessibilityAccess: {},
            openSystemSettingsURL: { _ in }
        )

        XCTAssertEqual(
            controller.channelSetupSnapshot.outstanding.map(\.id),
            [.activation, .microphone]
        )

        let providerPopup = try XCTUnwrap(
            descendantViews(in: controller.window?.contentView)
                .compactMap { $0 as? NSPopUpButton }
                .first(where: { popup in
                    popup.itemArray.contains(where: {
                        ($0.representedObject as? String)
                            == VoiceProviderID.chatGPTWeb.rawValue
                    })
                })
        )
        let index = try XCTUnwrap(
            providerPopup.itemArray.firstIndex(where: {
                ($0.representedObject as? String)
                    == VoiceProviderID.chatGPTWeb.rawValue
            })
        )
        providerPopup.selectItem(at: index)
        sendAction(for: providerPopup)

        XCTAssertEqual(
            controller.channelSetupSnapshot.outstanding.map(\.id),
            [.microphone]
        )
    }

    func testSetupChangeNotifiesTheDelegate() {
        var microphone = MicrophoneAuthorizationState.denied
        var profile = VoiceProfile.defaultOpenAI()
        profile.hotKey = .defaultVoiceToggle
        let credentials = InMemoryCredentialStore()
        credentials.apiKeys[profile.id] = "sk-test"
        let controller = SettingsWindowController(
            profiles: [profile],
            credentialStore: credentials,
            saveProfiles: { _ in },
            microphoneAuthorizationProvider: { microphone },
            requestMicrophoneAccess: { _ in },
            isAccessibilityTrusted: { true },
            requestAccessibilityAccess: {},
            openSystemSettingsURL: { _ in }
        )
        let delegate = ChannelSetupSettingsDelegate()
        controller.delegate = delegate
        controller.showAndFocus()
        XCTAssertEqual(delegate.setupChangeCount, 0)

        microphone = .authorized
        waitUntil(
            { delegate.setupChangeCount > 0 },
            "polling never noticed the granted microphone"
        )
        controller.close()
    }

    func testNoStaleButtonSurvivesASatisfiedRequirement() {
        var microphone = MicrophoneAuthorizationState.denied
        let profile = VoiceProfile.defaultOpenAI()
        let credentials = InMemoryCredentialStore()
        credentials.apiKeys[profile.id] = "sk-test"
        let controller = SettingsWindowController(
            profiles: [profile],
            credentialStore: credentials,
            saveProfiles: { _ in },
            microphoneAuthorizationProvider: { microphone },
            requestMicrophoneAccess: { _ in },
            isAccessibilityTrusted: { false },
            requestAccessibilityAccess: {},
            openSystemSettingsURL: { _ in }
        )
        let delegate = ChannelSetupSettingsDelegate()
        delegate.registration = .carbonRegistered
        controller.delegate = delegate
        controller.showAndFocus()

        XCTAssertTrue(
            descendantButtons(in: controller.window?.contentView)
                .contains(where: {
                    $0.isHidden == false && $0.title == "Open Settings"
                })
        )

        microphone = .authorized
        controller.showAndFocus()

        XCTAssertFalse(
            descendantButtons(in: controller.window?.contentView)
                .contains(where: {
                    $0.isHidden == false
                        && ["Enable", "Open Settings"].contains($0.title)
                })
        )
        controller.close()
    }

    func testWindowIsTallEnoughForAChannelMissingEverything() {
        var profile = VoiceProfile.defaultOpenAI()
        profile.hotKey = nil
        profile.mcpServers = [
            MCPServerConfiguration(
                label: "tools",
                urlString: "https://mcp.example.com"
            )
        ]
        let controller = SettingsWindowController(
            profiles: [profile],
            credentialStore: InMemoryCredentialStore(),
            saveProfiles: { _ in },
            microphoneAuthorizationProvider: { .denied },
            requestMicrophoneAccess: { _ in },
            isAccessibilityTrusted: { false },
            requestAccessibilityAccess: {},
            openSystemSettingsURL: { _ in }
        )
        // Worst case: all three rows and all three reason lines at once.
        let delegate = ChannelSetupSettingsDelegate()
        delegate.registration = .eventMonitorFallback
        controller.delegate = delegate
        controller.showAndFocus()
        XCTAssertEqual(
            controller.channelSetupSnapshot.outstanding.count,
            3
        )

        let sizing = controller.windowSizingSnapshot
        XCTAssertGreaterThanOrEqual(
            sizing.defaultContentHeight,
            sizing.formHeight,
            """
            the default window must fit the worst case without scrolling. \
            Asserted against the requested height, not the realized one: a \
            screen smaller than the window clamps it, and CI runners have one.
            """
        )
        controller.close()
    }

    func testProviderPickerStatesWhatTheChannelWillNeed() throws {
        let picker = VoiceChannelProviderPickerView()
        let labels = descendantViews(in: picker)
            .compactMap { $0 as? NSTextField }
        XCTAssertTrue(
            labels.contains(where: {
                $0.stringValue == ChannelSetupPolicy.requirementSummary(
                    for: .openAIRealtime
                )
            }),
            "picker never states what an OpenAI channel needs"
        )

        let popup = try XCTUnwrap(
            descendantViews(in: picker)
                .compactMap { $0 as? NSPopUpButton }
                .first
        )
        let index = try XCTUnwrap(
            popup.itemArray.firstIndex(where: {
                ($0.representedObject as? String)
                    == VoiceProviderID.openClaw.rawValue
            })
        )
        popup.selectItem(at: index)
        sendAction(for: popup)

        XCTAssertTrue(
            descendantViews(in: picker)
                .compactMap { $0 as? NSTextField }
                .contains(where: {
                    $0.stringValue == ChannelSetupPolicy.requirementSummary(
                        for: .openClaw
                    )
                }),
            "picker did not follow the popup selection"
        )
    }

    func testSetupSitsBetweenTheChannelAndProviderSections() throws {
        let controller = SettingsWindowController(
            profiles: [VoiceProfile.defaultOpenAI()],
            credentialStore: InMemoryCredentialStore(),
            saveProfiles: { _ in }
        )
        _ = controller.windowSizingSnapshot

        let headers = descendantViews(in: controller.window?.contentView)
            .compactMap { $0 as? NSTextField }
        func header(_ title: String) throws -> NSTextField {
            try XCTUnwrap(headers.first(where: {
                $0.stringValue == title
                    && $0.font == NSFont.systemFont(
                        ofSize: 13,
                        weight: .bold
                    )
            }))
        }
        let channel = try header(VoiceChannelUIStrings.channelSectionTitle)
        let setup = try header("Setup")
        let provider = try header("Voice Provider")

        // The form stack is vertical and unflipped, so higher minY is higher
        // on screen.
        XCTAssertGreaterThan(channel.frame.minY, setup.frame.minY)
        XCTAssertGreaterThan(setup.frame.minY, provider.frame.minY)
    }

    /// The picker inherited a hard-coded 72pt height with no bottom pin, so a
    /// third wrapping line clipped silently. Nothing renders in a unit test,
    /// but the geometry is still checkable.
    func testProviderPickerGrowsToFitItsRequirementsLine() {
        let picker = VoiceChannelProviderPickerView()
        picker.layoutSubtreeIfNeeded()

        let content = descendantViews(in: picker).dropFirst()
        XCTAssertFalse(content.isEmpty)
        for view in content where view.superview === picker {
            XCTAssertGreaterThanOrEqual(
                view.frame.minY,
                -0.5,
                "\(view) hangs below the picker"
            )
            XCTAssertLessThanOrEqual(
                view.frame.maxY,
                picker.bounds.height + 0.5,
                "\(view) is clipped by the picker's frame"
            )
        }
        XCTAssertGreaterThan(picker.bounds.height, 72)
    }

    /// NSAlert lays its accessory view out once and ignores later frame
    /// changes, so a picker that resized itself on every popup change slid up
    /// over the alert's informative text. The reserved size has to fit every
    /// provider and never move.
    func testProviderPickerKeepsOneSizeForEveryProvider() throws {
        let picker = VoiceChannelProviderPickerView()
        picker.layoutSubtreeIfNeeded()
        let reserved = picker.frame.size
        let popup = try XCTUnwrap(
            descendantViews(in: picker)
                .compactMap { $0 as? NSPopUpButton }
                .first
        )

        for provider in VoiceProviderID.allCases where provider.isImplemented {
            let index = try XCTUnwrap(
                popup.itemArray.firstIndex(where: {
                    ($0.representedObject as? String) == provider.rawValue
                })
            )
            popup.selectItem(at: index)
            sendAction(for: popup)
            picker.layoutSubtreeIfNeeded()

            XCTAssertEqual(
                picker.frame.size,
                reserved,
                "\(provider.rawValue) resized the accessory the alert already laid out"
            )
            XCTAssertEqual(
                picker.fittingSize.height,
                reserved.height,
                accuracy: 0.5,
                "\(provider.rawValue) reports a fitting height the alert would size to instead"
            )
            for view in descendantViews(in: picker).dropFirst()
            where view.superview !== picker {
                // Alignment rect, not frame: a button's bezel draws a point
                // outside the rect AppKit lays it out by, so asserting on raw
                // frames demands a guarantee AppKit does not make and fails by
                // exactly 1pt wherever the bezel is drawn that way. The labels
                // — the views that would actually clip text — are unaffected.
                let alignmentFrame = view.alignmentRect(forFrame: view.frame)
                let inPicker = view.superview?
                    .convert(alignmentFrame, to: picker) ?? .zero
                XCTAssertGreaterThanOrEqual(
                    inPicker.minY,
                    -0.5,
                    "\(provider.rawValue) pushes \(view) below the accessory"
                )
                XCTAssertLessThanOrEqual(
                    inPicker.maxY,
                    reserved.height + 0.5,
                    "\(provider.rawValue) clips \(view) against the accessory"
                )
            }
        }
    }

    /// The picker only ever renders inside an NSAlert, and the alert lays its
    /// accessory out once. This drives the real alert, so a picker that resizes
    /// itself is caught where it actually breaks.
    func testAlertKeepsThePickerWhereItLaidItOut() throws {
        let picker = VoiceChannelProviderPickerView()
        let alert = NSAlert()
        alert.messageText = "Add Voice Channel"
        alert.informativeText = "Choose how this voice channel connects."
        alert.addButton(withTitle: "Add Channel")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = picker
        alert.layout()

        let popup = try XCTUnwrap(
            descendantViews(in: picker)
                .compactMap { $0 as? NSPopUpButton }
                .first
        )
        let container = try XCTUnwrap(picker.superview).frame
        let popupInWindow = popup.convert(popup.bounds, to: nil)
        let alertSize = alert.window.frame.size

        for provider in VoiceProviderID.allCases where provider.isImplemented {
            let index = try XCTUnwrap(
                popup.itemArray.firstIndex(where: {
                    ($0.representedObject as? String) == provider.rawValue
                })
            )
            popup.selectItem(at: index)
            sendAction(for: popup)
            alert.window.layoutIfNeeded()

            XCTAssertEqual(
                picker.superview?.frame,
                container,
                "\(provider.rawValue) needs a band the alert never reserved"
            )
            XCTAssertEqual(
                picker.frame.height,
                container.height,
                accuracy: 0.5,
                "\(provider.rawValue) overflows the band the alert reserved"
            )
            XCTAssertEqual(
                popup.convert(popup.bounds, to: nil),
                popupInWindow,
                "\(provider.rawValue) moved the popup after the alert laid out"
            )
            XCTAssertEqual(
                alert.window.frame.size,
                alertSize,
                "\(provider.rawValue) changed the alert's size"
            )
        }
    }

    /// NSClipView is unflipped, so a form shorter than the window used to be
    /// parked against the bottom: 64pt of blank above the first header at the
    /// old 900pt default, 144pt at 980pt.
    func testTheFormStartsAtTheTopOfTheWindow() throws {
        let profile = VoiceProfile.defaultOpenAI()
        let credentials = InMemoryCredentialStore()
        credentials.apiKeys[profile.id] = "sk-test"
        let controller = SettingsWindowController(
            profiles: [profile],
            credentialStore: credentials,
            saveProfiles: { _ in },
            microphoneAuthorizationProvider: { .authorized },
            requestMicrophoneAccess: { _ in },
            isAccessibilityTrusted: { true },
            requestAccessibilityAccess: {},
            openSystemSettingsURL: { _ in }
        )
        let delegate = ChannelSetupSettingsDelegate()
        delegate.registration = .carbonRegistered
        controller.delegate = delegate
        controller.showAndFocus()

        let scrollView = try XCTUnwrap(
            descendantViews(in: controller.window?.contentView)
                .compactMap { $0 as? NSScrollView }
                .first
        )
        scrollView.layoutSubtreeIfNeeded()
        let document = try XCTUnwrap(scrollView.documentView)
        // Make the clip taller than the form by hand: the assertion below is
        // about the alignment constraint, and on a screen too small to show the
        // whole form there would otherwise be no slack to detect it in.
        scrollView.setFrameSize(
            NSSize(
                width: scrollView.frame.width,
                height: document.fittingSize.height + 200
            )
        )
        scrollView.layoutSubtreeIfNeeded()
        XCTAssertLessThan(
            document.fittingSize.height,
            scrollView.contentView.bounds.height,
            "the clip view was just sized to guarantee this"
        )
        XCTAssertEqual(
            document.frame.maxY,
            scrollView.contentView.bounds.maxY,
            accuracy: 0.5,
            "the form floats away from the top of the window"
        )
        controller.close()
    }

    func testRecordButtonArmsTheRecorderAndGivesItTheKeyboard() throws {
        var profile = VoiceProfile.defaultOpenAI()
        profile.hotKey = nil
        let credentials = InMemoryCredentialStore()
        credentials.apiKeys[profile.id] = "sk-test"
        let controller = SettingsWindowController(
            profiles: [profile],
            credentialStore: credentials,
            saveProfiles: { _ in },
            microphoneAuthorizationProvider: { .authorized },
            requestMicrophoneAccess: { _ in },
            isAccessibilityTrusted: { true },
            requestAccessibilityAccess: {},
            openSystemSettingsURL: { _ in }
        )
        let delegate = ChannelSetupSettingsDelegate()
        delegate.registration = .noHotKey
        controller.delegate = delegate
        controller.showAndFocus()

        XCTAssertEqual(
            controller.channelSetupSnapshot.outstanding.map(\.id),
            [.activation]
        )
        sendAction(for: try activationButton(in: controller))

        let recorder = try XCTUnwrap(
            descendantViews(in: controller.window?.contentView)
                .compactMap { $0 as? HotKeyRecorderView }
                .first
        )
        XCTAssertTrue(
            recorder.isRecording,
            "Record… did not arm the recorder"
        )
        // Armed but unfocused would swallow every shortcut into whichever
        // field still had focus, while every global hotkey stays torn down.
        XCTAssertTrue(
            controller.window?.firstResponder === recorder,
            "the armed recorder never got the keyboard"
        )
        controller.close()
    }

    func testAddKeyFocusesTheCredentialField() throws {
        let profile = VoiceProfile.defaultOpenAI()
        let controller = SettingsWindowController(
            profiles: [profile],
            credentialStore: InMemoryCredentialStore(),
            saveProfiles: { _ in },
            microphoneAuthorizationProvider: { .authorized },
            requestMicrophoneAccess: { _ in },
            isAccessibilityTrusted: { true },
            requestAccessibilityAccess: {},
            openSystemSettingsURL: { _ in }
        )
        let delegate = ChannelSetupSettingsDelegate()
        delegate.registration = .carbonRegistered
        controller.delegate = delegate
        controller.showAndFocus()

        XCTAssertEqual(
            controller.channelSetupSnapshot.outstanding.map(\.id),
            [.activation]
        )
        sendAction(for: try activationButton(in: controller))

        let field = try XCTUnwrap(
            descendantViews(in: controller.window?.contentView)
                .compactMap { $0 as? NSSecureTextField }
                .first
        )
        XCTAssertTrue(
            focusedTextField(in: controller) === field,
            "Add Key did not focus the credential field"
        )
        controller.close()
    }

    func testSetEndpointFocusesTheEndpointField() throws {
        var profile = VoiceProfile.defaultOpenAI()
        profile.providerID = .custom
        profile.endpointURL = "   "
        let controller = SettingsWindowController(
            profiles: [profile],
            credentialStore: InMemoryCredentialStore(),
            saveProfiles: { _ in },
            microphoneAuthorizationProvider: { .authorized },
            requestMicrophoneAccess: { _ in },
            isAccessibilityTrusted: { true },
            requestAccessibilityAccess: {},
            openSystemSettingsURL: { _ in }
        )
        let delegate = ChannelSetupSettingsDelegate()
        delegate.registration = .carbonRegistered
        controller.delegate = delegate
        controller.showAndFocus()

        XCTAssertEqual(
            controller.channelSetupSnapshot.outstanding.map(\.id),
            [.activation]
        )
        sendAction(for: try activationButton(in: controller))

        let field = try XCTUnwrap(
            findTextField(
                in: controller.window?.contentView,
                placeholder: VoiceProviderID.custom.endpointPlaceholder
            )
        )
        XCTAssertTrue(
            focusedTextField(in: controller) === field,
            "Set Endpoint did not focus the endpoint field"
        )
        controller.close()
    }

    /// Recording tears every Carbon registration down and puts it back through
    /// the delegate. Rendering the section before that callback made the
    /// channel read `.eventMonitorFallback` and flashed a red Accessibility row
    /// on a shortcut that works fine.
    func testEndingARecordingNeverFlashesTheAccessibilityRow() throws {
        let profile = VoiceProfile.defaultOpenAI()
        let credentials = InMemoryCredentialStore()
        credentials.apiKeys[profile.id] = "sk-test"
        let controller = SettingsWindowController(
            profiles: [profile],
            credentialStore: credentials,
            saveProfiles: { _ in },
            microphoneAuthorizationProvider: { .authorized },
            requestMicrophoneAccess: { _ in },
            isAccessibilityTrusted: { false },
            requestAccessibilityAccess: {},
            openSystemSettingsURL: { _ in }
        )
        let delegate = ChannelSetupSettingsDelegate()
        delegate.registration = .carbonRegistered
        // Mirrors `setHotKeyRecording`: registrations are gone for as long as
        // the recorder is capturing, and back the moment it stops.
        delegate.onRecordingStateChanged = { [weak delegate] isRecording in
            delegate?.registration = isRecording
                ? .eventMonitorFallback
                : .carbonRegistered
        }
        controller.delegate = delegate
        controller.showAndFocus()

        func accessibilityRowIsVisible() -> Bool {
            descendantButtons(in: controller.window?.contentView)
                .contains(where: {
                    $0.identifier?.rawValue
                        == ChannelSetupRequirementID.accessibility.rawValue
                        && $0.isHidden == false
                })
        }

        XCTAssertFalse(accessibilityRowIsVisible())
        let recorder = try XCTUnwrap(
            descendantViews(in: controller.window?.contentView)
                .compactMap { $0 as? HotKeyRecorderView }
                .first
        )
        recorder.beginRecording()
        XCTAssertFalse(
            accessibilityRowIsVisible(),
            "a red Accessibility row appeared while the recorder was capturing"
        )
        recorder.cancelRecording()
        XCTAssertFalse(
            accessibilityRowIsVisible(),
            "the section rendered before the delegate re-registered the shortcut"
        )
        controller.close()
    }

    private func activationButton(
        in controller: SettingsWindowController
    ) throws -> NSButton {
        try XCTUnwrap(
            descendantButtons(in: controller.window?.contentView)
                .first(where: {
                    $0.identifier?.rawValue
                        == ChannelSetupRequirementID.activation.rawValue
                        && $0.isHidden == false
                }),
            "no visible activation button"
        )
    }

    /// A focused `NSTextField` hands first responder to the window's shared
    /// field editor, so identity has to be read back through its delegate.
    private func focusedTextField(
        in controller: SettingsWindowController
    ) -> NSTextField? {
        let responder = controller.window?.firstResponder
        if let field = responder as? NSTextField {
            return field
        }
        return (responder as? NSTextView)?.delegate as? NSTextField
    }

    private func assertEverySetupRowIsHidden(
        in controller: SettingsWindowController,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let buttons = descendantButtons(in: controller.window?.contentView)
        for requirement: ChannelSetupRequirementID in [
            .activation, .microphone, .accessibility
        ] {
            let button = buttons.first(where: {
                $0.identifier?.rawValue == requirement.rawValue
            })
            XCTAssertNotNil(button, "\(requirement) has no button", file: file, line: line)
            XCTAssertTrue(
                button?.isHidden == true,
                "\(requirement) button is still visible",
                file: file,
                line: line
            )
            XCTAssertTrue(
                button?.superview?.isHidden == true,
                "\(requirement) row is still visible",
                file: file,
                line: line
            )
        }
    }

    private func makeController(
        profiles: [VoiceProfile],
        defaults: UserDefaults,
        credentials: InMemoryCredentialStore =
            InMemoryCredentialStore()
    ) -> SettingsWindowController {
        SettingsWindowController(
            profiles: profiles,
            credentialStore: credentials,
            saveProfiles: {
                VoiceProfileStore.save($0, defaults: defaults)
            }
        )
    }

    private func makeDefaults() throws -> UserDefaults {
        makeTestDefaults()
    }

    private func findTextField(
        in view: NSView?,
        placeholder: String
    ) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField,
           field.placeholderString == placeholder {
            return field
        }
        for subview in view.subviews {
            if let match = findTextField(
                in: subview,
                placeholder: placeholder
            ) {
                return match
            }
        }
        return nil
    }

    private func descendantButtons(in view: NSView?) -> [NSButton] {
        guard let view else { return [] }
        var buttons = view.subviews.flatMap(descendantButtons(in:))
        if let button = view as? NSButton {
            buttons.insert(button, at: 0)
        }
        return buttons
    }

    private func descendantViews(in view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return [view] + view.subviews.flatMap(descendantViews(in:))
    }

    private func sendAction(for control: NSControl) {
        guard let action = control.action else {
            XCTFail("Expected control action")
            return
        }
        XCTAssertTrue(NSApplication.shared.sendAction(
            action,
            to: control.target,
            from: control
        ))
    }

    private func makeFunctionHotKey(
        keyCode: UInt32,
        number: Int
    ) -> HotKeyConfiguration {
        HotKeyConfiguration(
            keyCode: keyCode,
            carbonModifiers: 0,
            menuKeyEquivalent: "",
            menuModifierMask: [],
            displayName: "F\(number)",
            mainKeyDisplayName: "F\(number)"
        )
    }
}

private final class AutoApplySettingsDelegate:
    SettingsWindowControllerDelegate {
    var profileUpdates: [[VoiceProfile]] = []

    func settingsController(
        _ controller: SettingsWindowController,
        didUpdateProfiles profiles: [VoiceProfile]
    ) {
        profileUpdates.append(profiles)
    }

    func settingsController(
        _ controller: SettingsWindowController,
        didRecordHotKey hotKey: HotKeyConfiguration,
        for profile: VoiceProfile
    ) -> Bool {
        true
    }

    func settingsControllerDidUpdateCredentials(
        _ controller: SettingsWindowController
    ) {}

    func settingsController(
        _ controller: SettingsWindowController,
        isRecordingHotKey: Bool
    ) {}
}

/// Answers the two setup-related delegate questions. `delegate` is weak, so
/// every test holds one of these in a strong local for its whole duration.
private final class ChannelSetupSettingsDelegate:
    SettingsWindowControllerDelegate {
    var registration: ChannelHotKeyRegistration = .unknown
    var registrationsByProfile: [UUID: ChannelHotKeyRegistration] = [:]
    /// Lets a test model the app delegate, which tears every Carbon
    /// registration down while the recorder captures and restores it after.
    var onRecordingStateChanged: ((Bool) -> Void)?
    private(set) var setupChangeCount = 0

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

    func settingsController(
        _ controller: SettingsWindowController,
        isRecordingHotKey: Bool
    ) {
        onRecordingStateChanged?(isRecordingHotKey)
    }

    func settingsController(
        _ controller: SettingsWindowController,
        hotKeyRegistrationFor profileID: UUID
    ) -> ChannelHotKeyRegistration {
        registrationsByProfile[profileID] ?? registration
    }

    func settingsControllerDidChangeSetup(
        _ controller: SettingsWindowController
    ) {
        setupChangeCount += 1
    }
}

private final class SettingsCommitRecorder {
    var savedProfiles: [[VoiceProfile]] = []
    var events: [String] = []
}

private enum InMemoryCredentialError: Error {
    case rejected
}

private final class InMemoryCredentialStore: VoiceCredentialStoring {
    struct APIKeyWrite: Equatable {
        var provider: VoiceProviderID
        var profileID: UUID
    }

    var apiKeys: [UUID: String] = [:]
    var tokens: [UUID: String] = [:]
    var apiKeyWrites: [APIKeyWrite] = []
    var failingToken: String?
    weak var events: SettingsCommitRecorder?

    func hasAPIKey(for profile: VoiceProfile) -> Bool {
        apiKey(for: profile) != nil
    }

    func apiKey(for profile: VoiceProfile) -> String? {
        apiKeys[profile.id]
    }

    func setAPIKey(_ apiKey: String, for profile: VoiceProfile) throws {
        apiKeys[profile.id] = apiKey
        apiKeyWrites.append(APIKeyWrite(
            provider: profile.providerID,
            profileID: profile.id
        ))
    }

    func deleteAPIKey(for profile: VoiceProfile) throws {
        apiKeys[profile.id] = nil
    }

    func authorizationToken(forMCPServer id: UUID) -> String? {
        tokens[id]
    }

    func setAuthorizationToken(
        _ token: String,
        forMCPServer id: UUID
    ) throws {
        events?.events.append("token.set")
        if token == failingToken {
            throw InMemoryCredentialError.rejected
        }
        tokens[id] = token
    }

    func deleteAuthorizationToken(forMCPServer id: UUID) throws {
        events?.events.append("token.delete")
        tokens[id] = nil
    }
}

private final class EndpointRecordingRuntimeService:
    OpenClawRuntimeSettingsServing {
    let approvedScopes: Set<String> = ["operator.admin"]
    var loadEndpoints: [String] = []
    var applyEndpoints: [String] = []

    func load(
        endpointURL: String,
        completion: @escaping (
            Result<OpenClawRuntimeSettings, Error>
        ) -> Void
    ) {
        loadEndpoints.append(endpointURL)
        completion(.success(.staticFallback))
    }

    func apply(
        model: String,
        voice: String,
        endpointURL: String,
        completion: @escaping (
            Result<OpenClawRuntimeSettings, Error>
        ) -> Void
    ) {
        applyEndpoints.append(endpointURL)
        completion(.success(OpenClawRuntimeSettings(
            sessionKey: OpenClawTalkRequestBuilder.sessionKey,
            model: model,
            voice: voice,
            source: .gateway
        )))
    }
}

private final class SettingsOpenClawConnectionTester:
    OpenClawConnectionTesting {
    private var completion:
        ((OpenClawConnectionTestResult) -> Void)?
    private(set) var endpoints: [String] = []
    /// What the next completed test reports as the credential it used.
    var tokenSource: OpenClawGatewayTokenSource? = .enteredToken
    var discoveryWouldSupplyDifferentToken = false

    @discardableResult
    func testConnection(
        endpointURL: String,
        completion: @escaping (
            OpenClawConnectionOutcome
        ) -> Void
    ) -> OpenClawConnectionTestCancellation {
        testConnection(endpointURL: endpointURL) { result in
            completion(result.outcome)
        }
    }

    @discardableResult
    func testConnection(
        endpointURL: String,
        detailedCompletion: @escaping (
            OpenClawConnectionTestResult
        ) -> Void
    ) -> OpenClawConnectionTestCancellation {
        endpoints.append(endpointURL)
        completion = detailedCompletion
        return SettingsOpenClawTestCancellation()
    }

    func complete(_ outcome: OpenClawConnectionOutcome) {
        completion?(OpenClawConnectionTestResult(
            outcome: outcome,
            tokenSource: tokenSource,
            discoveryWouldSupplyDifferentToken:
                discoveryWouldSupplyDifferentToken
        ))
        completion = nil
    }
}

private final class SettingsOpenClawTestCancellation:
    OpenClawConnectionTestCancellation {
    func cancel() {}
}
