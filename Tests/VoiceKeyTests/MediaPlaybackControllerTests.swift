@testable import VoiceKey
import XCTest

/// A scripting layer that answers from a script the test writes, and records
/// every call. No Apple Event is sent by anything in this file.
private final class FakeMediaPlayerScripting: MediaPlayerScripting {
    enum Call: Equatable {
        case isRunning(String)
        case state(String)
        case pause(String)
        case play(String)
    }

    /// The controller answers on its own serial queue, and the quit tests read
    /// these from the test thread, so every access goes through the lock.
    private let lock = NSLock()
    private var runningNames: Set<String> = []
    private var stateResults:
        [String: Result<MediaPlayerState, MediaScriptingFailure>] = [:]
    private var pauseOutcomes: [String: Result<Void, MediaScriptingFailure>] =
        [:]
    private var playOutcomes: [String: Result<Void, MediaScriptingFailure>] =
        [:]
    private var recordedCalls: [Call] = []

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var running: Set<String> {
        get { locked { runningNames } }
        set { locked { runningNames = newValue } }
    }

    var states: [String: Result<MediaPlayerState, MediaScriptingFailure>] {
        get { locked { stateResults } }
        set { locked { stateResults = newValue } }
    }

    var pauseResults: [String: Result<Void, MediaScriptingFailure>] {
        get { locked { pauseOutcomes } }
        set { locked { pauseOutcomes = newValue } }
    }

    var playResults: [String: Result<Void, MediaScriptingFailure>] {
        get { locked { playOutcomes } }
        set { locked { playOutcomes = newValue } }
    }

    var calls: [Call] {
        locked { recordedCalls }
    }

    func isRunning(_ player: MediaPlayer) -> Bool {
        locked {
            recordedCalls.append(.isRunning(player.name))
            return runningNames.contains(player.name)
        }
    }

    func state(
        of player: MediaPlayer
    ) -> Result<MediaPlayerState, MediaScriptingFailure> {
        locked {
            recordedCalls.append(.state(player.name))
            return stateResults[player.name] ?? .success(.stopped)
        }
    }

    func pause(
        _ player: MediaPlayer
    ) -> Result<Void, MediaScriptingFailure> {
        locked {
            recordedCalls.append(.pause(player.name))
            return pauseOutcomes[player.name] ?? .success(())
        }
    }

    func play(
        _ player: MediaPlayer
    ) -> Result<Void, MediaScriptingFailure> {
        locked {
            recordedCalls.append(.play(player.name))
            return playOutcomes[player.name] ?? .success(())
        }
    }

    /// Every call that would have crossed the Apple Event boundary. `isRunning`
    /// is excluded because it reads the process list.
    var scriptedCalls: [Call] {
        calls.filter {
            if case .isRunning = $0 { return false }
            return true
        }
    }
}

final class MediaPlaybackControllerTests: XCTestCase {
    private var scripting = FakeMediaPlayerScripting()
    private var log: [String] = []

    override func setUp() {
        super.setUp()
        scripting = FakeMediaPlayerScripting()
        log = []
    }

    /// The decision tests run the work inline, so every assertion is about what
    /// the controller decided rather than when a queue got round to it.
    private func makeController(
        players: [MediaPlayer] = [.music, .spotify]
    ) -> MediaPlaybackController {
        let controller = MediaPlaybackController(
            scripting: scripting,
            players: players,
            execute: { $0() }
        )
        controller.onDiagnostic = { [weak self] message in
            self?.log.append(message)
        }
        return controller
    }

    // MARK: - The core cycle

    func testPlayingPlayerIsPausedOnActivationAndResumedOnClose() {
        scripting.running = ["Music"]
        scripting.states["Music"] = .success(.playing)
        let controller = makeController()
        let channel = UUID()

        controller.channelDidActivate(channel)

        XCTAssertEqual(
            scripting.scriptedCalls,
            [.state("Music"), .pause("Music")]
        )

        scripting.states["Music"] = .success(.paused)
        controller.channelDidDeactivate(channel)

        XCTAssertEqual(
            scripting.scriptedCalls,
            [
                .state("Music"),
                .pause("Music"),
                .state("Music"),
                .play("Music")
            ]
        )
        XCTAssertEqual(log, [
            "Paused Music while a voice channel is active.",
            "Resumed Music after the last voice channel closed."
        ])
    }

    func testAlreadyPausedPlayerIsNotResumedWhenTheChannelCloses() {
        scripting.running = ["Music"]
        scripting.states["Music"] = .success(.paused)
        let controller = makeController()
        let channel = UUID()

        controller.channelDidActivate(channel)
        controller.channelDidDeactivate(channel)

        XCTAssertEqual(scripting.scriptedCalls, [.state("Music")])
        XCTAssertTrue(log.isEmpty, "nothing happened, so nothing is logged")
    }

