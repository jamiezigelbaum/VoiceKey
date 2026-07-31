import Foundation

struct MCPServerConfiguration: Codable, Equatable, Identifiable {
    var id: UUID
    var label: String
    var urlString: String
    var allowedTools: [String]?

    init(
        id: UUID = UUID(),
        label: String,
        urlString: String,
        allowedTools: [String]? = nil
    ) {
        self.id = id
        self.label = label
        self.urlString = urlString
        self.allowedTools = allowedTools
    }
}

struct VoiceProfile: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var providerID: VoiceProviderID
    var hotKey: HotKeyConfiguration?
    var model: String
    var voice: String
    var instructions: String
    var endpointURL: String
    var mcpServers: [MCPServerConfiguration]
    var webSearchEnabled: Bool
    var speakerModePreference: OpenAISpeakerModePreference

    init(
        id: UUID = UUID(),
        name: String,
        providerID: VoiceProviderID,
        hotKey: HotKeyConfiguration? = nil,
        model: String,
        voice: String,
        instructions: String = "",
        endpointURL: String = "",
        mcpServers: [MCPServerConfiguration] = [],
        webSearchEnabled: Bool? = nil,
        speakerModePreference: OpenAISpeakerModePreference = .automatic
    ) {
        self.id = id
        self.name = name
        self.providerID = providerID
        self.hotKey = hotKey
        self.model = model
        self.voice = voice
        self.instructions = instructions
        self.endpointURL = endpointURL
        self.mcpServers = mcpServers
        self.webSearchEnabled =
            webSearchEnabled ?? (providerID == .openAIRealtime)
        self.speakerModePreference = speakerModePreference
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case providerID
        case hotKey
        case model
        case voice
        case instructions
        case endpointURL
        case mcpServers
        case webSearchEnabled
        case speakerModePreference
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        providerID = try container.decode(VoiceProviderID.self, forKey: .providerID)
        hotKey = try container.decodeIfPresent(HotKeyConfiguration.self, forKey: .hotKey)
        model = try container.decode(String.self, forKey: .model)
        voice = try container.decode(String.self, forKey: .voice)
        instructions = try container.decode(String.self, forKey: .instructions)
        endpointURL = try container.decode(String.self, forKey: .endpointURL)
        mcpServers = try container.decodeIfPresent(
            [MCPServerConfiguration].self,
            forKey: .mcpServers
        ) ?? []
        webSearchEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .webSearchEnabled
        ) ?? (providerID == .openAIRealtime)
        speakerModePreference = try container.decodeIfPresent(
            OpenAISpeakerModePreference.self,
            forKey: .speakerModePreference
        ) ?? .automatic
    }

    static func defaultOpenAI(name: String = "OpenAI") -> VoiceProfile {
        let provider = VoiceProviderID.openAIRealtime
        return VoiceProfile(
            name: name,
            providerID: provider,
            hotKey: .defaultVoiceToggle,
            model: provider.defaultModel,
            voice: provider.defaultVoice,
            instructions: VoiceSessionConfiguration.defaultInstructions,
            endpointURL: ""
        )
    }
}

enum VoiceProfileStore {
    private static let profilesKey = "VoiceProfiles.v1"

    private static let legacyHotKeyKeys = [
        "VoiceHotKey.keyCode",
        "VoiceHotKey.carbonModifiers",
        "VoiceHotKey.menuKeyEquivalent",
        "VoiceHotKey.menuModifierMask",
        "VoiceHotKey.displayName",
        "VoiceHotKey.mainKeyDisplayName"
    ]
    private static let legacyProviderIDKey = "VoiceProvider.providerID"
    private static let legacyModelKey = "VoiceProvider.model"
    private static let legacyVoiceKey = "VoiceProvider.voice"
    private static let legacyInstructionsKey = "VoiceProvider.instructions"

    /// A tombstone, not a default. This exact text shipped as
    /// `VoiceSessionConfiguration.defaultInstructions` from the first realtime
    /// build through v0.2.0 and was emptied in commit 10b80cb (v0.2.1). It
    /// exists nowhere else in the tree, so the one-shot clear below has to
    /// re-declare it to recognise the residue those builds left in profiles.
    static let retiredDefaultInstructions = "You are VoiceKey, a concise and helpful voice assistant. Speak naturally and keep answers brief unless the user asks for detail."

    private static let retiredDefaultInstructionsClearedKey =
        "VoiceProfiles.retiredDefaultInstructionsCleared.v1"

