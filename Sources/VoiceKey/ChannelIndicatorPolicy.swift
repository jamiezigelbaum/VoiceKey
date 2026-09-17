import Foundation

/// What the menu-bar indicator should announce, if anything.
enum ChannelIndicatorEvent: Equatable {
    case opened(channelName: String)
    case closed(channelName: String)

    var text: String {
        switch self {
        case let .opened(name):
            return "\(name) — listening"
        case let .closed(name):
            return "\(name) — closed"
        }
    }

    /// SF Symbol shown beside the text.
    var symbolName: String {
        switch self {
        case .opened:
            return "waveform"
        case .closed:
            return "waveform.slash"
        }
    }
}

/// Decides when a channel change is worth interrupting the owner for.
///
/// Driven by the same "which channel is active" value the media hold uses, so
/// the indicator cannot disagree with the rest of the app about whether a
/// channel is open. Deliberately blind to `listening`/`speaking` churn: those
/// alternate several times a second during a normal turn and an indicator that
/// tracked them would be a strobe.
enum ChannelIndicatorPolicy {
    static func event(
        from previous: UUID?,
        to next: UUID?,
        channelName: (UUID) -> String?
    ) -> ChannelIndicatorEvent? {
        guard previous != next else { return nil }

        if let next {
            // Covers both "nothing was open" and a direct switch between two
            // channels: either way what the owner needs to know is which one is
            // live now.
            guard let name = channelName(next) else { return nil }
            return .opened(channelName: name)
        }

        guard let previous, let name = channelName(previous) else { return nil }
        return .closed(channelName: name)
    }
}
