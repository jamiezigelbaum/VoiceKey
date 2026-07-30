@testable import VoiceKey
import XCTest

/// The owner's ruling (2026-07-30): no user-visible instructions by default
/// for anyone, and whatever the app itself needs the model to know stays
/// hidden and unstored. These cover the two halves — the one-shot clear of
/// the retired stored default, and the app-owned preamble.
final class RetiredDefaultInstructionsMigrationTests: XCTestCase {
    private let profilesKey = "VoiceProfiles.v1"

    func testClearRemovesTheRetiredDefaultFromAStoredProfile() throws {
        let defaults = makeTestDefaults()
        VoiceProfileStore.save(
            [makeProfile(instructions: VoiceProfileStore.retiredDefaultInstructions)],
            defaults: defaults
        )

        VoiceProfileStore.clearRetiredDefaultInstructions(defaults: defaults)

        let profile = try XCTUnwrap(VoiceProfileStore.load(defaults: defaults).first)
        XCTAssertEqual(profile.instructions, "")
    }

    func testClearPreservesEverythingTheOwnerActuallyWrote() throws {
        let defaults = makeTestDefaults()
        let authored = "Always answer in French."
        // The retired text plus the user's own lines is proof of intent: the
        // whole value has to survive, not just the appended part.
        let extended =
            VoiceProfileStore.retiredDefaultInstructions
            + "\n\nAlways answer in French."
        VoiceProfileStore.save(
            [
                makeProfile(name: "Authored", instructions: authored),
                makeProfile(name: "Extended", instructions: extended),
                makeProfile(name: "Empty", instructions: "")
            ],
            defaults: defaults
        )

        VoiceProfileStore.clearRetiredDefaultInstructions(defaults: defaults)

        let profiles = VoiceProfileStore.load(defaults: defaults)
        XCTAssertEqual(instructions(named: "Authored", in: profiles), authored)
        XCTAssertEqual(instructions(named: "Extended", in: profiles), extended)
        XCTAssertEqual(instructions(named: "Empty", in: profiles), "")
    }

    func testClearMatchesTheRetiredDefaultThroughSurroundingWhitespace() throws {
        // v0.2.0 stored the text view's string untrimmed, so a stale value can
        // carry leading and trailing whitespace.
        let defaults = makeTestDefaults()
        VoiceProfileStore.save(
            [
                makeProfile(
                    instructions:
                        "\n  " + VoiceProfileStore.retiredDefaultInstructions + "  \n"
                )
            ],
            defaults: defaults
        )

        VoiceProfileStore.clearRetiredDefaultInstructions(defaults: defaults)

        let profile = try XCTUnwrap(VoiceProfileStore.load(defaults: defaults).first)
        XCTAssertEqual(profile.instructions, "")
    }

    func testClearRunsExactlyOnceSoLaterTypingOfThatTextSurvives() throws {
        let defaults = makeTestDefaults()
        VoiceProfileStore.save([makeProfile(instructions: "")], defaults: defaults)

        VoiceProfileStore.clearRetiredDefaultInstructions(defaults: defaults)

        // Someone who deliberately types the old wording afterwards keeps it
        // forever — the pass already ran, marker and all.
        var profiles = VoiceProfileStore.load(defaults: defaults)
        profiles[0].instructions = VoiceProfileStore.retiredDefaultInstructions
        VoiceProfileStore.save(profiles, defaults: defaults)

        VoiceProfileStore.clearRetiredDefaultInstructions(defaults: defaults)

        let profile = try XCTUnwrap(VoiceProfileStore.load(defaults: defaults).first)
        XCTAssertEqual(
            profile.instructions,
            VoiceProfileStore.retiredDefaultInstructions
        )
    }

    func testClearKeepsEveryOtherFieldOfATouchedProfileIntact() throws {
        let defaults = makeTestDefaults()
        let original = VoiceProfile(
            name: "OpenAI",
            providerID: .openAIRealtime,
            hotKey: .defaultVoiceToggle,
            model: "gpt-realtime-2",
            voice: "marin",
            instructions: VoiceProfileStore.retiredDefaultInstructions,
            endpointURL: "wss://example.test/v1/realtime",
            mcpServers: [
                MCPServerConfiguration(
                    label: "calendar",
                    urlString: "https://mcp.example.com/calendar",
                    allowedTools: ["search_events"]
                )
            ],
            webSearchEnabled: false,
            speakerModePreference: .alwaysOn
        )
        VoiceProfileStore.save([original], defaults: defaults)

        VoiceProfileStore.clearRetiredDefaultInstructions(defaults: defaults)

        var expected = original
        expected.instructions = ""
        XCTAssertEqual(VoiceProfileStore.load(defaults: defaults), [expected])
    }

