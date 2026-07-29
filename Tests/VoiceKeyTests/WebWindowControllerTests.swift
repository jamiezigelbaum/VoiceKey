@testable import VoiceKey
import XCTest

final class WebWindowControllerTests: XCTestCase {
    func testMediaCapturePermissionRequiresAnExactAllowedHostOrTrueSubdomain() {
        let cases: [(host: String, expected: WebMediaCapturePermissionPolicy.Decision)] = [
            ("chatgpt.com", .grant),
            ("openai.com", .grant),
            ("auth.openai.com", .grant),
            ("chat.chatgpt.com", .grant),
            ("openai.com.attacker.example", .prompt),
            ("chatgpt.com.evil.test", .prompt),
            ("notopenai.com", .prompt),
            ("myopenai.com.co", .prompt),
            ("openai.company", .prompt),
            ("evil.com/openai.com", .prompt),
            ("", .prompt),
            ("AuTh.OpEnAi.CoM", .grant),
        ]

        for testCase in cases {
            XCTAssertEqual(
                WebMediaCapturePermissionPolicy.decision(forHost: testCase.host),
                testCase.expected,
                "Unexpected media capture permission for host \(testCase.host)"
            )
        }
    }

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
