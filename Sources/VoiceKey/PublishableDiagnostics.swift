import Foundation

/// The only endpoint representation allowed in persisted or pasteable
/// diagnostics. It keeps the network address useful while making user info,
/// query parameters and fragments impossible to recover from the value.
struct PublishableDiagnosticEndpoint: Equatable, CustomStringConvertible {
    private let value: String

    init(_ rawEndpoint: String) {
        let trimmed = rawEndpoint.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard trimmed.isEmpty == false else {
            value = "auto-discovery"
            return
        }
        guard var components = URLComponents(string: trimmed),
              components.host != nil else {
            value = "unparsable"
            return
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        value = components.string ?? "unparsable"
    }

    var description: String {
        value
    }
}

enum VoiceTranscriptRole: String, Equatable {
    case user
    case assistant
}

/// A non-revealing projection of one transcript delta. The raw text is
/// consumed to derive role and counts, then discarded.
struct PublishableTranscriptSummary: Equatable {
    var role: VoiceTranscriptRole
    var deltaCount: Int
    var characterCount: Int

    init?(delta: String) {
        guard delta.isEmpty == false else { return nil }
        if delta.hasPrefix("You: ") {
            role = .user
            characterCount = delta.dropFirst("You: ".count).count
        } else {
            role = .assistant
            characterCount = delta.count
        }
        deltaCount = 1
    }

    func appending(_ other: Self) -> Self? {
        guard role == other.role else { return nil }
        return Self(
            role: role,
            deltaCount: deltaCount + other.deltaCount,
            characterCount: characterCount + other.characterCount
        )
    }

    var text: String {
        "\(role.rawValue) turn occurred "
            + "(\(deltaCount) \(deltaNoun), "
            + "\(characterCount) \(characterNoun))"
    }

    private init(
        role: VoiceTranscriptRole,
        deltaCount: Int,
        characterCount: Int
    ) {
        self.role = role
        self.deltaCount = deltaCount
        self.characterCount = characterCount
    }

    private var deltaNoun: String {
        deltaCount == 1 ? "delta" : "deltas"
    }

    private var characterNoun: String {
        characterCount == 1 ? "character" : "characters"
    }
}
