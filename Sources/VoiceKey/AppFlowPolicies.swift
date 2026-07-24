import Foundation

extension ProviderStatus {
    var isLiveSessionStatus: Bool {
        switch self {
        case .starting, .listening, .thinking, .speaking,
             .clickSent, .voiceActive, .stopping:
            return true
        case .loading, .checking, .loginRequired, .ready,
             .needsAttention:
            return false
        }
    }
}

enum ProfileActivationFailure: Equatable {
    case missingHotKey
    case missingEndpoint
    case providerNotReady(String)

    var settingsMessage: String {
        switch self {
        case .missingHotKey:
            return "Record a global shortcut for this voice channel."
        case .missingEndpoint:
            return "Set the endpoint URL for this voice channel."
        case let .providerNotReady(message):
            return message
        }
    }
}

enum ProfileActivationPolicy {
    static func failure(
        for profile: VoiceProfile,
        hasAPIKey: Bool
    ) -> ProfileActivationFailure? {
        guard profile.hotKey != nil else {
            return .missingHotKey
        }
        if profile.providerID == .custom,
           profile.endpointURL.trimmingCharacters(
               in: .whitespacesAndNewlines
           ).isEmpty {
            return .missingEndpoint
        }
        let readiness = profile.providerID.readiness(
            hasAPIKey: hasAPIKey
        )
        guard readiness.allowsVoiceToggle else {
            return .providerNotReady(readiness.settingsMessage)
        }
        return nil
    }

    static func preservesGlobalStatus(
        requestedProfileID: UUID,
        activeProfileID: UUID?,
        currentStatus: ProviderStatus
    ) -> Bool {
        activeProfileID != nil
            && requestedProfileID != activeProfileID
            && currentStatus.isLiveSessionStatus
    }
}

struct AppOwnedAttentionState: Equatable {
    var profileID: UUID
    var failure: ProfileActivationFailure

    mutating func credentialDidChange(
        profile: VoiceProfile,
        hasAPIKey: Bool,
        currentStatus: ProviderStatus
    ) -> ProviderStatus? {
        guard profile.id == profileID else { return nil }
        if let nextFailure = ProfileActivationPolicy.failure(
            for: profile,
            hasAPIKey: hasAPIKey
        ) {
            failure = nextFailure
            return .needsAttention(nextFailure.settingsMessage)
        }
        guard case .needsAttention = currentStatus else { return nil }
        return .ready
    }
}

enum CredentialAttentionPolicy {
    static func profileAffectedByCredentialChange(
        attention: AppOwnedAttentionState?,
        changedProfile: VoiceProfile,
        profiles: [VoiceProfile]
    ) -> VoiceProfile? {
        guard let attention,
              let attentionProfile = profiles.first(where: {
                  $0.id == attention.profileID
              }) else {
            return nil
        }
        if attentionProfile.id == changedProfile.id {
            return attentionProfile
        }
        let provider = attentionProfile.providerID
        guard provider == changedProfile.providerID,
              provider == .openAIRealtime
                || provider == .openClaw else {
            return nil
        }
        return attentionProfile
    }

    static func reconcile(
        attention: inout AppOwnedAttentionState?,
        profile: VoiceProfile,
        hasAPIKey: Bool,
        currentStatus: ProviderStatus
    ) -> ProviderStatus? {
        guard var state = attention,
              let status = state.credentialDidChange(
                  profile: profile,
                  hasAPIKey: hasAPIKey,
                  currentStatus: currentStatus
              ) else {
            return nil
        }
        attention = status == .ready ? nil : state
        return status
    }
}

enum VoiceProfileMenuPolicy {
    static func isProfileItemEnabled(
        profileID: UUID,
        activeProfileID: UUID?,
        status: ProviderStatus
    ) -> Bool {
        // The active channel remains actionable during a wedged stop; the stop
        // watchdog provides the bounded recovery path.
        true
    }

    static func providerTargetsEnabled(hasProfiles: Bool) -> Bool {
        hasProfiles
    }
}

