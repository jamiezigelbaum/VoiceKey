@testable import VoiceKey
import XCTest

final class WebWindowControllerTests: XCTestCase {
    func testWebViewPresentsSafariUserAgent() {
        // chatgpt.com strips GPT-Live's server-side tools (web search) when
        // it sees a bare WKWebView embed UA (verified live 2026-07-24).
        let controller = WebWindowController()
        let userAgent = controller.webView.customUserAgent ?? ""
        XCTAssertTrue(userAgent.contains("Safari/"), "UA must present as Safari: \(userAgent)")
        XCTAssertTrue(userAgent.contains("Version/"), "Safari UAs carry a Version token: \(userAgent)")
        XCTAssertFalse(userAgent.contains("VoiceKey"), "App name must not leak into the UA")
    }

    func testDOMPointUsesTopLeftOriginAndAppKitPointUsesBottomLeftOrigin() {
        let point = WebWindowController.appKitPointForDOMPoint(
            x: 930,
            y: 350,
            webViewHeight: 820
        )

        XCTAssertEqual(point.x, 930)
        XCTAssertEqual(point.y, 470)
    }
}
