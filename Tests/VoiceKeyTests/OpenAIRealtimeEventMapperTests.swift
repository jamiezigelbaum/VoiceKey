@testable import VoiceKey
import Foundation
import XCTest

final class OpenAIRealtimeEventMapperTests: XCTestCase {
    func testSessionCreatedMapsToDiagnosticOnly() {
        XCTAssertEqual(
            OpenAIRealtimeEventMapper.actions(from: #"{"type":"session.created"}"#),
            [.providerEvent(.diagnostic("session.created"))]
        )
    }

    func testSessionUpdatedMapsToDiagnosticAndSessionUpdatedAction() {
        XCTAssertEqual(
            OpenAIRealtimeEventMapper.actions(from: #"{"type":"session.updated"}"#),
            [
                .providerEvent(.diagnostic("session.updated")),
                .sessionUpdated
            ]
        )
    }

    func testSpeechStartedMapsToListening() {
        XCTAssertEqual(
            OpenAIRealtimeEventMapper.actions(from: #"{"type":"input_audio_buffer.speech_started"}"#),
            [
                .stopPlayback,
                .providerEvent(.status(.listening))
            ]
        )
    }

    func testSpeechStoppedMapsToThinking() {
        XCTAssertEqual(
            OpenAIRealtimeEventMapper.actions(from: #"{"type":"input_audio_buffer.speech_stopped"}"#),
            [.providerEvent(.status(.thinking))]
        )
    }

    func testResponseCreatedMapsToThinking() {
        XCTAssertEqual(
            OpenAIRealtimeEventMapper.actions(from: #"{"type":"response.created"}"#),
            [
                .providerEvent(.status(.thinking)),
                .responseStarted
            ]
        )
    }

    func testAssistantMessageItemMapsItsIDWithoutAddingMapperState() {
        XCTAssertEqual(
            OpenAIRealtimeEventMapper.actions(
                from: #"{"type":"response.output_item.added","item":{"type":"message","id":"item-42"}}"#
            ),
            [
                .assistantMessageStarted(itemID: "item-42"),
                .providerEvent(.diagnostic("response.output_item.added"))
            ]
        )
    }

    func testNonMessageOutputItemDoesNotStartAssistantAudioTurn() {
        XCTAssertEqual(
            OpenAIRealtimeEventMapper.actions(
                from: #"{"type":"response.output_item.added","item":{"type":"mcp_call","id":"call-1"}}"#
            ),
            [.providerEvent(.diagnostic("response.output_item.added"))]
        )
    }

    func testAudioDeltaMapsToAudioPlaybackAndSpeaking() {
        let audio = Data([0, 1, 2, 3])
        let event = #"{"type":"response.output_audio.delta","delta":"\#(audio.base64EncodedString())"}"#

        XCTAssertEqual(
            OpenAIRealtimeEventMapper.actions(from: event),
            [
                .audio(audio),
                .providerEvent(.status(.speaking))
            ]
        )
    }

    func testLegacyAudioDeltaNameIsAccepted() {
        let audio = Data([4, 5, 6, 7])
        let event = #"{"type":"response.audio.delta","delta":"\#(audio.base64EncodedString())"}"#

        XCTAssertEqual(
            OpenAIRealtimeEventMapper.actions(from: event),
            [
                .audio(audio),
                .providerEvent(.status(.speaking))
            ]
        )
    }

    func testTranscriptDeltaMapsToTranscript() {
        XCTAssertEqual(
            OpenAIRealtimeEventMapper.actions(from: #"{"type":"response.output_audio_transcript.delta","delta":"hello"}"#),
            [.providerEvent(.transcript("hello"))]
        )
    }

    /// `response.done` means the server finished sending, not that the speaker
    /// went quiet — the buffer usually has seconds left. Mapping it straight to
    /// listening stopped the menu-bar animation while she was still audibly
    /// talking, so the mapper now reports only that the audio is complete and
    /// the provider decides when listening resumes.
    func testResponseDoneReportsAudioCompleteRatherThanListening() throws {
        let actions = OpenAIRealtimeEventMapper.actions(
            from: #"{"type":"response.done"}"#
        )

        XCTAssertEqual(actions, [.assistantAudioComplete, .responseEnded])
        XCTAssertFalse(
            actions.contains(.providerEvent(.status(.listening))),
            "reporting listening here is what desynced the speaking animation"
        )
    }

    func testAudioDoneReportsAudioCompleteRatherThanListening() {
        for type in ["response.output_audio.done", "response.audio.done"] {
            XCTAssertEqual(
                OpenAIRealtimeEventMapper.actions(
                    from: #"{"type":"\#(type)"}"#
                ),
                [.assistantAudioComplete],
                "\(type) must not claim the assistant stopped speaking"
            )
        }
    }

    func testFunctionCallArgumentsMapCallIDAndOpaqueArguments() {
        XCTAssertEqual(
            OpenAIRealtimeEventMapper.actions(
                from:
                    #"{"type":"response.function_call_arguments.done","call_id":"call-42","arguments":"{\"query\":\"today's news\"}"}"#
            ),
            [
                .providerEvent(.diagnostic(
                    "response.function_call_arguments.done"
                )),
                .webSearchFunctionCall(
                    callID: "call-42",
                    arguments: #"{"query":"today's news"}"#
                )
            ]
        )
    }

    func testErrorMapsToNeedsAttention() {
        XCTAssertEqual(
            OpenAIRealtimeEventMapper.actions(from: #"{"type":"error","error":{"message":"Bad key"}}"#),
            [.providerEvent(.status(.needsAttention("Bad key")))]
        )
    }

    func testMCPListToolsCompletedMapsToServerAndToolDiagnostic() {
        let event = #"{"type":"mcp_list_tools.completed","server_label":"calendar","tools":[{"name":"search_events"},{"name":"create_event"}],"authorization":"must-not-log"}"#

        XCTAssertEqual(
            OpenAIRealtimeEventMapper.actions(from: event),
            [
                .providerEvent(.diagnostic(
                    "MCP mcp_list_tools.completed — server: calendar; tool count: 2; tool: search_events."
                ))
            ]
        )
    }

    func testMCPCallInProgressMapsToDiagnosticAndThinking() {
        let event = #"{"type":"response.mcp_call.in_progress","item":{"server_label":"calendar","name":"create_event","authorization":"must-not-log"}}"#

        XCTAssertEqual(
            OpenAIRealtimeEventMapper.actions(from: event),
            [
                .providerEvent(.diagnostic(
                    "MCP response.mcp_call.in_progress — server: calendar; tool: create_event."
                )),
                .providerEvent(.status(.thinking))
            ]
        )
    }

    func testMCPCallCompletedMapsToDiagnosticAndTerminalAction() {
        let event = #"{"type":"response.mcp_call.completed","server_label":"calendar","tool_name":"create_event"}"#

        XCTAssertEqual(
            OpenAIRealtimeEventMapper.actions(from: event),
            [
                .providerEvent(.diagnostic(
                    "MCP response.mcp_call.completed — server: calendar; tool: create_event."
                )),
                .mcpCallTerminated
            ]
        )
    }

    func testMCPCallFailedMapsToDiagnosticAndTerminalAction() {
        let event = #"{"type":"response.mcp_call.failed","server_label":"calendar","tool_name":"create_event"}"#

        XCTAssertEqual(
            OpenAIRealtimeEventMapper.actions(from: event),
            [
                .providerEvent(.diagnostic(
                    "MCP response.mcp_call.failed — server: calendar; tool: create_event."
                )),
                .mcpCallTerminated
            ]
        )
    }

    func testUnknownEventMapsToDiagnostic() {
        XCTAssertEqual(
            OpenAIRealtimeEventMapper.actions(from: #"{"type":"rate_limits.updated"}"#),
            [.providerEvent(.diagnostic("rate_limits.updated"))]
        )
    }

    func testMalformedEventIsIgnored() {
        XCTAssertEqual(OpenAIRealtimeEventMapper.actions(from: "not json"), [])
    }
}
