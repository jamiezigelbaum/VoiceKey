@testable import VoiceKey
import XCTest

/// Nothing here executes a script. Every test reads the text VoiceKey would
/// send, or maps an error dictionary — no Apple Event leaves this process.
final class AppleScriptMediaPlayerScriptingTests: XCTestCase {

    // MARK: - No script may be able to launch a player

    func testEverySourceGuardsItsTellWithARunningCheck() {
        for player in MediaPlayer.all {
            let sources = [
                AppleScriptMediaPlayerScripting.stateSource(for: player),
                AppleScriptMediaPlayerScripting.transportSource(
                    for: player,
                    command: "pause"
                ),
                AppleScriptMediaPlayerScripting.transportSource(
                    for: player,
                    command: "play"
                )
            ]
            for source in sources {
                let guardClause =
                    "if application \"\(player.name)\" is running then"
                guard let guardIndex = source.range(of: guardClause) else {
                    XCTFail(
                        "no running guard in the script for \(player.name):"
                        + "\n\(source)"
                    )
                    continue
                }
                guard let tellIndex = source.range(of: "tell application") else {
                    XCTFail("no tell at all in: \n\(source)")
                    continue
                }
                XCTAssertTrue(
                    guardIndex.lowerBound < tellIndex.lowerBound,
                    "a tell reached before the running guard launches "
                    + "\(player.name):\n\(source)"
                )
            }
        }
    }

    func testNoSourceSendsTheBarePlayPauseToggle() {
        for player in MediaPlayer.all {
            let sources = [
                AppleScriptMediaPlayerScripting.stateSource(for: player),
                AppleScriptMediaPlayerScripting.transportSource(
                    for: player,
                    command: "pause"
                ),
                AppleScriptMediaPlayerScripting.transportSource(
                    for: player,
                    command: "play"
                )
            ]
            for source in sources {
                XCTAssertFalse(
                    source.contains("playpause"),
                    "playpause is a toggle: sent to a stopped player it starts "
                    + "music because a voice channel opened"
                )
            }
        }
    }

    func testStateSourceReadsPlayerStateWithoutCoercingIt() {
        let source = AppleScriptMediaPlayerScripting.stateSource(for: .music)
        let terminationSource =
            AppleScriptMediaPlayerScripting.stateSource(
                for: .music,
                timeoutSeconds: AppleScriptMediaPlayerScripting
                    .terminationAppleEventTimeoutSeconds
            )

        XCTAssertTrue(source.contains("set currentState to player state"))
        XCTAssertTrue(source.contains("if currentState is playing"))
        XCTAssertTrue(source.contains("if currentState is paused"))
        XCTAssertTrue(
            terminationSource.contains("with timeout of 1 seconds"),
            "termination inherited the consent-capable 30-second timeout"
        )
        XCTAssertFalse(
            source.contains("as text"),
            "coercing the ePlS enumeration is the part that differs between "
            + "players; comparing against the enumerators does not"
        )
    }

    // MARK: - isRunning sends nothing and cannot launch

    func testIsRunningIsFalseForAPlayerThatCannotBeRunning() {
        let scripting = AppleScriptMediaPlayerScripting()
        let absent = MediaPlayer(
            name: "VoiceKeyNoSuchPlayer",
            bundleID: "com.zigelbaum.VoiceKeyNoSuchPlayer"
        )

        XCTAssertFalse(scripting.isRunning(absent))
    }

    // MARK: - What an error is allowed to become

    func testPermissionDenialIsRecognisedByItsOSStatus() {
        let errorInfo: NSDictionary = [
            NSAppleScript.errorNumber: NSNumber(value: -1743),
            NSAppleScript.errorMessage:
                "Not authorized to send Apple events to Music."
        ]

        XCTAssertEqual(
            AppleScriptMediaPlayerScripting.failure(from: errorInfo),
            .permissionDenied
        )
    }

    func testOtherErrorsKeepOnlyTheirNumber() {
        let errorInfo: NSDictionary = [
            NSAppleScript.errorNumber: NSNumber(value: -1728),
            NSAppleScript.errorMessage: "Can’t get player state."
        ]

        XCTAssertEqual(
            AppleScriptMediaPlayerScripting.failure(from: errorInfo),
            .scriptingError(code: -1728)
        )
    }

    /// The decisive privacy gate. An `NSAppleScript` error message is the
    /// player's own sentence about the player's own state, and it can quote
    /// what is loaded. The failure type has to be incapable of carrying it.
    func testAnErrorMessageCannotSurviveIntoAFailure() {
        let listening = "Kind of Blue — Miles Davis"
        let errorInfo: NSDictionary = [
            NSAppleScript.errorNumber: NSNumber(value: -1719),
            NSAppleScript.errorMessage:
                "Can’t get track \"\(listening)\" of application \"Music\"."
        ]

        let failure = AppleScriptMediaPlayerScripting.failure(from: errorInfo)

        XCTAssertFalse(
            "\(failure)".contains(listening),
            "the player's error prose reached the failure the log is built from"
        )
        XCTAssertEqual(failure, .scriptingError(code: -1719))
    }

    func testAnErrorWithNoNumberStillProducesAFailure() {
        XCTAssertEqual(
            AppleScriptMediaPlayerScripting.failure(from: [:]),
            .scriptingError(code: 0)
        )
    }
}

/// The v0.2.0/v0.2.1 microphone bug in a sentence: the hardened runtime refused
/// a capability, silently, because a key was missing from a file nothing
/// checked. Apple Events are the same shape of trap, so this is the check.
final class AutomationEntitlementGateTests: XCTestCase {
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // VoiceKeyTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repository root
    }

    func testEntitlementsGrantAppleEvents() throws {
        let url = Self.repositoryRoot
            .appendingPathComponent("VoiceKey.entitlements")
        let entitlements = try plist(at: url)

        XCTAssertEqual(
            entitlements["com.apple.security.automation.apple-events"]
                as? Bool,
            true,
            """
            Without this the hardened runtime refuses every Apple Event and \
            pausing the owner's music does nothing on a notarized build — no \
            prompt, no error, no log line.
            """
        )
    }

    func testInfoPlistExplainsWhyVoiceKeyControlsOtherApps() throws {
        let url = Self.repositoryRoot.appendingPathComponent("Info.plist")
        let info = try plist(at: url)

        let usage = info["NSAppleEventsUsageDescription"] as? String
        XCTAssertNotNil(
            usage,
            """
            macOS will not even show the "VoiceKey wants to control Music" \
            prompt without this string, so the permission can never be granted.
            """
        )
        XCTAssertFalse(
            usage?.isEmpty ?? true,
            "an empty usage string is the same failure with a key present"
        )
    }

    /// The microphone half, which is what taught us to write this file.
    func testTheMicrophoneEntitlementIsStillThere() throws {
        let url = Self.repositoryRoot
            .appendingPathComponent("VoiceKey.entitlements")
        let entitlements = try plist(at: url)

        XCTAssertEqual(
            entitlements["com.apple.security.device.audio-input"] as? Bool,
            true
        )
    }

    private func plist(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let parsed = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        )
        return try XCTUnwrap(parsed as? [String: Any])
    }
}
