@testable import VoiceKey
import AppKit
import XCTest

final class ChannelIndicatorPolicyTests: XCTestCase {
    private let openAI = UUID()
    private let castor = UUID()

    private func name(_ id: UUID) -> String? {
        switch id {
        case openAI: return "OpenAI"
        case castor: return "Castor"
        default: return nil
        }
    }

    func testOpeningAChannelAnnouncesIt() {
        XCTAssertEqual(
            ChannelIndicatorPolicy.event(
                from: nil, to: openAI, channelName: name
            ),
            .opened(channelName: "OpenAI")
        )
    }

    func testClosingTheLastChannelAnnouncesIt() {
        XCTAssertEqual(
            ChannelIndicatorPolicy.event(
                from: openAI, to: nil, channelName: name
            ),
            .closed(channelName: "OpenAI")
        )
    }

    func testSwitchingChannelsAnnouncesTheOneThatIsNowLive() {
        XCTAssertEqual(
            ChannelIndicatorPolicy.event(
                from: openAI, to: castor, channelName: name
            ),
            .opened(channelName: "Castor")
        )
    }

    /// The status funnel fires many times during one turn — listening and
    /// speaking alternate several times a second. An indicator that announced
    /// each of them would be a strobe, so an unchanged channel must say nothing.
    func testAnUnchangedChannelSaysNothing() {
        XCTAssertNil(
            ChannelIndicatorPolicy.event(
                from: openAI, to: openAI, channelName: name
            )
        )
        XCTAssertNil(
            ChannelIndicatorPolicy.event(
                from: nil, to: nil, channelName: name
            )
        )
    }

    func testAChannelThatNoLongerExistsIsNotAnnounced() {
        XCTAssertNil(
            ChannelIndicatorPolicy.event(
                from: nil, to: UUID(), channelName: name
            )
        )
    }

    func testTheTextNamesTheChannelAndItsState() {
        XCTAssertEqual(
            ChannelIndicatorEvent.opened(channelName: "OpenAI").text,
            "OpenAI — listening"
        )
        XCTAssertEqual(
            ChannelIndicatorEvent.closed(channelName: "Castor").text,
            "Castor — closed"
        )
    }
}

final class ChannelIndicatorControllerTests: XCTestCase {
    /// The panel must never steal focus or swallow a click: it appears over
    /// whatever the owner is doing, unasked.
    func testThePanelNeverTakesFocusOrClicks() throws {
        let controller = ChannelIndicatorController(
            statusItemFrame: { NSRect(x: 1200, y: 900, width: 38, height: 24) }
        )
        controller.show(.opened(channelName: "OpenAI"))

        let panel = NSApplication.shared.windows
            .compactMap { $0 as? NSPanel }
            .first { $0.contentView is NSVisualEffectView }
        XCTAssertEqual(panel?.ignoresMouseEvents, true)
        XCTAssertEqual(panel?.canBecomeKey, false)
        XCTAssertEqual(panel?.level, .statusBar)
        controller.hide()
    }

    /// With the menu bar hidden the status item has no usable frame, which is
    /// the case this whole feature exists for — it must still appear on screen.
    func testItStillAppearsWhenTheStatusItemCannotBeFound() {
        let controller = ChannelIndicatorController(statusItemFrame: { nil })
        controller.show(.closed(channelName: "Castor"))

        let panel = NSApplication.shared.windows
            .compactMap { $0 as? NSPanel }
            .first { $0.contentView is NSVisualEffectView }
        let frame = panel?.frame ?? .zero
        let screen = NSScreen.main?.frame ?? .zero
        XCTAssertTrue(
            screen.isEmpty || screen.intersects(frame),
            "the panel landed off screen when the status item was unavailable"
        )
        controller.hide()
    }
}