    func testStoppedPlayerIsNeitherPausedNorStarted() {
        scripting.running = ["Music"]
        scripting.states["Music"] = .success(.stopped)
        let controller = makeController()
        let channel = UUID()

        controller.channelDidActivate(channel)
        controller.channelDidDeactivate(channel)

        XCTAssertEqual(
            scripting.scriptedCalls,
            [.state("Music")],
            "a stopped player must never be sent play — that starts music the "
            + "owner did not ask for"
        )
    }

    // MARK: - The launch guard

    func testPlayerThatIsNotRunningIsNeverContacted() {
        scripting.running = []
        scripting.states["Music"] = .success(.playing)
        let controller = makeController()
        let channel = UUID()

        controller.channelDidActivate(channel)
        controller.channelDidDeactivate(channel)

        XCTAssertEqual(
            scripting.scriptedCalls,
            [],
            "asking a player that is not running launches it"
        )
        XCTAssertEqual(
            scripting.calls,
            [
                .isRunning("Music"),
                .isRunning("Spotify")
            ]
        )
    }

    func testPlayerThatQuitsDuringTheSessionIsNotRelaunchedToResumeIt() {
        scripting.running = ["Music"]
        scripting.states["Music"] = .success(.playing)
        let controller = makeController(players: [.music])
        let channel = UUID()

        controller.channelDidActivate(channel)
        scripting.running = []

        controller.channelDidDeactivate(channel)

        XCTAssertEqual(
            scripting.scriptedCalls,
            [.state("Music"), .pause("Music")],
            "the player quit; resuming it would launch it again"
        )
    }

    // MARK: - More than one channel

    func testSwitchingChannelsDoesNotResumeInBetween() {
        scripting.running = ["Music"]
        scripting.states["Music"] = .success(.playing)
        let controller = makeController(players: [.music])
        let channelA = UUID()
        let channelB = UUID()

        controller.setActiveChannel(channelA)
        scripting.states["Music"] = .success(.paused)
        controller.setActiveChannel(channelB)

        XCTAssertEqual(
            scripting.scriptedCalls,
            [.state("Music"), .pause("Music")],
            "a switch must not put the music back for the width of one "
            + "statement"
        )

        controller.setActiveChannel(nil)

        XCTAssertEqual(
            scripting.scriptedCalls,
            [.state("Music"), .pause("Music"), .state("Music"), .play("Music")]
        )
    }

    func testSecondChannelClosingResumesOnlyAfterTheLastOne() {
        scripting.running = ["Music"]
        scripting.states["Music"] = .success(.playing)
        let controller = makeController(players: [.music])
        let channelA = UUID()
        let channelB = UUID()

        controller.channelDidActivate(channelA)
        scripting.states["Music"] = .success(.paused)
        controller.channelDidActivate(channelB)

        XCTAssertEqual(
            scripting.scriptedCalls,
            [.state("Music"), .pause("Music")],
            "the second channel must not re-scan"
        )

        controller.channelDidDeactivate(channelA)

        XCTAssertEqual(
            scripting.scriptedCalls,
            [.state("Music"), .pause("Music")],
            "a channel is still open"
        )

        controller.channelDidDeactivate(channelB)

        XCTAssertEqual(
            scripting.scriptedCalls,
            [.state("Music"), .pause("Music"), .state("Music"), .play("Music")]
        )
    }

    func testSecondChannelDoesNotOverwriteWhatTheFirstOnePaused() {
        scripting.running = ["Music"]
        scripting.states["Music"] = .success(.playing)
        let controller = makeController(players: [.music])
        let channelA = UUID()
        let channelB = UUID()

        controller.channelDidActivate(channelA)
        // Music is paused now, so a re-scan would find nothing playing and
        // forget that we are the ones who paused it.
        scripting.states["Music"] = .success(.paused)
        controller.channelDidActivate(channelB)
        controller.channelDidDeactivate(channelA)
        controller.channelDidDeactivate(channelB)

        XCTAssertEqual(
            log,
            [
                "Paused Music while a voice channel is active.",
                "Resumed Music after the last voice channel closed."
            ]
        )
    }

    // MARK: - The owner's own decisions win

    func testOwnerPressingPlayMidSessionIsLeftAlone() {
        scripting.running = ["Music"]
        scripting.states["Music"] = .success(.playing)
        let controller = makeController(players: [.music])
        let channel = UUID()

        controller.channelDidActivate(channel)
        // The owner hit play themselves while the channel was open.
        scripting.states["Music"] = .success(.playing)

        controller.channelDidDeactivate(channel)

        XCTAssertEqual(
            scripting.scriptedCalls,
            [.state("Music"), .pause("Music"), .state("Music")],
            "it is already playing; sending play again is not ours to do"
        )
        XCTAssertEqual(log, [
            "Paused Music while a voice channel is active."
        ])
    }

