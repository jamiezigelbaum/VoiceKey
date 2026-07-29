import AppKit
import Foundation

/// The real scripting layer: `NSAppleScript`, in this process.
///
/// In-process on purpose. Shelling out to `osascript` would attribute the
/// automation permission to `/usr/bin/osascript` rather than to VoiceKey, so
/// the entitlement below would buy nothing and the owner's grant would be
/// against the wrong app.
///
/// Not thread-safe, and does not need to be: `MediaPlaybackController` drives
/// it from a serial executor, so only one queue is ever inside it.
final class AppleScriptMediaPlayerScripting: MediaPlayerScripting {
    /// TCC returns `errAEEventNotPermitted` when the owner declines the
    /// "VoiceKey wants to control Music" prompt, or has the switch off in
    /// System Settings.
    private static let errAEEventNotPermitted = -1743

    /// Compiled scripts, kept because compilation resolves the player's
    /// terminology from its `.sdef` and a channel opens many times a day.
    private var scripts: [String: NSAppleScript] = [:]

    func isRunning(_ player: MediaPlayer) -> Bool {
        // The load-bearing launch guard, and the reason it is here rather than
        // in AppleScript: this reads the process list and sends nothing. Every
        // script below is additionally wrapped in `if application "X" is
        // running`, but that is the belt to this brace — by the time a script
        // is compiled at all, the player is known to be up.
        NSRunningApplication
            .runningApplications(withBundleIdentifier: player.bundleID)
            .isEmpty == false
    }

    func state(
        of player: MediaPlayer
    ) -> Result<MediaPlayerState, MediaScriptingFailure> {
        run(
            source: Self.stateSource(for: player),
            cacheKey: "\(player.name).state"
        )
        .map { descriptor in
            // Anything that is not one of the two states worth acting on —
            // including "notrunning", and Music's `fast forwarding` /
            // `rewinding` — is treated as stopped, which is the answer that
            // pauses nothing and resumes nothing.
            switch descriptor.stringValue {
            case "playing":
                return .playing
            case "paused":
                return .paused
            default:
                return .stopped
            }
        }
    }

    func pause(
        _ player: MediaPlayer
    ) -> Result<Void, MediaScriptingFailure> {
        run(
            source: Self.transportSource(for: player, command: "pause"),
            cacheKey: "\(player.name).pause"
        )
        .map { _ in () }
    }

    func play(
        _ player: MediaPlayer
    ) -> Result<Void, MediaScriptingFailure> {
        // `play`, never `playpause`. Both players define `playpause` and it is
        // a toggle: sent to a stopped player it starts music nobody asked for.
        // The controller only reaches here for a player it paused that is
        // still paused.
        run(
            source: Self.transportSource(for: player, command: "play"),
            cacheKey: "\(player.name).play"
        )
        .map { _ in () }
    }

    // MARK: - Script text

    /// Verified 2026-07-29 to compile against the real terminology of both
    /// players (`scripts/dev/probe-media-scripting.swift`). Deliberately does
    /// not coerce `player state` to text: it compares against the enumerators
    /// instead, which both players define identically as `ePlS`.
    /// Apple Events default to a 60-second timeout, and a real one was observed
    /// on 2026-07-29: with the Mac locked, the automation-consent prompt could
    /// not be shown, so the event sat for a full minute before returning -1712.
    /// It did not block the voice session — that work is on its own queue — but
    /// it did occupy the queue the resume has to come back through. Two seconds
    /// is longer than a healthy player needs and short enough that a wedged one
    /// cannot hold the music hostage.
    static let appleEventTimeoutSeconds = 2

    static func stateSource(for player: MediaPlayer) -> String {
        """
        if application "\(player.name)" is running then
            with timeout of \(appleEventTimeoutSeconds) seconds
                tell application "\(player.name)"
                    set currentState to player state
                    if currentState is playing then return "playing"
                    if currentState is paused then return "paused"
                    return "stopped"
                end tell
            end timeout
        end if
        return "notrunning"
        """
    }

    /// The `if … is running` wrapper is what keeps a `tell` from launching the
    /// player. Testing `is running` does not launch it; a bare `tell` does.
    static func transportSource(
        for player: MediaPlayer,
        command: String
    ) -> String {
        """
        if application "\(player.name)" is running then
            with timeout of \(appleEventTimeoutSeconds) seconds
                tell application "\(player.name)" to \(command)
            end timeout
        end if
        return "ok"
        """
    }

    // MARK: - Execution

    private func run(
        source: String,
        cacheKey: String
    ) -> Result<NSAppleEventDescriptor, MediaScriptingFailure> {
        guard let script = self.script(source: source, cacheKey: cacheKey) else {
            return .failure(.scriptingError(code: 0))
        }
        var errorInfo: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            return .failure(Self.failure(from: errorInfo))
        }
        return .success(descriptor)
    }

    private func script(
        source: String,
        cacheKey: String
    ) -> NSAppleScript? {
        if let cached = scripts[cacheKey] {
            return cached
        }
        guard let script = NSAppleScript(source: source) else {
            return nil
        }
        scripts[cacheKey] = script
        return script
    }

    /// Reduces an `NSAppleScript` error dictionary to a number.
    ///
    /// The dictionary's `NSAppleScriptErrorMessage` is discarded here and never
    /// reaches a caller. It is the player's own sentence about the player's own
    /// state, it can quote what is loaded, and the session log is written to be
    /// pasteable into a public bug report.
    static func failure(from errorInfo: NSDictionary) -> MediaScriptingFailure {
        let code = (errorInfo[NSAppleScript.errorNumber] as? NSNumber)?
            .intValue ?? 0
        if code == errAEEventNotPermitted {
            return .permissionDenied
        }
        return .scriptingError(code: code)
    }
}
