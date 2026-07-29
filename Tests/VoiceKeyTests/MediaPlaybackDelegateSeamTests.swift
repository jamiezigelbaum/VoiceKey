@testable import VoiceKey
import XCTest

/// The two pieces were each right and the app still blipped, because the blip
/// lived in the order the delegate calls them in. So this file replays that
/// order — `VoiceKeyAppDelegate.activate()` and `updateStatus()` — against the
/// real policy and the real controller, and asserts on what the scripting layer
/// is actually asked to do.
///
/// `MediaPlaybackDelegateSeam` below mirrors the delegate's calls and nothing
/// else. If the delegate's order changes, this has to change with it.
private final class MediaPlaybackDelegateSeam {
    private var channels = MediaPlaybackChannelPolicy()
    private let playback: MediaPlaybackController

    /// The delegate's own stored state.
    private var activeProfileID: UUID?
    private var currentStatus: ProviderStatus = .ready

    init(playback: MediaPlaybackController) {
        self.playback = playback
    }

    /// `VoiceKeyAppDelegate.activate(profileID:)`, from the stop of the
    /// outgoing session onwards.
    func activate(_ channelID: UUID) {
        activeProfileID = channelID
        channels.channelRequested(channelID)
        playback.setActiveChannel(channelID)
    }

    /// `VoiceKeyAppDelegate.updateStatus(_:)` — the funnel every provider event
    /// arrives through, followed by `syncMediaPlayback()`.
    func statusArrived(_ status: ProviderStatus) {
        currentStatus = status
        playback.setActiveChannel(
            channels.activeChannel(
                activeProfileID: activeProfileID,
                status: currentStatus
            )
        )
    }

    /// What `armMediaPlaybackRequestTimeout()` schedules, run on demand so the
    /// test never waits on a clock.
    func requestTimeoutFired() {
        channels.requestDidExpire(generation: channels.requestGeneration)
        playback.setActiveChannel(
            channels.activeChannel(
                activeProfileID: activeProfileID,
                status: currentStatus
            )
        )
    }

    /// `applicationWillTerminate(_:)`.
    func willTerminate() {
        channels.runtimeWasReset()
        playback.resumeBeforeTermination()
    }
}

final class MediaPlaybackDelegateSeamTests: XCTestCase {
    private var scripting = SeamScripting()
    private var seam: MediaPlaybackDelegateSeam!

    override func setUp() {
        super.setUp()
        scripting = SeamScripting()
        scripting.running = ["Music"]
        scripting.state = .playing
        seam = MediaPlaybackDelegateSeam(
            playback: MediaPlaybackController(
                scripting: scripting,
                terminationScripting: scripting,
                players: [.music],
                execute: { $0() },
                executeTermination: { $0() }
            )
        )
    }

    /// The owner switches from a live channel to another one on the same
    /// provider. The outgoing session's `.stopping` → `.ready` arrive with
    /// `activeProfileID` already pointing at the incoming channel, and the
    /// incoming `.starting` lands a main-thread turn or two later.
    ///
    /// Any `play` before that `.starting` is a burst of music in the owner's
    /// ears, which is what requirement 4 forbids.
    func testSwitchingChannelsNeverSendsPlayInBetween() {
        let channelA = UUID()
        let channelB = UUID()

        seam.activate(channelA)
        seam.statusArrived(.starting)
        seam.statusArrived(.listening)
        XCTAssertEqual(scripting.transport, [.pause])

        // The owner hits B's hotkey.
        seam.activate(channelB)
        // A status the outgoing session had already emitted, delivered after
        // the switch because `emit` hops through the main queue.
        seam.statusArrived(.listening)
        seam.statusArrived(.stopping)
        seam.statusArrived(.ready)

        XCTAssertEqual(
            scripting.transport,
            [.pause],
            "the music was put back in the gap between the two channels"
        )

        seam.statusArrived(.starting)
        seam.statusArrived(.listening)
        XCTAssertEqual(scripting.transport, [.pause])

        // B closes for real.
        seam.statusArrived(.stopping)
        seam.statusArrived(.ready)
        XCTAssertEqual(scripting.transport, [.pause, .play])
    }

    func testClosingTheOnlyChannelPutsTheMusicBack() {
        seam.activate(UUID())
        seam.statusArrived(.starting)
        seam.statusArrived(.listening)
        seam.statusArrived(.stopping)
        seam.statusArrived(.ready)

        XCTAssertEqual(scripting.transport, [.pause, .play])
    }

    /// The shape with no status to end it: two channels share a provider
    /// instance that is still `.stopping`, so the incoming channel's
    /// `toggleVoice` stops it again rather than starting it. It settles at
    /// `.ready` and nothing further is ever reported.
    func testAChannelThatNeverStartsDoesNotStrandTheMusic() {
        let channelA = UUID()
        let channelB = UUID()

        seam.activate(channelA)
        seam.statusArrived(.starting)
        seam.statusArrived(.listening)

        seam.activate(channelB)
        seam.statusArrived(.stopping)
        seam.statusArrived(.ready)
        XCTAssertEqual(
            scripting.transport,
            [.pause],
            "indistinguishable from a switch until the request expires"
        )

        seam.requestTimeoutFired()

        XCTAssertEqual(
            scripting.transport,
            [.pause, .play],
            "no session is running, so the owner's music is theirs again"
        )
    }

    func testALoginPromptDoesNotStrandTheMusic() {
        seam.activate(UUID())
        seam.statusArrived(.loading)
        XCTAssertEqual(scripting.transport, [.pause], "still coming up")

        seam.statusArrived(.loginRequired)

        XCTAssertEqual(
            scripting.transport,
            [.pause, .play],
            "the owner has to sign in before anything can start"
        )
    }

    func testQuittingWithAChannelStillOpenPutsTheMusicBack() {
        seam.activate(UUID())
        seam.statusArrived(.starting)
        seam.statusArrived(.listening)
        XCTAssertEqual(scripting.transport, [.pause])

        seam.willTerminate()

        XCTAssertEqual(
            scripting.transport,
            [.pause, .play],
            "VoiceKey is about to be gone; nothing else can put it back"
        )
    }
}

/// Tracks the state a player would really be in, so a second pause or a play
/// sent to something already playing shows up in `transport` rather than being
/// hidden by a fixture that always answers the same way.
private final class SeamScripting: MediaPlayerScripting {
    enum Transport: Equatable {
        case pause
        case play
    }

    var running: Set<String> = []
    var state: MediaPlayerState = .stopped
    private(set) var transport: [Transport] = []

    func isRunning(_ player: MediaPlayer) -> Bool {
        running.contains(player.name)
    }

    func state(
        of player: MediaPlayer
    ) -> Result<MediaPlayerState, MediaScriptingFailure> {
        .success(state)
    }

    func pause(
        _ player: MediaPlayer
    ) -> Result<Void, MediaScriptingFailure> {
        transport.append(.pause)
        state = .paused
        return .success(())
    }

    func play(
        _ player: MediaPlayer
    ) -> Result<Void, MediaScriptingFailure> {
        transport.append(.play)
        state = .playing
        return .success(())
    }
}