    func testOwnerStoppingPlaybackMidSessionIsNotResumed() {
        scripting.running = ["Music"]
        scripting.states["Music"] = .success(.playing)
        let controller = makeController(players: [.music])
        let channel = UUID()

        controller.channelDidActivate(channel)
        // Stopped outright and moved on.
        scripting.states["Music"] = .success(.stopped)

        controller.channelDidDeactivate(channel)

        XCTAssertEqual(
            scripting.scriptedCalls,
            [.state("Music"), .pause("Music"), .state("Music")]
        )
    }

    func testAppOpenWithNoChannelEverActiveTouchesNothing() {
        scripting.running = ["Music", "Spotify"]
        scripting.states["Music"] = .success(.playing)
        scripting.states["Spotify"] = .success(.playing)
        let controller = makeController()

        // What the delegate does on every status change while idle.
        for _ in 0..<5 {
            controller.setActiveChannel(nil)
        }

        XCTAssertEqual(scripting.calls, [], "audio plays as normal")
        XCTAssertTrue(log.isEmpty)
    }

    // MARK: - Failure never reaches the session

    func testPermissionDenialIsLoggedOnceAndResumesNothing() {
        scripting.running = ["Music", "Spotify"]
        scripting.states["Music"] = .failure(.permissionDenied)
        scripting.states["Spotify"] = .failure(.permissionDenied)
        let controller = makeController()

        controller.channelDidActivate(UUID())
        controller.setActiveChannel(nil)
        controller.channelDidActivate(UUID())
        controller.setActiveChannel(nil)

        XCTAssertEqual(
            log.count,
            1,
            "one denial notice per session, not one per channel"
        )
        XCTAssertEqual(log.first?.contains("not allowed to control"), true)
    }

    func testDeniedPermissionLeavesTheControllerUsable() {
        scripting.running = ["Music"]
        scripting.states["Music"] = .failure(.permissionDenied)
        let controller = makeController(players: [.music])
        let denied = UUID()

        controller.channelDidActivate(denied)
        controller.channelDidDeactivate(denied)

        // The owner grants it, and the very next channel works.
        scripting.states["Music"] = .success(.playing)
        let granted = UUID()
        controller.channelDidActivate(granted)
        scripting.states["Music"] = .success(.paused)
        controller.channelDidDeactivate(granted)

        XCTAssertEqual(log.suffix(2), [
            "Paused Music while a voice channel is active.",
            "Resumed Music after the last voice channel closed."
        ])
    }

    func testPauseThatFailsLeavesThePlayerOutOfTheResumeSet() {
        scripting.running = ["Music"]
        scripting.states["Music"] = .success(.playing)
        scripting.pauseResults["Music"] = .failure(.scriptingError(code: -1728))
        let controller = makeController(players: [.music])
        let channel = UUID()

        controller.channelDidActivate(channel)
        scripting.states["Music"] = .success(.paused)
        controller.channelDidDeactivate(channel)

        XCTAssertEqual(
            scripting.scriptedCalls,
            [.state("Music"), .pause("Music")],
            "the pause failed, so this player was never ours to resume"
        )
        XCTAssertEqual(log, [
            "Could not pause Music (AppleScript error -1728)."
        ])
    }

    /// The decisive one: the entry point returns without waiting for the
    /// scripting layer, so no amount of Apple Event latency — or a permission
    /// prompt sitting on screen — can delay a voice session starting.
    func testActivationDoesNotWaitForTheScriptingLayer() {
        let blocking = BlockingScripting()
        let controller = MediaPlaybackController(
            scripting: blocking,
            players: [.music]
        )

        controller.channelDidActivate(UUID())

        XCTAssertFalse(
            blocking.didFinish,
            "channelDidActivate blocked on the scripting layer"
        )
        waitUntil(
            { blocking.didEnter },
            "the scripting layer was never reached"
        )
        blocking.unblock()
        waitUntil(
            { blocking.didFinish },
            "the scripting work never completed"
        )
    }

    // MARK: - Quitting

    /// Quit is the one channel close no status reports. Without this the owner
    /// quits VoiceKey and is left with music VoiceKey paused and nothing
    /// running that could ever put it back.
    func testQuittingWithAChannelOpenResumesWhatWePaused() {
        scripting.running = ["Music"]
        scripting.states["Music"] = .success(.playing)
        let controller = makeController(players: [.music])

        controller.setActiveChannel(UUID())
        scripting.states["Music"] = .success(.paused)

        controller.resumeBeforeTermination()

        XCTAssertEqual(
            scripting.scriptedCalls,
            [.state("Music"), .pause("Music"), .state("Music"), .play("Music")]
        )
        XCTAssertEqual(log, [
            "Paused Music while a voice channel is active.",
            "Resumed Music after the last voice channel closed."
        ])
    }