enum ProviderReplacementPolicy {
    static func requiresReplacement(
        current: VoiceSessionConfiguration,
        next: VoiceSessionConfiguration,
        currentProviderID: VoiceProviderID?
    ) -> Bool {
        guard currentProviderID == next.providerID else {
            return true
        }
        return next.providerID == .custom
            && current.profileID != next.profileID
    }
}

enum EmptyProfileRuntimeLifecycle {
    static func reset(
        provider: RealtimeVoiceProvider?
    ) -> VoiceSessionConfiguration {
        provider?.stopVoice()
        return .default
    }
}

final class StopWatchdog {
    typealias Cancellation = () -> Void
    typealias Scheduler = (
        TimeInterval,
        @escaping () -> Void
    ) -> Cancellation

    private let timeout: TimeInterval
    private let scheduler: Scheduler
    private var cancellation: Cancellation?
    private var generation = UUID()

    init(
        timeout: TimeInterval = 10,
        scheduler: @escaping Scheduler = StopWatchdog.dispatchScheduler
    ) {
        self.timeout = timeout
        self.scheduler = scheduler
    }

    func statusDidChange(
        _ status: ProviderStatus,
        providerID: VoiceProviderID?,
        onTimeout: @escaping (VoiceProviderID) -> Void
    ) {
        cancellation?()
        cancellation = nil
        generation = UUID()
        guard status == .stopping, let providerID else { return }

        let armedGeneration = generation
        cancellation = scheduler(timeout) { [weak self] in
            guard let self,
                  self.generation == armedGeneration else {
                return
            }
            self.cancellation = nil
            onTimeout(providerID)
        }
    }

    func cancel() {
        cancellation?()
        cancellation = nil
        generation = UUID()
    }

    private static func dispatchScheduler(
        timeout: TimeInterval,
        action: @escaping () -> Void
    ) -> Cancellation {
        let item = DispatchWorkItem(block: action)
        DispatchQueue.main.asyncAfter(
            deadline: .now() + timeout,
            execute: item
        )
        return { item.cancel() }
    }
}

enum HotKeyFallbackPolicy {
    static func diagnostic(
        hotKeyName: String,
        profileName: String,
        isAccessibilityTrusted: Bool,
        requestAccessibilityTrust: () -> Void
    ) -> String {
        if isAccessibilityTrusted {
            return "Hotkey \(hotKeyName) for voice channel \"\(profileName)\" could not be registered with Carbon; trusted event-monitor fallback active."
        }
        requestAccessibilityTrust()
        return "Hotkey \(hotKeyName) for voice channel \"\(profileName)\" could not be registered with Carbon and cannot work globally until VoiceKey is granted Accessibility access."
    }
}

struct FirstRunSettingsLifecycle: Equatable {
    private(set) var hasBeenShown = false
    private(set) var isComplete = false

    mutating func didShow(hasHotKey: Bool) -> Bool {
        hasBeenShown = true
        return completeIfAllowed(hasHotKey: hasHotKey)
    }

    mutating func profilesDidChange(hasHotKey: Bool) -> Bool {
        completeIfAllowed(hasHotKey: hasHotKey)
    }

    mutating func didClose() -> Bool {
        guard hasBeenShown, isComplete == false else { return false }
        isComplete = true
        return true
    }

    private mutating func completeIfAllowed(
        hasHotKey: Bool
    ) -> Bool {
        guard hasBeenShown, hasHotKey, isComplete == false else {
            return false
        }
        isComplete = true
        return true
    }
}

enum ProviderEventAttribution {
    static func handler(
        providerID: VoiceProviderID,
        consume: @escaping (
            VoiceProviderEvent,
            VoiceProviderID
        ) -> Void
    ) -> (VoiceProviderEvent) -> Void {
        { event in
            consume(event, providerID)
        }
    }
}

enum ProviderStatusAdoptionPolicy {
    static func shouldAdopt(
        wiredGeneration: UUID,
        currentGeneration: UUID
    ) -> Bool {
        wiredGeneration == currentGeneration
    }
}
