@testable import VoiceKey
import XCTest

final class WebWindowControllerTests: XCTestCase {
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
