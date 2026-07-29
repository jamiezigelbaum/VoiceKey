import Foundation

/// A script-controllable media player VoiceKey pauses while a voice channel is
/// listening.
///
/// The table below is the whole registry — adding a player is one row, and no
/// decision in this file names a player.
struct MediaPlayer: Equatable, Hashable {
    /// The AppleScript application name, as in `tell application "Music"`.
    let name: String
    /// Checked against the running process list before any script is compiled.
    /// That check is what makes launching a player impossible.
    let bundleID: String

    static let music = MediaPlayer(
        name: "Music",
        bundleID: "com.apple.Music"
    )
    static let spotify = MediaPlayer(
        name: "Spotify",
        bundleID: "com.spotify.client"
    )

    static let all: [MediaPlayer] = [.music, .spotify]
}

/// Both players' `player state` resolves to the same `ePlS` enumeration —
/// `stopped` / `playing` / `paused` — verified 2026-07-29 against
/// `com.apple.Music.sdef` and `Spotify.sdef` on disk.
///
/// Music also defines `fast forwarding` and `rewinding`; both land in
/// `stopped` here, which costs a pause during a scrub and can never cause a
/// spurious resume.
enum MediaPlayerState: Equatable {
    case playing
    case paused
    case stopped
}

/// Why a scripting call did not answer.
///
/// It deliberately carries no free text. The session log is written to be
/// pasteable into a public bug report, and an `NSAppleScript` error dictionary
/// is the *player's own prose about the player's own state* — a string that
/// can name a track. An `OSStatus` is a number, and a number cannot.
enum MediaScriptingFailure: Error, Equatable {
    /// The owner declined the automation prompt, or has it turned off.
    case permissionDenied
    case scriptingError(code: Int)
}

/// The scripting layer, kept behind a protocol so every decision below is
/// testable without sending a single Apple Event.
protocol MediaPlayerScripting: AnyObject {
    /// Must answer from the process list without sending an Apple Event, and
    /// must never launch the player.
    func isRunning(_ player: MediaPlayer) -> Bool
    func state(
        of player: MediaPlayer
    ) -> Result<MediaPlayerState, MediaScriptingFailure>
    func pause(
        _ player: MediaPlayer
    ) -> Result<Void, MediaScriptingFailure>
    func play(
        _ player: MediaPlayer
    ) -> Result<Void, MediaScriptingFailure>
}

/// Pauses whatever is playing while a voice channel is open, and puts back
/// exactly what it paused when the last one closes.
///
/// Transport control, not ducking: the owner's ruling is that a voice channel
/// takes the audio session outright, and that music returns untouched
/// afterwards.
final class MediaPlaybackController {
    typealias WorkExecutor = (@escaping () -> Void) -> Void

    private let players: [MediaPlayer]
    private let scripting: MediaPlayerScripting
    private let execute: WorkExecutor

    /// Written on whichever thread drives the channel lifecycle (the main
    /// thread, in the app). Never read by the executor — `reconcile()` hands
    /// the executor a snapshot instead, so the two sides share no state.
    private var activeChannels: Set<UUID> = []

    /// Everything below is touched only inside `execute`, which is serial.
    private var pausedPlayers: [MediaPlayer] = []
    private var hasPausedForCurrentActivation = false
    private var hasReportedPermissionDenial = false

    /// Session-log text. Called on the executor's queue, so a handler that
    /// touches AppKit has to hop to the main thread itself.
    ///
    /// Every string handed to this closure names apps and nothing else.
    var onDiagnostic: ((String) -> Void)?

    init(
        scripting: MediaPlayerScripting,
        players: [MediaPlayer] = MediaPlayer.all,
        execute: @escaping WorkExecutor =
            MediaPlaybackController.makeDefaultExecutor()
    ) {
        self.scripting = scripting
        self.players = players
        self.execute = execute
    }

    /// A pause is a synchronous Apple Event round trip, and the caller is the
    /// main thread on its way to building the audio graph. Nothing here may
    /// block, delay, or fail a voice session, so the round trip happens here
    /// instead.
    ///
    /// Serial, so a pause and the resume that follows it cannot overlap or
    /// arrive out of order. `NSAppleScript` compiles and executes on a
    /// background serial queue — verified 2026-07-29,
    /// `scripts/dev/probe-media-scripting.swift`.
    static func makeDefaultExecutor() -> WorkExecutor {
        let queue = DispatchQueue(
            label: "com.zigelbaum.VoiceKey.media-playback"
        )
        return { queue.async(execute: $0) }
    }

    // MARK: - Channel lifecycle

