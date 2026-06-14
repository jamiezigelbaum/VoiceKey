import Foundation

enum ProviderStatus: Equatable {
    case loading
    case checking
    case loginRequired
    case ready
    case starting
    case listening
    case thinking
    case speaking
    case clickSent
    case voiceActive
    case stopping
    case needsAttention(String)

    var menuTitle: String {
        switch self {
        case .loading:
            return "Loading provider"
        case .checking:
            return "Checking provider"
        case .loginRequired:
            return "Sign in required"
        case .ready:
            return "Ready"
        case .starting:
            return "Starting voice"
        case .listening:
            return "Listening"
        case .thinking:
            return "Thinking"
        case .speaking:
            return "Speaking"
        case .clickSent:
            return "Voice started"
        case .voiceActive:
            return "Voice active"
        case .stopping:
            return "Stopping voice"
        case .needsAttention:
            return "Needs attention"
        }
    }

    var statusItemTitle: String {
        switch self {
        case .loading:
            return "VK Loading"
        case .checking:
            return "VK Checking"
        case .loginRequired:
            return "VK Sign In"
        case .ready:
            return "VK Ready"
        case .starting:
            return "VK Starting"
        case .listening:
            return "VK Listening"
        case .thinking:
            return "VK Thinking"
        case .speaking:
            return "VK Speaking"
        case .clickSent:
            return "VK Voice"
        case .voiceActive:
            return "VK Voice"
        case .stopping:
            return "VK Stopping"
        case .needsAttention:
            return "VK Attention"
        }
    }

    var detail: String? {
        if case let .needsAttention(message) = self {
            return message
        }
        return nil
    }
}
