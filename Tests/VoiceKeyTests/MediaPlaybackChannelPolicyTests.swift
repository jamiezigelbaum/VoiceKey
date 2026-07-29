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

    /// The outgoing session is still emitting when the request is made. Its
    /// statuses arrive with `activeProfileID` already pointing at the incoming
    /// channel, so a live status alone cannot mean "the new one reported in" —
    /// only the `.starting` that opens a session can.
    func testAStaleLiveStatusFromTheOutgoingSessionDoesNotClearTheRequest() {
        let channelA = UUID()
        let channelB = UUID()

        policy.channelRequested(channelA)
        _ = policy.activeChannel(activeProfileID: channelA, status: .starting)
        _ = policy.activeChannel(activeProfileID: channelA, status: .listening)

        // The owner hits B's hotkey. activate() commits to B, and A's own
        // `.listening` — queued before the switch, or read straight off the
        // delegate's stale `currentStatus` — lands next.
        policy.channelRequested(channelB)
        XCTAssertEqual(
            policy.activeChannel(activeProfileID: channelB, status: .listening),
            channelB
        )
        XCTAssertEqual(
            policy.requestedChannelID,
            channelB,
            "that .listening came from the session being torn down"
        )

        XCTAssertEqual(
            policy.activeChannel(activeProfileID: channelB, status: .stopping),
            channelB
        )
        XCTAssertEqual(
            policy.activeChannel(activeProfileID: channelB, status: .ready),
            channelB,
            "releasing here is the blip requirement 4 forbids"
        )

        XCTAssertEqual(
            policy.activeChannel(activeProfileID: channelB, status: .starting),
            channelB
        )
        XCTAssertNil(policy.requestedChannelID, "B opened its session")
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
        _ = policy.activeChannel(activeProfileID: channel, status: .starting)
        XCTAssertNil(
            policy.requestedChannelID,
            "the session opened, so the next stop is honest"
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

    // MARK: - Every status a requested channel can land on

    /// An expired web session. No voice session can start until the owner logs
    /// in, and holding their music until they notice is the stuck-paused mode
    /// that is worse than never pausing.
    func testALoginPromptReleasesTheMusic() {
        let channel = UUID()
        policy.channelRequested(channel)

        XCTAssertNil(
            policy.activeChannel(
                activeProfileID: channel,
                status: .loginRequired
            ),
            "nothing can start until the owner signs in"
        )
        XCTAssertNil(policy.requestedChannelID)
    }

    /// The other side of the same coin: a channel still on its way up must keep
    /// the music paused, or it comes back for the width of the start.
    func testAChannelStillComingUpHoldsTheMusic() {
        for status in [ProviderStatus.loading, .checking, .ready, .stopping] {
            var policy = MediaPlaybackChannelPolicy()
            let channel = UUID()
            policy.channelRequested(channel)

            XCTAssertEqual(
                policy.activeChannel(
                    activeProfileID: channel,
                    status: status
                ),
                channel,
                "\(status) is on the way to a session, not the end of one"
            )
            XCTAssertEqual(policy.requestedChannelID, channel)
        }
    }

    // MARK: - The bound on the hold

    /// The shape that has no status to end it: two channels share a provider
    /// instance, the outgoing stop leaves it `.stopping`, so the incoming
    /// channel's `toggleVoice` stops it again instead of starting. It settles
    /// at `.ready` and says nothing further — forever, without this.
    func testARequestThatNeverStartsIsReleasedWhenItExpires() {
        let channel = UUID()
        policy.channelRequested(channel)
        let generation = policy.requestGeneration

        _ = policy.activeChannel(activeProfileID: channel, status: .stopping)
        XCTAssertEqual(
            policy.activeChannel(activeProfileID: channel, status: .ready),
            channel,
            "indistinguishable from a switch until it expires"
        )

        policy.requestDidExpire(generation: generation)

        XCTAssertNil(policy.requestedChannelID)
        XCTAssertNil(
            policy.activeChannel(activeProfileID: channel, status: .ready),
            "the music comes back rather than staying paused for good"
        )
    }

    /// Two hotkey presses inside the timeout: the first one's fallback must not
    /// release the second one's hold.
    func testAnExpiredRequestDoesNotReleaseTheOneThatReplacedIt() {
        let channelA = UUID()
        let channelB = UUID()

        policy.channelRequested(channelA)
        let staleGeneration = policy.requestGeneration
        policy.channelRequested(channelB)

        policy.requestDidExpire(generation: staleGeneration)

        XCTAssertEqual(policy.requestedChannelID, channelB)
        XCTAssertEqual(
            policy.activeChannel(activeProfileID: channelB, status: .ready),
            channelB
        )
    }

    /// The same channel twice, so the id cannot tell the requests apart.
    func testExpiryIsMatchedByRequestRatherThanByChannel() {
        let channel = UUID()

        policy.channelRequested(channel)
        let staleGeneration = policy.requestGeneration
        policy.channelRequested(channel)

        policy.requestDidExpire(generation: staleGeneration)

        XCTAssertEqual(
            policy.requestedChannelID,
            channel,
            "that expiry belonged to the previous press"
        )
    }
}
