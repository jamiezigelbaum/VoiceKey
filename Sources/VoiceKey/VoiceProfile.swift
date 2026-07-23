import Foundation

struct VoiceProfile: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var providerID: VoiceProviderID
    var hotKey: HotKeyConfiguration?
    var model: String
    var voice: String
    var instructions: String
    var endpointURL: String

    init(
        id: UUID = UUID(),
        name: String,
        providerID: VoiceProviderID,
        hotKey: HotKeyConfiguration? = nil,
        model: String,
        voice: String,
        instructions: String = "",
        endpointURL: String = ""
    ) {
        self.id = id
        self.name = name
        self.providerID = providerID
        self.hotKey = hotKey
        self.model = model
        self.voice = voice
        self.instructions = instructions
        self.endpointURL = endpointURL
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

    static func load(defaults: UserDefaults = .standard) -> [VoiceProfile] {
        if let data = defaults.data(forKey: profilesKey),
           let profiles = try? JSONDecoder().decode([VoiceProfile].self, from: data) {
            return profiles
        }

        if hasLegacySettings(defaults: defaults) {
            return [migrateLegacyProfile(defaults: defaults)]
        }

        return [freshInstallProfile()]
    }

    static func save(_ profiles: [VoiceProfile], defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        defaults.set(data, forKey: profilesKey)
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
        let instructions = defaults.string(forKey: legacyInstructionsKey)
            .flatMap { $0.isEmpty ? nil : $0 } ?? VoiceSessionConfiguration.defaultInstructions

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
        let provider = VoiceProviderID.openAIRealtime
        return VoiceProfile(
            name: "OpenAI",
            providerID: provider,
            hotKey: .defaultVoiceToggle,
            model: provider.defaultModel,
            voice: provider.defaultVoice,
            instructions: "",
            endpointURL: ""
        )
    }
}
