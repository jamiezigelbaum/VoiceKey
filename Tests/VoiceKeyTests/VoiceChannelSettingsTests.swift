@testable import VoiceKey
import XCTest

final class VoiceChannelTerminologyTests: XCTestCase {
    func testKeySettingsStringsUseVoiceChannelTerminology() {
        XCTAssertEqual(VoiceChannelUIStrings.windowTitle, "VoiceKey Voice Channels")
        XCTAssertEqual(VoiceChannelUIStrings.channelSectionTitle, "Voice Channel")
        XCTAssertEqual(VoiceChannelUIStrings.addChannel, "Add Channel")
        XCTAssertEqual(VoiceChannelUIStrings.duplicateChannel, "Duplicate Channel")
        XCTAssertEqual(VoiceChannelUIStrings.deleteChannel, "Delete Channel")
        XCTAssertEqual(
            VoiceChannelUIStrings.channelNamePlaceholder,
            "Voice channel name"
        )
        XCTAssertEqual(
            VoiceChannelUIStrings.speakerModeLabel,
            "Channel speaker mode"
        )

        let visibleStrings = [
            VoiceChannelUIStrings.windowTitle,
            VoiceChannelUIStrings.channelSectionTitle,
            VoiceChannelUIStrings.addChannel,
            VoiceChannelUIStrings.duplicateChannel,
            VoiceChannelUIStrings.deleteChannel,
            VoiceChannelUIStrings.channelNamePlaceholder,
            VoiceChannelUIStrings.speakerModeLabel
        ]
        XCTAssertFalse(visibleStrings.contains {
            $0.localizedCaseInsensitiveContains("profile")
        })
    }
}

final class VoiceChannelOperationsTests: XCTestCase {
    func testDuplicateCopiesChannelSettingsWithFreshIDAndNoHotKey() {
        let source = VoiceProfile(
            id: UUID(uuidString: "1255CB7F-47A5-4C92-A6C3-E9429DA5FA48")!,
            name: "Research",
            providerID: .openAIRealtime,
            hotKey: .defaultVoiceToggle,
            model: "provider/custom-model",
            voice: "coral",
            instructions: "Keep it short.",
            endpointURL: "wss://example.com/realtime",
            mcpServers: [
                MCPServerConfiguration(
                    id: UUID(uuidString: "6FA2714D-7DB6-4601-93DB-54572B64FFAA")!,
                    label: "search",
                    urlString: "https://mcp.example.com",
                    allowedTools: ["search"]
                )
            ],
            webSearchEnabled: true,
            speakerModePreference: .alwaysOn
        )

        let copy = VoiceChannelOperations.duplicate(
            source,
            existingNames: [source.name]
        )

        XCTAssertNotEqual(copy.id, source.id)
        XCTAssertEqual(copy.name, "Research Copy")
        XCTAssertNil(copy.hotKey)
        XCTAssertEqual(copy.providerID, source.providerID)
        XCTAssertEqual(copy.model, source.model)
        XCTAssertEqual(copy.voice, source.voice)
        XCTAssertEqual(copy.instructions, source.instructions)
        XCTAssertEqual(copy.endpointURL, source.endpointURL)
        XCTAssertEqual(copy.webSearchEnabled, source.webSearchEnabled)
        XCTAssertEqual(
            copy.speakerModePreference,
            source.speakerModePreference
        )
        XCTAssertEqual(copy.mcpServers.count, 1)
        XCTAssertNotEqual(copy.mcpServers[0].id, source.mcpServers[0].id)
        XCTAssertEqual(copy.mcpServers[0].label, source.mcpServers[0].label)
        XCTAssertEqual(
            copy.mcpServers[0].urlString,
            source.mcpServers[0].urlString
        )
        XCTAssertEqual(
            copy.mcpServers[0].allowedTools,
            source.mcpServers[0].allowedTools
        )
    }