    func testClearNeverWritesAProfileBlobOnAFreshInstall() {
        let defaults = makeTestDefaults()

        VoiceProfileStore.clearRetiredDefaultInstructions(defaults: defaults)

        // Writing here would suppress the first-run setup assistant.
        XCTAssertNil(defaults.object(forKey: profilesKey))
        XCTAssertTrue(VoiceProfileStore.isFreshInstall(defaults: defaults))
    }

    func testRetiredDefaultInLegacyKeysDoesNotBecomeAProfileInstruction() throws {
        // Pre-0.2.0 builds wrote the whole configuration — the then-default
        // instructions included — into the legacy key.
        let defaults = makeTestDefaults()
        defaults.set(
            VoiceProviderID.openAIRealtime.rawValue,
            forKey: "VoiceProvider.providerID"
        )
        defaults.set(
            VoiceProfileStore.retiredDefaultInstructions,
            forKey: "VoiceProvider.instructions"
        )

        let profile = try XCTUnwrap(VoiceProfileStore.load(defaults: defaults).first)

        XCTAssertEqual(profile.instructions, "")
        // Legacy keys stay in place so a downgrade still finds them.
        XCTAssertNotNil(defaults.object(forKey: "VoiceProvider.instructions"))
    }

    func testAuthoredLegacyInstructionsStillMigrate() throws {
        let defaults = makeTestDefaults()
        defaults.set(
            VoiceProviderID.openAIRealtime.rawValue,
            forKey: "VoiceProvider.providerID"
        )
        defaults.set("Be brief.", forKey: "VoiceProvider.instructions")

        let profile = try XCTUnwrap(VoiceProfileStore.load(defaults: defaults).first)

        XCTAssertEqual(profile.instructions, "Be brief.")
    }

    func testRetiredDefaultTextExistsNowhereInTheAppsOwnDefaults() {
        // Nothing may re-seed it: not the session default, not a new channel,
        // not the onboarding wizard's channel.
        XCTAssertEqual(VoiceSessionConfiguration.defaultInstructions, "")
        XCTAssertEqual(VoiceProfile.defaultOpenAI().instructions, "")
        XCTAssertEqual(
            VoiceChannelOperations.makeChannel(
                provider: .openAIRealtime,
                existingNames: []
            ).instructions,
            ""
        )
        for provider in VoiceProviderID.allCases {
            XCTAssertEqual(provider.defaultConfiguration.instructions, "")
        }
    }

    private func makeProfile(
        name: String = "OpenAI",
        instructions: String
    ) -> VoiceProfile {
        VoiceProfile(
            name: name,
            providerID: .openAIRealtime,
            hotKey: nil,
            model: "gpt-realtime-2",
            voice: "marin",
            instructions: instructions
        )
    }

    private func instructions(
        named name: String,
        in profiles: [VoiceProfile]
    ) -> String? {
        profiles.first(where: { $0.name == name })?.instructions
    }
}

