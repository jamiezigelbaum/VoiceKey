@testable import VoiceKey
import AppKit
import XCTest

final class MenuBarIconStateMotionTests: XCTestCase {
    func testStatusMappingDistinguishesActiveFamily() {
        XCTAssertEqual(MenuBarIconState(status: .listening), .listening)
        XCTAssertEqual(MenuBarIconState(status: .thinking), .thinking)
        XCTAssertEqual(MenuBarIconState(status: .speaking), .speaking)
        XCTAssertEqual(MenuBarIconState(status: .clickSent), .speaking)
        XCTAssertEqual(MenuBarIconState(status: .voiceActive), .speaking)
    }

    func testStatusMappingKeepsNonActiveFamilies() {
        XCTAssertEqual(MenuBarIconState(status: .loading), .loading)
        XCTAssertEqual(MenuBarIconState(status: .checking), .loading)
        XCTAssertEqual(MenuBarIconState(status: .starting), .loading)
        XCTAssertEqual(MenuBarIconState(status: .stopping), .loading)
        XCTAssertEqual(MenuBarIconState(status: .loginRequired), .problem)
        XCTAssertEqual(MenuBarIconState(status: .needsAttention("Disconnected")), .problem)
        XCTAssertEqual(MenuBarIconState(status: .ready), .ready)
    }

    func testEveryStateRendersAtMenuBarSizeForAnyPhase() {
        let states: [MenuBarIconState] = [.loading, .problem, .listening, .thinking, .speaking, .active, .ready]
        for state in states {
            for phase in [0.0, 0.13, 0.25, 0.5, 0.9, 1.35] {
                let image = MenuBarIconRenderer.image(state: state, phase: phase)
                XCTAssertEqual(image.size, NSSize(width: 36, height: 22), "state \(state) phase \(phase)")
                XCTAssertNotNil(bitmapData(image), "state \(state) phase \(phase)")
            }
        }
    }

    func testAnimatedStatesChangeBetweenPhases() {
        for state in [MenuBarIconState.listening, .thinking, .speaking] {
            let first = bitmapData(MenuBarIconRenderer.image(state: state, phase: 0))
            let second = bitmapData(MenuBarIconRenderer.image(state: state, phase: 0.25))
            XCTAssertNotEqual(first, second, "state \(state) should animate")
        }
    }

    func testActiveRendersIdenticallyToSpeaking() {
        for phase in [0.0, 0.2, 0.55] {
            XCTAssertEqual(
                bitmapData(MenuBarIconRenderer.image(state: .active, phase: phase)),
                bitmapData(MenuBarIconRenderer.image(state: .speaking, phase: phase)),
                "phase \(phase)"
            )
        }
    }

    func testNewActiveStatesAreTemplate() {
        XCTAssertTrue(MenuBarIconRenderer.image(state: .listening).isTemplate)
        XCTAssertTrue(MenuBarIconRenderer.image(state: .thinking).isTemplate)
        XCTAssertTrue(MenuBarIconRenderer.image(state: .speaking).isTemplate)
    }

    func testPhaseWrapsCleanlyBeyondOneCycle() {
        for state in [MenuBarIconState.loading, .listening, .thinking, .speaking] {
            XCTAssertEqual(
                bitmapData(MenuBarIconRenderer.image(state: state, phase: 0.25)),
                bitmapData(MenuBarIconRenderer.image(state: state, phase: 1.25)),
                "state \(state)"
            )
        }
    }

    private func bitmapData(_ image: NSImage) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 36,
            pixelsHigh: 22,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 36, height: 22))
        NSGraphicsContext.restoreGraphicsState()

        guard let pixels = rep.bitmapData else { return nil }
        return Data(bytes: pixels, count: rep.bytesPerRow * rep.pixelsHigh)
    }
}
