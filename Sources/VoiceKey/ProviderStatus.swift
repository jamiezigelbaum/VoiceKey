import Foundation

enum ProviderStatus: Equatable {
    case loading
    case loginRequired
    case ready
    case starting
    case clickSent
    case voiceActive
    case stopping
    case needsAttention(String)

    var menuTitle: String {
        switch self {
        case .loading:
            return "Loading ChatGPT"
        case .loginRequired:
            return "Sign in required"
        case .ready:
            return "Ready"
        case .starting:
            return "Starting voice"
        case .clickSent:
            return "Voice click sent"
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
        case .loginRequired:
            return "VK Sign In"
        case .ready:
            return "VK Ready"
        case .starting:
            return "VK Starting"
        case .clickSent:
            return "VK Sent"
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