    /// The decisive one for quit: the resume runs on the executor's queue, and
    /// the process is about to exit, so the call has to still be inside it when
    /// the play lands. An async reconcile here would never run at all.
    func testQuittingWaitsForWorkTheExecutorRunsElsewhere() {
        scripting.running = ["Music"]
        scripting.states["Music"] = .success(.playing)
        let queue = DispatchQueue(label: "media-playback-test")
        let controller = MediaPlaybackController(
            scripting: scripting,
            players: [.music],
            execute: { queue.async(execute: $0) }
        )

        controller.setActiveChannel(UUID())
        waitUntil(
            { self.scripting.scriptedCalls.contains(.pause("Music")) },
            "the pause never reached the scripting layer"
        )
        scripting.states["Music"] = .success(.paused)

        controller.resumeBeforeTermination()

        XCTAssertTrue(
            scripting.scriptedCalls.contains(.play("Music")),
            "resumeBeforeTermination returned before the music was put back"
        )
    }

    /// A player that has stopped answering Apple Events must not be able to
    /// wedge quit. The executor here never runs the work at all, which is the
    /// worst case the bound exists for.
    func testQuittingIsBoundedWhenTheResumeCannotRun() {
        let controller = MediaPlaybackController(
            scripting: scripting,
            players: [.music],
            execute: { _ in }
        )

        controller.resumeBeforeTermination(timeout: 0.05)

        // Returning at all is the assertion; a controller without the bound
        // hangs here and the suite times out rather than failing.
        XCTAssertEqual(scripting.calls, [])
    }

    func testQuittingWithNothingPausedContactsNobody() {
        scripting.running = ["Music"]
        scripting.states["Music"] = .success(.playing)
        let controller = makeController(players: [.music])

        controller.resumeBeforeTermination()

        XCTAssertEqual(
            scripting.calls,
            [],
            "VoiceKey paused nothing, so quitting starts nothing"
        )
    }

    // MARK: - What reaches the log

    func testTheLogNamesAppsAndNothingElse() {
        scripting.running = ["Music", "Spotify"]
        scripting.states["Music"] = .success(.playing)
        scripting.states["Spotify"] = .failure(.scriptingError(code: -1743))
        let controller = makeController()
        let channel = UUID()

        controller.channelDidActivate(channel)
        scripting.states["Music"] = .success(.paused)
        scripting.states["Spotify"] = .failure(.permissionDenied)
        controller.channelDidDeactivate(channel)

        XCTAssertFalse(log.isEmpty)
        let allowedNames = Set(["Music", "Spotify", "VoiceKey"])
        for line in log {
            // Every capitalised word in a log line has to be one of the app
            // names, a sentence opener, or fixed vocabulary. A track title,
            // artist, or playlist would show up here.
            let capitalised = line
                .split(whereSeparator: { $0 == " " || $0 == "(" })
                .map { $0.trimmingCharacters(in: .punctuationCharacters) }
                .filter { $0.first?.isUppercase == true }
            for word in capitalised where allowedNames.contains(word) == false {
                XCTAssertTrue(
                    Self.fixedVocabulary.contains(word),
                    "unexpected proper noun \"\(word)\" in log line: \(line)"
                )
            }
        }
    }

    /// Words the controller itself writes. Anything capitalised that is not
    /// here and not an app name came from somewhere it should not have.
    private static let fixedVocabulary: Set<String> = [
        "Paused", "Resumed", "Could", "Allow", "System", "Settings",
        "Privacy", "Security", "Automation", "AppleScript"
    ]
}

/// Blocks inside the scripting layer until the test lets it go, so the test can
/// prove the caller was never waiting on it.
private final class BlockingScripting: MediaPlayerScripting {
    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var enteredFlag = false
    private var finishedFlag = false

    var didEnter: Bool {
        lock.lock()
        defer { lock.unlock() }
        return enteredFlag
    }

    var didFinish: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finishedFlag
    }

    func unblock() {
        gate.signal()
    }

    func isRunning(_ player: MediaPlayer) -> Bool {
        lock.lock()
        enteredFlag = true
        lock.unlock()
        // Bounded, so a controller that *does* block fails the assertion
        // instead of hanging the suite.
        _ = gate.wait(timeout: .now() + 5)
        lock.lock()
        finishedFlag = true
        lock.unlock()
        return false
    }

    func state(
        of player: MediaPlayer
    ) -> Result<MediaPlayerState, MediaScriptingFailure> {
        .success(.stopped)
    }

    func pause(
        _ player: MediaPlayer
    ) -> Result<Void, MediaScriptingFailure> {
        .success(())
    }

    func play(
        _ player: MediaPlayer
    ) -> Result<Void, MediaScriptingFailure> {
        .success(())
    }
}
