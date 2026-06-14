@testable import VoiceKey
import XCTest

final class VoiceKeyDiagnosticsSnapshotTests: XCTestCase {
    func testOpenAIRealtimeSnapshotReportsReadinessWithoutSecret() {
        let configuration = VoiceSessionConfiguration(
            providerID: .openAIRealtime,
            model: "gpt-realtime-2",
            voice: "marin",
            instructions: "Never include this prompt in diagnostics."
        )
        let snapshot = VoiceKeyDiagnosticsSnapshot(
            provider: .openAIRealtime,
            configuration: configuration,
            readiness: .ready,
            hotKey: .defaultVoiceToggle,
            currentStatus: .listening,
            hasAPIKey: true,
            supportsProviderInterface: false,
            hasSessionLog: true
        )

        XCTAssertEqual(
            snapshot.displayText,
            """
            VoiceKey Diagnostics
            Provider: OpenAI Realtime API
            Provider ID: openai-realtime
            Provider implemented: yes
            Readiness: Ready to use.
            API key: stored
            Model: gpt-realtime-2
            Voice: marin
            Hotkey: F16
            Status: Listening
            Provider window: no
            Session log has entries: yes
            """
        )
        XCTAssertFalse(snapshot.displayText.contains("sk-"))
        XCTAssertFalse(snapshot.displayText.contains(configuration.instructions))
    }

    func testMissingKeySnapshotReportsMissingKey() {
        let snapshot = VoiceKeyDiagnosticsSnapshot(
            provider: .openAIRealtime,
            configuration: VoiceProviderID.openAIRealtime.defaultConfiguration,
            readiness: .needsAPIKey("OpenAI API key required."),
            hotKey: .defaultVoiceToggle,
            currentStatus: .needsAttention("OpenAI API key required."),
            hasAPIKey: false,
            supportsProviderInterface: false,
            hasSessionLog: false
        )

        XCTAssertTrue(snapshot.displayText.contains("Readiness: Needs key - OpenAI API key required."))
        XCTAssertTrue(snapshot.displayText.contains("API key: missing"))
        XCTAssertTrue(snapshot.displayText.contains("Status: Needs attention - OpenAI API key required."))
    }

    func testProviderSignInSnapshotReportsNoAPIKeyRequired() {
        let snapshot = VoiceKeyDiagnosticsSnapshot(
            provider: .chatGPTWeb,
            configuration: VoiceProviderID.chatGPTWeb.defaultConfiguration,
            readiness: .providerSignIn("Uses provider sign-in."),
            hotKey: .defaultVoiceToggle,
            currentStatus: .ready,
            hasAPIKey: false,
            supportsProviderInterface: true,
            hasSessionLog: false
        )

        XCTAssertTrue(snapshot.displayText.contains("Provider: ChatGPT Web (OAuth)"))
        XCTAssertTrue(snapshot.displayText.contains("Readiness: Sign-in - Uses provider sign-in."))
        XCTAssertTrue(snapshot.displayText.contains("API key: not required"))
        XCTAssertTrue(snapshot.displayText.contains("Provider window: yes"))
    }
}