    func channelDidActivate(_ channelID: UUID) {
        activeChannels.insert(channelID)
        reconcile()
    }

    func channelDidDeactivate(_ channelID: UUID) {
        activeChannels.remove(channelID)
        reconcile()
    }

    /// The at-most-one-channel form the app delegate uses.
    func setActiveChannel(_ channelID: UUID?) {
        setActiveChannels(channelID.map { [$0] } ?? [])
    }

    /// The whole active set in one call, and the reason switching channels
    /// cannot resume in between: VoiceKey moves from channel A to channel B in
    /// a single assignment, so the active set never passes through empty.
    /// Calling deactivate-then-activate around a switch would put the owner's
    /// music back for the width of one statement.
    func setActiveChannels(_ channelIDs: Set<UUID>) {
        activeChannels = channelIDs
        reconcile()
    }

    private func reconcile() {
        let isAnyChannelActive = activeChannels.isEmpty == false
        execute { [weak self] in
            self?.apply(isAnyChannelActive: isAnyChannelActive)
        }
    }

    private func apply(isAnyChannelActive: Bool) {
        if isAnyChannelActive {
            pauseWhateverIsPlaying()
        } else {
            resumeWhatWePaused()
        }
    }

    // MARK: - The two passes

    private func pauseWhateverIsPlaying() {
        // A second channel opening while the first is live must not re-scan,
        // and must not overwrite the set the first one paused.
        guard hasPausedForCurrentActivation == false else { return }
        hasPausedForCurrentActivation = true

        var paused: [MediaPlayer] = []
        for player in players {
            // The launch guard. `tell application "Music"` *launches* Music in
            // order to ask it anything; the process list does not.
            guard scripting.isRunning(player) else { continue }

            switch scripting.state(of: player) {
            case .success(.playing):
                switch scripting.pause(player) {
                case .success:
                    pausedPlayers.append(player)
                    paused.append(player)
                case let .failure(failure):
                    report(failure, couldNot: "pause", player: player)
                }
            case .success(.paused), .success(.stopped):
                // Nothing was playing, so nothing is remembered, so nothing is
                // resumed when the channel closes.
                continue
            case let .failure(failure):
                report(
                    failure,
                    couldNot: "read the state of",
                    player: player
                )
            }
        }

        guard paused.isEmpty == false else { return }
        onDiagnostic?(
            "Paused \(names(paused)) while a voice channel is active."
        )
    }

    private func resumeWhatWePaused() {
        hasPausedForCurrentActivation = false

        // Resuming is only ever putting back what this controller paused, so
        // requirement 3 holds structurally rather than by a guard: with the app
        // open and no channel ever activated, this set is empty and the pass
        // below contacts nobody. (A guard here tested as dead code — no
        // mutation of it changed an observable outcome.)
        let candidates = pausedPlayers
        pausedPlayers = []

        var resumed: [MediaPlayer] = []
        for player in candidates {
            // Quit while we were talking. Asking would relaunch it.
            guard scripting.isRunning(player) else { continue }

            switch scripting.state(of: player) {
            case .success(.paused):
                switch scripting.play(player) {
                case .success:
                    resumed.append(player)
                case let .failure(failure):
                    report(failure, couldNot: "resume", player: player)
                }
            case .success(.playing), .success(.stopped):
                // The owner pressed play, or stopped it outright and moved on.
                // Either way the state it is in now is the one they chose.
                continue
            case let .failure(failure):
                report(
                    failure,
                    couldNot: "read the state of",
                    player: player
                )
            }
        }

        guard resumed.isEmpty == false else { return }
        onDiagnostic?(
            "Resumed \(names(resumed)) after the last voice channel closed."
        )
    }

    // MARK: - Logging

    private func report(
        _ failure: MediaScriptingFailure,
        couldNot verb: String,
        player: MediaPlayer
    ) {
        switch failure {
        case .permissionDenied:
            // Once per session. The owner declined; repeating it every time a
            // channel opens would bury the log they are meant to read.
            guard hasReportedPermissionDenial == false else { return }
            hasReportedPermissionDenial = true
            onDiagnostic?(
                "VoiceKey is not allowed to control \(player.name), so other "
                + "media was left playing. Allow it under System Settings > "
                + "Privacy & Security > Automation."
            )
        case let .scriptingError(code):
            onDiagnostic?(
                "Could not \(verb) \(player.name) (AppleScript error \(code))."
            )
        }
    }

    /// App names, and nothing else. Never a track, an artist, or a playlist.
    private func names(_ players: [MediaPlayer]) -> String {
        players.map(\.name).joined(separator: ", ")
    }
}
