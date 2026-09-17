@testable import VoiceKey
import AppKit
import XCTest

final class MenuBarIconRendererTests: XCTestCase {
    func testImageForEveryStateAndPhaseHasMenuBarSize() {
        for state in [MenuBarIconState.loading, .problem, .active, .ready] {
            for phase in [0.0, 0.25, 0.5, 0.75] {
                let image = MenuBarIconRenderer.image(state: state, phase: phase)
                XCTAssertEqual(image.size, NSSize(width: 36, height: 22), "state \(state) phase \(phase)")
            }
        }
    }

    func testImageStateDefaultsToPhaseZero() {
        let implicit = MenuBarIconRenderer.image(state: .active)
        let explicit = MenuBarIconRenderer.image(state: .active, phase: 0)
        XCTAssertEqual(bitmapData(implicit), bitmapData(explicit))
    }

    func testTemplateFlagMatchesState() {
        XCTAssertTrue(MenuBarIconRenderer.image(state: .ready).isTemplate)
        XCTAssertTrue(MenuBarIconRenderer.image(state: .loading).isTemplate)
        XCTAssertTrue(MenuBarIconRenderer.image(state: .active).isTemplate)
        XCTAssertFalse(MenuBarIconRenderer.image(state: .problem).isTemplate)
    }

    func testLoadingFramesDifferBetweenPhases() {
        let first = MenuBarIconRenderer.image(state: .loading, phase: 0)
        let second = MenuBarIconRenderer.image(state: .loading, phase: 0.25)
        XCTAssertNotNil(bitmapData(first))
        XCTAssertNotNil(bitmapData(second))
        XCTAssertNotEqual(bitmapData(first), bitmapData(second))
    }

    func testActiveFramesDifferBetweenPhases() {
        let first = MenuBarIconRenderer.image(state: .active, phase: 0)
        let second = MenuBarIconRenderer.image(state: .active, phase: 0.25)
        XCTAssertNotEqual(bitmapData(first), bitmapData(second))
    }

    func testReadyAndProblemFramesDoNotAnimate() {
        XCTAssertEqual(
            bitmapData(MenuBarIconRenderer.image(state: .ready, phase: 0)),
            bitmapData(MenuBarIconRenderer.image(state: .ready, phase: 0.5))
        )
        XCTAssertEqual(
            bitmapData(MenuBarIconRenderer.image(state: .problem, phase: 0)),
            bitmapData(MenuBarIconRenderer.image(state: .problem, phase: 0.5))
        )
    }

    func testLegacyEntryPointsStillRender() {
        let textImage = MenuBarIconRenderer.image(text: "F16", state: .ready)
        XCTAssertEqual(textImage.size, NSSize(width: 36, height: 22))

        let hotKeyImage = MenuBarIconRenderer.image(for: .defaultVoiceToggle, status: .ready)
        XCTAssertEqual(hotKeyImage.size, NSSize(width: 36, height: 22))
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

final class MenuBarIconAnimatorTests: XCTestCase {
    func testPhaseStartsAtZero() {
        XCTAssertEqual(MenuBarIconAnimator().phase, 0)
    }

    func testStartAndStopAreIdempotent() {
        let animator = MenuBarIconAnimator()
        animator.stop()
        animator.start()
        animator.start()
        animator.stop()
        animator.stop()
        animator.start()
        animator.stop()
    }

    func testAdvanceForTestingAdvancesPhaseAndFiresCallback() {
        let animator = MenuBarIconAnimator()
        var phases: [Double] = []
        animator.onFrame = { phases.append($0) }

        animator.advanceForTesting()

        XCTAssertEqual(animator.phase, 1.0 / 12.0, accuracy: 1e-9)
        XCTAssertEqual(phases.count, 1)
        XCTAssertEqual(phases.first ?? -1, animator.phase, accuracy: 1e-9)
    }

    func testAdvanceForTestingWrapsPhaseAfterFullCycle() {
        let animator = MenuBarIconAnimator()
        var callCount = 0
        animator.onFrame = { _ in callCount += 1 }

        for _ in 0..<12 {
            animator.advanceForTesting()
            XCTAssertGreaterThanOrEqual(animator.phase, 0)
            XCTAssertLessThan(animator.phase, 1.0)
        }

        XCTAssertEqual(animator.phase, 0, accuracy: 1e-9)
        XCTAssertEqual(callCount, 12)

        animator.advanceForTesting()
        XCTAssertEqual(animator.phase, 1.0 / 12.0, accuracy: 1e-9)
        XCTAssertEqual(callCount, 13)
    }
}
