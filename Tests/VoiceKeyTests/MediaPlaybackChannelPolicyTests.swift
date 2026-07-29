@testable import VoiceKey
import XCTest

/// The delegate seam: given what the app knows — which channel it asked for,
/// which one is active, and the last status a provider reported — which channel
/// should be holding other media paused?
final class MediaPlaybackChannelPolicyTests: XCTestCase {
    private var policy = MediaPlaybackChannelPolicy()

    override func setUp() {
        super.setUp()
        policy = MediaPlaybackChannelPolicy()
    }

    // MARK: - The plain cases

    func testNothingIsActiveBeforeAnyChannelIsAskedFor() {
        XCTAssertNil(
            policy.activeChannel(activeProfileID: nil, status: .ready)
        )
    }

    func testAnIdleAppWithAChannelSelectedHoldsNothing() {
        // The app open, a profile selected, no session. Audio plays normally.
        XCTAssertNil(
            policy.activeChannel(activeProfileID: UUID(), status: .ready)
        )
    }

    func testALiveChannelHoldsTheMusic() {
        let channel = UUID()
        for status in [
            ProviderStatus.starting,
            .listening,
            .thinking,
            .speaking,
            .clickSent,
            .voiceActive,
            .stopping
        ] {
            var policy = MediaPlaybackChannelPolicy()
            XCTAssertEqual(
                policy.activeChannel(
                    activeProfileID: channel,
                    status: status
                ),
                channel,
                "\(status) is a live session"
            )
        }
    }

    func testStoppingStillHoldsTheMusic() {
        let channel = UUID()

        XCTAssertEqual(
            policy.activeChannel(
                activeProfileID: channel,
                status: .stopping
            ),
            channel,
            "the audio graph is still up; putting music back under it is early"
        )
    }

    func testAFinishedSessionReleasesTheMusic() {
        let channel = UUID()
        policy.channelRequested(channel)
        _ = policy.activeChannel(activeProfileID: channel, status: .starting)
        _ = policy.activeChannel(activeProfileID: channel, status: .stopping)

        XCTAssertNil(
            policy.activeChannel(activeProfileID: channel, status: .ready)
        )
    }

    // MARK: - The switch window

    /// The case this type exists for. Switching channels stops the outgoing
    /// session, which reports `.stopping` → `.ready` exactly as a real stop
    /// does; the incoming `.starting` lands a main-thread turn or two later.
    func testSwitchingChannelsNeverReleasesTheMusicInBetween() {
        let channelA = UUID()
        let channelB = UUID()

        // A is live.
        policy.channelRequested(channelA)
        XCTAssertEqual(
            policy.activeChannel(activeProfileID: channelA, status: .listening),
            channelA
        )

        // The owner hits B's hotkey. activate() stops A and commits to B.
        policy.channelRequested(channelB)

        // A's stop reports in, with activeProfileID already B.
        XCTAssertEqual(
            policy.activeChannel(activeProfileID: channelB, status: .stopping),
            channelB
        )
        XCTAssertEqual(
            policy.activeChannel(activeProfileID: channelB, status: .ready),
            channelB,
            "this .ready is the outgoing session's, and releasing here is the "
            + "blip requirement 4 forbids"
        )

        // B reports in.
        XCTAssertEqual(
            policy.activeChannel(activeProfileID: channelB, status: .starting),
            channelB
        )
        // And from here the live status carries it, request cleared.
        XCTAssertNil(policy.requestedChannelID)
        XCTAssertNil(
            policy.activeChannel(activeProfileID: channelB, status: .ready)
        )
    }

    func testARequestedChannelThatFailsToStartReleasesTheMusic() {
        let channel = UUID()
        policy.channelRequested(channel)

        XCTAssertNil(
            policy.activeChannel(
                activeProfileID: channel,
                status: .needsAttention("Add an OpenAI API key in Settings.")
            ),
            "it is never going to hold the audio session"
        )
        XCTAssertNil(policy.requestedChannelID)
    }

    /// The stuck-paused failure mode, which is worse than not pausing at all:
    /// a request that nobody can honour must not hold the music forever.
    func testAResetRuntimeReleasesAPendingRequest() {
        let channel = UUID()
        policy.channelRequested(channel)
        XCTAssertEqual(
            policy.activeChannel(activeProfileID: channel, status: .ready),
            channel
        )

        policy.runtimeWasReset()

        XCTAssertNil(
            policy.activeChannel(activeProfileID: nil, status: .ready)
        )
        XCTAssertNil(policy.requestedChannelID)
    }

    /// Stopping a channel goes through `toggleVoice`, not `activate`, so no
    /// request is made and the `.ready` at the end is the real end.
    func testStoppingAChannelIsNotHeldOpenByAStaleRequest() {
        let channel = UUID()
        policy.channelRequested(channel)
        _ = policy.activeChannel(activeProfileID: channel, status: .listening)
        XCTAssertNil(
            policy.requestedChannelID,
            "a live report clears the request, so the next stop is honest"
        )

        XCTAssertEqual(
            policy.activeChannel(activeProfileID: channel, status: .stopping),
            channel
        )
        XCTAssertNil(
            policy.activeChannel(activeProfileID: channel, status: .ready)
        )
    }

    func testALiveStatusForADifferentChannelDoesNotClearTheRequest() {
        let channelA = UUID()
        let channelB = UUID()
        policy.channelRequested(channelB)

        XCTAssertEqual(
            policy.activeChannel(activeProfileID: channelA, status: .listening),
            channelB,
            "still mid-switch"
        )
        XCTAssertEqual(policy.requestedChannelID, channelB)
    }
}
