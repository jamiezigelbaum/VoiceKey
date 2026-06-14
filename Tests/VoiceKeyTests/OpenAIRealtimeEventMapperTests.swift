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
            [.providerEvent(.status(.listening))]
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
            [.providerEvent(.status(.thinking))]
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

    func testResponseDoneMapsBackToListening() {
        XCTAssertEqual(
            OpenAIRealtimeEventMapper.actions(from: #"{"type":"response.done"}"#),
            [.providerEvent(.status(.listening))]
        )
    }

    func testErrorMapsToNeedsAttention() {
        XCTAssertEqual(
            OpenAIRealtimeEventMapper.actions(from: #"{"type":"error","error":{"message":"Bad key"}}"#),
            [.providerEvent(.status(.needsAttention("Bad key")))]
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