/// The hidden operational preamble: app-owned, never stored, never shown.
final class HiddenOperationalPreambleTests: XCTestCase {
    func testSearchNudgeIsPresentWhenTheSearchToolIsDeclared() throws {
        var configuration = makeConfiguration(instructions: "")
        configuration.webSearchEnabled = true

        let session = try session(for: configuration)
        let instructions = try XCTUnwrap(session["instructions"] as? String)

        XCTAssertTrue(instructions.contains("search_web"))
        let tools = try XCTUnwrap(session["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.first?["name"] as? String, "search_web")
    }

    func testSearchNudgeIsAbsentWhenSearchIsOff() throws {
        var configuration = makeConfiguration(instructions: "")
        configuration.webSearchEnabled = false

        let session = try session(for: configuration)
        let instructions = try XCTUnwrap(session["instructions"] as? String)

        XCTAssertFalse(instructions.contains("search_web"))
        XCTAssertNil(session["tools"])
    }

    func testSearchNudgeIsAbsentForProvidersThatNeverGetTheTool() throws {
        // A custom endpoint never has the tool declared, so telling its model
        // the tool exists would be a lie.
        var configuration = makeConfiguration(instructions: "")
        configuration.providerID = .custom
        configuration.webSearchEnabled = true

        let session = try session(for: configuration)
        let instructions = try XCTUnwrap(session["instructions"] as? String)

        XCTAssertFalse(instructions.contains("search_web"))
        XCTAssertNil(session["tools"])
    }

    func testPreambleComposesAheadOfTheUsersOwnInstructions() throws {
        var configuration = makeConfiguration(instructions: "Always answer in French.")
        configuration.webSearchEnabled = true

        let session = try session(for: configuration)
        let instructions = try XCTUnwrap(session["instructions"] as? String)
        let parts = instructions.components(separatedBy: "\n\n")

        XCTAssertEqual(parts.count, 3)
        XCTAssertTrue(parts[0].contains("search_web"))
        XCTAssertEqual(parts[1], "Always answer in French.")
        XCTAssertTrue(parts[2].hasPrefix("Session started"))
    }

    func testAChannelWithNoInstructionsStillSendsASensibleSession() throws {
        var configuration = makeConfiguration(instructions: "")
        configuration.webSearchEnabled = false

        let session = try session(for: configuration)
        let instructions = try XCTUnwrap(session["instructions"] as? String)
        let parts = instructions.components(separatedBy: "\n\n")

        // Brevity, then the clock stamp. Brevity is about the medium — a spoken
        // paragraph cannot be skimmed — so it applies with or without a search
        // tool. Still no identity and no persona.
        XCTAssertEqual(parts.count, 2)
        XCTAssertTrue(parts[0].contains("one or two short sentences"))
        XCTAssertFalse(parts[0].contains("search_web"), "no tool is declared")
        XCTAssertTrue(parts[1].hasPrefix("Session started"))
        XCTAssertFalse(instructions.lowercased().contains("voicekey"))
        XCTAssertFalse(instructions.lowercased().contains("assistant"))
    }

    /// Brevity is not conditional on the search tool: a channel with search off
    /// is still a voice channel.
    func testBrevityAppliesWhetherOrNotSearchIsAvailable() throws {
        for searchEnabled in [true, false] {
            var configuration = makeConfiguration(instructions: "")
            configuration.webSearchEnabled = searchEnabled
            let session = try session(for: configuration)
            let instructions = try XCTUnwrap(session["instructions"] as? String)
            XCTAssertTrue(
                instructions.contains("one or two short sentences"),
                "brevity missing with webSearchEnabled=\(searchEnabled)"
            )
        }
    }

    func testPreambleIsNeverPersistedIntoAProfile() {
        let defaults = makeTestDefaults()
        var profile = VoiceProfile.defaultOpenAI()
        profile.webSearchEnabled = true
        VoiceProfileStore.save([profile], defaults: defaults)

        let reloaded = VoiceProfileStore.load(defaults: defaults)

        XCTAssertEqual(reloaded.first?.instructions, "")
    }

    private func makeConfiguration(instructions: String) -> VoiceSessionConfiguration {
        VoiceSessionConfiguration(
            providerID: .openAIRealtime,
            model: "gpt-realtime-2-test",
            voice: "marin-test",
            instructions: instructions
        )
    }

    private func session(
        for configuration: VoiceSessionConfiguration
    ) throws -> [String: Any] {
        let event = OpenAIRealtimeRequestBuilder.sessionUpdateEvent(
            configuration: configuration,
            authorizationProvider: { _ in nil }
        )
        return try XCTUnwrap(event["session"] as? [String: Any])
    }
}

/// The migration runs once per install and never gets a second chance. Its call
/// site used to be top-level code in main.swift, which no test can execute — so
/// a later refactor of the entry point could drop it with every test still
/// green, and every upgraded user would keep the retired instructions forever.
final class VoiceKeyBootstrapTests: XCTestCase {
    func testBootstrapClearsTheRetiredDefaultInstructions() throws {
        let defaults = makeTestDefaults()
        var profile = VoiceProfile.defaultOpenAI()
        profile.instructions = VoiceProfileStore.retiredDefaultInstructions
        VoiceProfileStore.save([profile], defaults: defaults)

        VoiceKeyBootstrap.run(defaults: defaults)

        let loaded = try XCTUnwrap(VoiceProfileStore.load(defaults: defaults).first)
        XCTAssertEqual(loaded.instructions, "")
    }

    func testBootstrapLeavesInstructionsTheOwnerWroteAlone() throws {
        let defaults = makeTestDefaults()
        var profile = VoiceProfile.defaultOpenAI()
        profile.instructions = "Always answer in French."
        VoiceProfileStore.save([profile], defaults: defaults)

        VoiceKeyBootstrap.run(defaults: defaults)

        let loaded = try XCTUnwrap(VoiceProfileStore.load(defaults: defaults).first)
        XCTAssertEqual(loaded.instructions, "Always answer in French.")
    }
}