    /// Clears the retired default out of stored profiles, once per install.
    ///
    /// Call this before anything reads profiles. It is deliberately a one-shot
    /// gated on its own marker key: a stored value is indistinguishable from a
    /// user who typed that exact text, so the only safe contract is "clear on
    /// the first launch of the build that carries this, never again". Matching
    /// is full-string equality on the trimmed value — someone who kept the old
    /// wording and appended their own lines has proven intent and is left
    /// alone.
    static func clearRetiredDefaultInstructions(
        defaults: UserDefaults = .standard
    ) {
        guard defaults.bool(forKey: retiredDefaultInstructionsClearedKey) == false
        else { return }

        // No blob means a fresh install. Writing one here would flip
        // `isFreshInstall` and swallow the first-run setup assistant.
        if let data = defaults.data(forKey: profilesKey) {
            guard var profiles = try? JSONDecoder().decode(
                [VoiceProfile].self,
                from: data
            ) else {
                // Undecodable today may be decodable after an upgrade; leave
                // the marker unset so a later launch retries.
                return
            }

            var changed = false
            for index in profiles.indices
            where profiles[index].instructions
                .trimmingCharacters(in: .whitespacesAndNewlines)
                == retiredDefaultInstructions {
                profiles[index].instructions = ""
                changed = true
            }

            if changed {
                // `instructions` is a required decode key, so a half-written
                // blob would reset every channel, hotkey and MCP server.
                // Encode first; write only once that succeeded.
                guard let encoded = try? JSONEncoder().encode(profiles) else {
                    return
                }
                defaults.set(encoded, forKey: profilesKey)
            }
        }

        defaults.set(true, forKey: retiredDefaultInstructionsClearedKey)
    }

    static func load(defaults: UserDefaults = .standard) -> [VoiceProfile] {
        if let data = defaults.data(forKey: profilesKey),
           let profiles = try? JSONDecoder().decode([VoiceProfile].self, from: data) {
            return sortedByHotKey(profiles)
        }

        if hasLegacySettings(defaults: defaults) {
            return [migrateLegacyProfile(defaults: defaults)]
        }

        return [freshInstallProfile()]
    }

    static func save(_ profiles: [VoiceProfile], defaults: UserDefaults = .standard) {
        let normalized = normalizedForPersistence(profiles)
        guard let data = try? JSONEncoder().encode(
            sortedByHotKey(normalized)
        ) else { return }
        defaults.set(data, forKey: profilesKey)
    }

    static func normalizedForPersistence(
        _ profiles: [VoiceProfile]
    ) -> [VoiceProfile] {
        profiles
    }

    /// Canonical channel order everywhere (menu, channel picker): by hotkey
    /// — F16 before F17 before F18 — with unassigned-hotkey channels last.
    /// Stable for ties so duplicates keep their relative position.
    static func sortedByHotKey(_ profiles: [VoiceProfile]) -> [VoiceProfile] {
        profiles.enumerated().sorted { lhs, rhs in
            let l = lhs.element.hotKey?.sortRank ?? (2, 0, "")
            let r = rhs.element.hotKey?.sortRank ?? (2, 0, "")
            if l == r { return lhs.offset < rhs.offset }
            return l < r
        }.map(\.element)
    }

    static func isFreshInstall(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: profilesKey) == nil && !hasLegacySettings(defaults: defaults)
    }

    private static func hasLegacySettings(defaults: UserDefaults) -> Bool {
        let providerKeys = [
            legacyProviderIDKey,
            legacyModelKey,
            legacyVoiceKey,
            legacyInstructionsKey
        ]
        return (legacyHotKeyKeys + providerKeys).contains { defaults.object(forKey: $0) != nil }
    }

    private static func migrateLegacyProfile(defaults: UserDefaults) -> VoiceProfile {
        let provider = defaults.string(forKey: legacyProviderIDKey)
            .flatMap { VoiceProviderID(rawValue: $0) } ?? .openAIRealtime

        let model = defaults.string(forKey: legacyModelKey)
            .flatMap { $0.isEmpty ? nil : $0 } ?? provider.defaultModel
        let voice = defaults.string(forKey: legacyVoiceKey)
            .flatMap { $0.isEmpty ? nil : $0 } ?? provider.defaultVoice
        // Pre-0.2.0 wrote the whole configuration to these keys, the then-
        // default instructions included, so a legacy value equal to the
        // retired text is the app's own residue rather than user intent.
        let legacyInstructions = defaults.string(forKey: legacyInstructionsKey) ?? ""
        let instructions =
            legacyInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
                == retiredDefaultInstructions
            ? VoiceSessionConfiguration.defaultInstructions
            : legacyInstructions

        return VoiceProfile(
            name: provider.displayName,
            providerID: provider,
            hotKey: HotKeyConfiguration.loadVoiceToggle(defaults: defaults),
            model: model,
            voice: voice,
            instructions: instructions,
            endpointURL: ""
        )
    }

    private static func freshInstallProfile() -> VoiceProfile {
        var profile = VoiceProfile.defaultOpenAI()
        profile.hotKey = nil
        return profile
    }
}
