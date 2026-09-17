@testable import VoiceKey
import Foundation
import XCTest

final class OpenAIRealtimeSpeakerModeTests: XCTestCase {
    func testAutoClassificationTreatsBluetoothAndBuiltInHeadphonesAsHeadphones() {
        let headphoneRoutes = [
            RealtimeAudioOutputRoute(
                transport: .bluetooth,
                dataSource: .other
            ),
            RealtimeAudioOutputRoute(
                transport: .bluetoothLE,
                dataSource: .other
            ),
            RealtimeAudioOutputRoute(
                transport: .builtIn,
                dataSource: .headphones
            )
        ]

        for route in headphoneRoutes {
            XCTAssertFalse(route.usesOpenSpeakersByDefault)
        }
    }

    func testAutoClassificationTreatsAllOtherRoutesAsSpeakers() {
        let speakerRoutes = [
            RealtimeAudioOutputRoute(
                transport: .builtIn,
                dataSource: .other
            ),
            RealtimeAudioOutputRoute(
                transport: .usb,
                dataSource: .other
            ),
            RealtimeAudioOutputRoute(
                transport: .displayPort,
                dataSource: .other
            ),
            RealtimeAudioOutputRoute(
                transport: .hdmi,
                dataSource: .other
            ),
            RealtimeAudioOutputRoute(
                transport: .airPlay,
                dataSource: .other
            ),
            RealtimeAudioOutputRoute(
                transport: .virtual,
                dataSource: .other
            ),
            // A non-built-in device cannot claim the built-in 3.5mm
            // exception merely by reporting a headphone-like source.
            RealtimeAudioOutputRoute(
                transport: .other,
                dataSource: .headphones
            )
        ]

        for route in speakerRoutes {
            XCTAssertTrue(route.usesOpenSpeakersByDefault)
        }
    }

    func testPreferenceOverrideMatrix() {
        let headphones = RealtimeAudioOutputRoute.headphones
        let speakers = RealtimeAudioOutputRoute.unknown

        XCTAssertFalse(mode(route: headphones, preference: .automatic))
        XCTAssertTrue(mode(route: speakers, preference: .automatic))
        XCTAssertTrue(mode(route: headphones, preference: .alwaysOn))
        XCTAssertTrue(mode(route: speakers, preference: .alwaysOn))
        XCTAssertFalse(mode(route: headphones, preference: .off))
        XCTAssertFalse(mode(route: speakers, preference: .off))
    }

    func testInactiveAECForcesSpeakerModePastEveryOverride() {
        for preference in OpenAISpeakerModePreference.allCases {
            XCTAssertTrue(OpenAIRealtimeSpeakerModePolicy.isSpeakerMode(
                route: .headphones,
                preference: preference,
                isEchoCancellationActive: false
            ))
        }
    }

    func testGateClosesDuringPlaybackAndForExactHangover() {
        var gate = OpenAIRealtimeSpeakerGate()
        let start = Date(timeIntervalSince1970: 100)
        gate.setSpeakerMode(true)
        gate.updatePlayback(isActive: true, at: start)

        XCTAssertTrue(gate.isGateClosed(at: start))

        gate.updatePlayback(isActive: false, at: start)
        XCTAssertTrue(gate.isGateClosed(at: start.addingTimeInterval(1)))
        XCTAssertFalse(gate.isGateClosed(at: start.addingTimeInterval(1.001)))
    }

    func testGateStaysOpenInHeadphoneMode() {
        var gate = OpenAIRealtimeSpeakerGate()
        let now = Date(timeIntervalSince1970: 100)
        gate.setSpeakerMode(false)
        gate.updatePlayback(isActive: true, at: now)

        XCTAssertFalse(gate.isGateClosed(at: now))
    }

    func testBargeInRequiresConsecutiveThresholdBuffersAndFiresOnce() {
        var gate = OpenAIRealtimeSpeakerGate()
        let now = Date(timeIntervalSince1970: 100)
        gate.setSpeakerMode(true)
        gate.updatePlayback(isActive: true, at: now)

        XCTAssertFalse(gate.observe(activity(peak: 0.08), at: now))
        XCTAssertFalse(gate.observe(activity(peak: 0.079), at: now))
        XCTAssertFalse(gate.observe(activity(peak: 0.2), at: now))
        XCTAssertFalse(gate.observe(activity(peak: 0.2), at: now))
        XCTAssertTrue(gate.observe(activity(peak: 0.2), at: now))
        XCTAssertFalse(gate.observe(activity(peak: 0.2), at: now))
        XCTAssertFalse(gate.isGateClosed(at: now))
    }

    func testBargeInLatchResetsForNewAssistantTurn() {
        var gate = OpenAIRealtimeSpeakerGate()
        let now = Date(timeIntervalSince1970: 100)
        gate.setSpeakerMode(true)
        gate.updatePlayback(isActive: true, at: now)
        for _ in 0..<OpenAIRealtimeSpeakerModeTuning.consecutiveBufferCount {
            _ = gate.observe(activity(peak: 0.2), at: now)
        }
        XCTAssertTrue(gate.hasInterruptedCurrentTurn)

        gate.beginAssistantTurn()

        XCTAssertFalse(gate.hasInterruptedCurrentTurn)
        XCTAssertTrue(gate.isGateClosed(at: now))
    }

    private func mode(
        route: RealtimeAudioOutputRoute,
        preference: OpenAISpeakerModePreference
    ) -> Bool {
        OpenAIRealtimeSpeakerModePolicy.isSpeakerMode(
            route: route,
            preference: preference,
            isEchoCancellationActive: true
        )
    }

    private func activity(peak: Float) -> RealtimeAudioInputActivity {
        RealtimeAudioInputActivity(rms: peak / 2, peak: peak)
    }
}