    func testNewChannelUsesSelectedProviderAndStartsUnassigned() {
        let channel = VoiceChannelOperations.makeChannel(
            provider: .chatGPTWeb,
            existingNames: []
        )

        XCTAssertEqual(channel.name, "ChatGPT (web)")
        XCTAssertEqual(channel.providerID, .chatGPTWeb)
        XCTAssertNil(channel.hotKey)
        XCTAssertEqual(channel.model, VoiceProviderID.chatGPTWeb.defaultModel)
        XCTAssertEqual(channel.voice, VoiceProviderID.chatGPTWeb.defaultVoice)
    }
}

final class VoiceProviderDescriptionTests: XCTestCase {
    func testOpenAIAndChatGPTDescriptionsExplainTheirDifferentProducts() {
        XCTAssertEqual(
            VoiceProviderID.openAIRealtime.settingsDescription,
            "OpenAI Realtime API — your OpenAI API key; pick model & voice; built-in web search"
        )
        XCTAssertEqual(VoiceProviderID.chatGPTWeb.displayName, "ChatGPT (web)")
        XCTAssertEqual(
            VoiceProviderID.chatGPTWeb.settingsDescription,
            "ChatGPT (web) — your ChatGPT subscription in a window; GPT-Live voice when available; OpenAI controls model & voice"
        )
    }

    func testEveryProviderHasAOneLineDescription() {
        for provider in VoiceProviderID.allCases {
            XCTAssertFalse(provider.settingsDescription.isEmpty)
            XCTAssertFalse(provider.settingsDescription.contains("\n"))
        }
    }
}

final class OpenClawRuntimePanelTests: XCTestCase {
    func testPanelIsReadOnlyWithoutAdminScope() {
        let service = StubOpenClawRuntimeSettingsService(
            approvedScopes: ["operator.talk", "operator.write"]
        )
        let controller = SettingsWindowController(
            profiles: [makeOpenClawChannel()],
            openClawRuntimeService: service
        )

        XCTAssertTrue(controller.openClawRuntimePanelSnapshot.isVisible)
        XCTAssertFalse(controller.openClawRuntimePanelState.isEditable)
        XCTAssertFalse(
            controller.openClawRuntimePanelSnapshot.modelIsEditable
        )
        XCTAssertFalse(
            controller.openClawRuntimePanelSnapshot.voicePickerIsVisible
        )
        XCTAssertFalse(
            controller.openClawRuntimePanelSnapshot.applyButtonIsVisible
        )
        XCTAssertEqual(
            controller.openClawRuntimePanelState.settings.sessionKey,
            "agent:voice:voicekey"
        )
        XCTAssertEqual(
            controller.openClawRuntimePanelState.settings.model,
            "gpt-5.6-luna"
        )
        XCTAssertEqual(
            controller.openClawRuntimePanelState.settings.voice,
            "cedar"
        )
    }

    func testPanelRendersPickersOnlyForAdminScopedConnection() {
        let service = StubOpenClawRuntimeSettingsService(
            approvedScopes: [
                "operator.talk",
                "operator.write",
                "operator.admin"
            ]
        )
        let controller = SettingsWindowController(
            profiles: [makeOpenClawChannel()],
            openClawRuntimeService: service
        )

        XCTAssertTrue(controller.openClawRuntimePanelState.isEditable)
        XCTAssertTrue(
            controller.openClawRuntimePanelSnapshot.modelIsEditable
        )
        XCTAssertTrue(
            controller.openClawRuntimePanelSnapshot.voicePickerIsVisible
        )
        XCTAssertTrue(
            controller.openClawRuntimePanelSnapshot.applyButtonIsVisible
        )
        XCTAssertEqual(
            OpenClawRuntimeSettings.voiceOptions,
            [
                "alloy", "ash", "ballad", "coral", "echo",
                "sage", "shimmer", "verse", "marin", "cedar"
            ]
        )
    }

    func testPanelPolicyRequiresExactAdminScope() {
        let writeOnly = OpenClawRuntimePanelState(
            settings: .staticFallback,
            approvedScopes: ["operator.write"],
            loadError: nil
        )
        let similarlyNamed = OpenClawRuntimePanelState(
            settings: .staticFallback,
            approvedScopes: ["operator.admin.read"],
            loadError: nil
        )
        let admin = OpenClawRuntimePanelState(
            settings: .staticFallback,
            approvedScopes: ["operator.admin"],
            loadError: nil
        )

        XCTAssertFalse(writeOnly.isEditable)
        XCTAssertFalse(similarlyNamed.isEditable)
        XCTAssertTrue(admin.isEditable)
    }

