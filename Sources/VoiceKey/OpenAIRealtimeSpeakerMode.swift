import Foundation

enum OpenAISpeakerModePreference: String, Codable, CaseIterable {
    case automatic
    case alwaysOn
    case off

    var displayName: String {
        switch self {
        case .automatic:
            return "Auto"
        case .alwaysOn:
            return "Always on"
        case .off:
            return "Off"
        }
    }
}

enum RealtimeAudioOutputTransport: Equatable {
    case builtIn
    case bluetooth
    case bluetoothLE
    case displayPort
    case hdmi
    case usb
    case airPlay
    case virtual
    case other
}

enum RealtimeAudioOutputDataSource: Equatable {
    case headphones
    case other
}

struct RealtimeAudioOutputRoute: Equatable {
    var transport: RealtimeAudioOutputTransport
    var dataSource: RealtimeAudioOutputDataSource

    static let unknown = RealtimeAudioOutputRoute(
        transport: .other,
        dataSource: .other
    )

    static let headphones = RealtimeAudioOutputRoute(
        transport: .bluetooth,
        dataSource: .other
    )

    var usesOpenSpeakersByDefault: Bool {
        switch transport {
        case .bluetooth, .bluetoothLE:
            return false
        case .builtIn:
            return dataSource != .headphones
        case .displayPort, .hdmi, .usb, .airPlay, .virtual, .other:
            // USB is deliberately included here: a Studio Display and a USB
            // headset are indistinguishable by transport, so Auto chooses the
            // echo-safe behavior and the user override handles headsets.
            return true
        }
    }
}

enum OpenAIRealtimeSpeakerModePolicy {
    static func isSpeakerMode(
        route: RealtimeAudioOutputRoute,
        preference: OpenAISpeakerModePreference,
        isEchoCancellationActive: Bool
    ) -> Bool {
        // A rebuild can leave voice processing inactive. The live audit found
        // that this previously streamed raw echo silently, so safety overrides
        // even an explicit Off preference until AEC is restored.
        guard isEchoCancellationActive else { return true }

        switch preference {
        case .automatic:
            return route.usesOpenSpeakersByDefault
        case .alwaysOn:
            return true
        case .off:
            return false
        }
    }
}

/// Every WO-H tuning knob lives here so the energy gate and the exact server
/// VAD contract cannot drift independently.
enum OpenAIRealtimeSpeakerModeTuning {
    static let energyPeakThreshold: Float = 0.08
    static let consecutiveBufferCount = 3
    static let playbackHangoverMilliseconds = 1_000
    static let serverVADThreshold = 0.75
    static let serverVADPrefixPaddingMilliseconds = 300
    static let serverVADSilenceDurationMilliseconds = 700
}

struct OpenAIRealtimeSpeakerGate {
    private(set) var isSpeakerMode = false
    private(set) var isPlaybackActive = false
    private(set) var hasInterruptedCurrentTurn = false
    private var playbackEndedAt: Date?
    private var consecutiveLoudBufferCount = 0

    mutating func setSpeakerMode(_ isSpeakerMode: Bool) {
        self.isSpeakerMode = isSpeakerMode
        if isSpeakerMode == false {
            playbackEndedAt = nil
            consecutiveLoudBufferCount = 0
        }
    }

    mutating func updatePlayback(isActive: Bool, at date: Date) {
        if isPlaybackActive, isActive == false {
            playbackEndedAt = date
        } else if isActive {
            playbackEndedAt = nil
        }
        isPlaybackActive = isActive
        if isGateClosed(at: date) == false {
            consecutiveLoudBufferCount = 0
        }
    }

    mutating func beginAssistantTurn() {
        hasInterruptedCurrentTurn = false
        consecutiveLoudBufferCount = 0
    }

    mutating func resetActivity() {
        consecutiveLoudBufferCount = 0
    }

    func isGateClosed(at date: Date) -> Bool {
        guard isSpeakerMode, hasInterruptedCurrentTurn == false else {
            return false
        }
        if isPlaybackActive {
            return true
        }
        guard let playbackEndedAt else { return false }
        let hangover = TimeInterval(
            OpenAIRealtimeSpeakerModeTuning.playbackHangoverMilliseconds
        ) / 1_000
        return date.timeIntervalSince(playbackEndedAt) <= hangover
    }

    mutating func observe(_ activity: RealtimeAudioInputActivity, at date: Date) -> Bool {
        guard isGateClosed(at: date) else {
            consecutiveLoudBufferCount = 0
            return false
        }

        if activity.peak >= OpenAIRealtimeSpeakerModeTuning.energyPeakThreshold {
            consecutiveLoudBufferCount += 1
        } else {
            consecutiveLoudBufferCount = 0
        }

        let requiredBufferCount =
            OpenAIRealtimeSpeakerModeTuning.consecutiveBufferCount
        guard consecutiveLoudBufferCount >= requiredBufferCount else {
            return false
        }
        hasInterruptedCurrentTurn = true
        consecutiveLoudBufferCount = 0
        return true
    }
}