    private func makeOpenClawChannel() -> VoiceProfile {
        VoiceProfile(
            name: "Castor",
            providerID: .openClaw,
            model: "",
            voice: ""
        )
    }
}

final class OpenClawRuntimeRequestBuilderTests: XCTestCase {
    func testRuntimeServiceFailsClosedBeforeConnectingWithoutAdminScope() {
        var tokenProviderCalls = 0
        let service = OpenClawRuntimeSettingsService(
            tokenProvider: {
                tokenProviderCalls += 1
                return "gateway-token"
            },
            credentialsProvider: {
                OpenClawDeviceCredentials(
                    deviceID: "device",
                    publicKey: Data(),
                    privateKeySeed: Data(),
                    operatorToken: "operator-token",
                    operatorScopes: ["operator.talk", "operator.write"]
                )
            }
        )
        var errorMessage: String?

        service.apply(
            model: "openai/gpt-5.6-luna",
            voice: "cedar",
            endpointURL: ""
        ) { result in
            if case let .failure(error) = result {
                errorMessage = error.localizedDescription
            }
        }

        XCTAssertEqual(tokenProviderCalls, 0)
        XCTAssertEqual(
            errorMessage,
            "The paired device is not approved for operator.admin."
        )
    }

    func testModelMutationTargetsPinnedConsultSession() throws {
        let frame = OpenClawRuntimeRequestBuilder.sessionsPatchFrame(
            model: "openai/gpt-5.6-luna"
        )
        let params = try XCTUnwrap(frame["params"] as? [String: Any])

        XCTAssertEqual(frame["method"] as? String, "sessions.patch")
        XCTAssertEqual(params["key"] as? String, "agent:voice:voicekey")
        XCTAssertEqual(params["model"] as? String, "openai/gpt-5.6-luna")
        XCTAssertNil(params["thinkingLevel"])
        XCTAssertNil(params["fastMode"])
    }

    func testVoiceMutationTargetsGatewayTalkConfigWithBaseHash() throws {
        let frame = try XCTUnwrap(
            OpenClawRuntimeRequestBuilder.configPatchFrame(
                voice: "cedar",
                baseHash: "current-hash"
            )
        )
        let params = try XCTUnwrap(frame["params"] as? [String: Any])
        let raw = try XCTUnwrap(params["raw"] as? String)
        let data = try XCTUnwrap(raw.data(using: .utf8))
        let patch = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let talk = try XCTUnwrap(patch["talk"] as? [String: Any])
        let realtime = try XCTUnwrap(talk["realtime"] as? [String: Any])
        let providers = try XCTUnwrap(
            realtime["providers"] as? [String: Any]
        )
        let openAI = try XCTUnwrap(
            providers["openai"] as? [String: Any]
        )

        XCTAssertEqual(frame["method"] as? String, "config.patch")
        XCTAssertEqual(params["baseHash"] as? String, "current-hash")
        XCTAssertEqual(openAI["voice"] as? String, "cedar")
    }
}

private final class StubOpenClawRuntimeSettingsService:
    OpenClawRuntimeSettingsServing {
    let approvedScopes: Set<String>

    init(approvedScopes: Set<String>) {
        self.approvedScopes = approvedScopes
    }

    func load(
        endpointURL: String,
        completion: @escaping (Result<OpenClawRuntimeSettings, Error>) -> Void
    ) {
        completion(.success(.staticFallback))
    }

    func apply(
        model: String,
        voice: String,
        endpointURL: String,
        completion: @escaping (Result<OpenClawRuntimeSettings, Error>) -> Void
    ) {
        completion(.success(OpenClawRuntimeSettings(
            sessionKey: OpenClawTalkRequestBuilder.sessionKey,
            model: model,
            voice: voice,
            source: .gateway
        )))
    }
}
