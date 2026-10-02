import XCTest
@testable import LocalFlow

/// Validation that keeps the dictation HUD from restoring to a position on a
/// screen that is no longer connected. Pure geometry — no live NSScreen needed.
final class WaveformOverlayTests: XCTestCase {
    private let size = NSSize(width: 200, height: 60)

    func testOriginFullyInsideAScreenIsVisible() {
        let screens = [NSRect(x: 0, y: 0, width: 1440, height: 900)]
        XCTAssertTrue(WaveformOverlay.isVisible(origin: NSPoint(x: 100, y: 100),
                                                size: size, on: screens))
    }

    func testPartialOverlapCountsAsVisible() {
        let screens = [NSRect(x: 0, y: 0, width: 1440, height: 900)]
        // Straddling the right edge — still grabbable, so still "visible".
        XCTAssertTrue(WaveformOverlay.isVisible(origin: NSPoint(x: 1400, y: 100),
                                                size: size, on: screens))
    }

    func testOriginOffAllScreensIsNotVisible() {
        let screens = [NSRect(x: 0, y: 0, width: 1440, height: 900)]
        XCTAssertFalse(WaveformOverlay.isVisible(origin: NSPoint(x: 5000, y: 5000),
                                                 size: size, on: screens))
    }

    func testNoScreensIsNotVisible() {
        XCTAssertFalse(WaveformOverlay.isVisible(origin: NSPoint(x: 100, y: 100),
                                                 size: size, on: []))
    }

    func testLandsOnSecondScreenIsVisible() {
        let screens = [
            NSRect(x: 0, y: 0, width: 1440, height: 900),
            NSRect(x: 1440, y: 0, width: 2560, height: 1440),
        ]
        XCTAssertTrue(WaveformOverlay.isVisible(origin: NSPoint(x: 3000, y: 700),
                                                size: size, on: screens))
    }

    func testWindowWithTranscriptReserveAtScreenBottomIsVisible() {
        // With live transcript on, the window is the capsule plus the panel
        // reserve above it, starting at the capsule's origin.
        let screens = [NSRect(x: 0, y: 0, width: 1440, height: 900)]
        let reserve = HudLayout.reserve(liveTranscript: true)
        let tall = HudLayout.windowSize(capsule: size, reserve: reserve)
        XCTAssertEqual(tall.height, size.height + reserve)
        XCTAssertTrue(WaveformOverlay.isVisible(origin: NSPoint(x: 100, y: 10),
                                                size: tall, on: screens))
        // Only the empty reserve pokes onto the screen: still counts, since
        // the capsule is a drag away.
        XCTAssertTrue(WaveformOverlay.isVisible(origin: NSPoint(x: 100, y: -size.height - 20),
                                                size: tall, on: screens))
        XCTAssertFalse(WaveformOverlay.isVisible(origin: NSPoint(x: 100, y: -tall.height - 1),
                                                 size: tall, on: screens))
    }

    // MARK: - Transcript panel geometry

    func testPanelHeightGrowsPerLineAndCapsAtThreeLines() {
        XCTAssertEqual(HudLayout.panelHeight(lineCount: 0), 0)
        // 12 pt + n * 20.25 pt (15 pt at 1.35 line height) + 10 pt, rounded up.
        XCTAssertEqual(HudLayout.panelHeight(lineCount: 1), 43)
        XCTAssertEqual(HudLayout.panelHeight(lineCount: 2), 63)
        XCTAssertEqual(HudLayout.panelHeight(lineCount: 3), 83)
        XCTAssertEqual(HudLayout.panelHeight(lineCount: 7), 83)
        XCTAssertEqual(HudLayout.panelMaxHeight, 83)
    }

    func testReserveIsGapPlusMaxPanelOnlyWhenTranscriptIsOn() {
        XCTAssertEqual(HudLayout.reserve(liveTranscript: true), 6 + 83)
        XCTAssertEqual(HudLayout.reserve(liveTranscript: false), 0)
        XCTAssertEqual(HudLayout.windowSize(capsule: size, reserve: 0), size)
    }

    func testCapsuleOriginRoundTripsThroughWindowOriginInBothPlacements() {
        let reserve = HudLayout.reserve(liveTranscript: true)
        let capsule = NSPoint(x: 612.5, y: 87.25)
        for placement in [TranscriptPlacement.above, .below] {
            let window = HudLayout.windowOrigin(capsuleOrigin: capsule, placement: placement,
                                                reserve: reserve)
            XCTAssertEqual(HudLayout.capsuleOrigin(windowOrigin: window, placement: placement,
                                                   reserve: reserve), capsule)
        }
        // Above: the capsule is the window's bottom. Below: its top.
        XCTAssertEqual(HudLayout.windowOrigin(capsuleOrigin: capsule, placement: .above,
                                              reserve: reserve), capsule)
        XCTAssertEqual(HudLayout.windowOrigin(capsuleOrigin: capsule, placement: .below,
                                              reserve: reserve).y, capsule.y - reserve)
    }

    func testOriginSavedUnderTheStripLayoutKeepsTheCapsuleInPlace() {
        // The strip layout saved panel origin + 30, which was the capsule's
        // bottom-left. The new layout treats the saved value the same way.
        let stripPanelOrigin = NSPoint(x: 400, y: 34)
        let saved = NSPoint(x: stripPanelOrigin.x, y: stripPanelOrigin.y + 30)
        let reserve = HudLayout.reserve(liveTranscript: true)
        let window = HudLayout.windowOrigin(capsuleOrigin: saved, placement: .above,
                                            reserve: reserve)
        let capsuleBottom = window.y + HudLayout.capsuleOffset(placement: .above, reserve: reserve)
        XCTAssertEqual(capsuleBottom, saved.y)
    }

    func testPanelOpensAboveUnlessTheCapsuleIsNearTheTopOfItsScreen() {
        let reserve = HudLayout.reserve(liveTranscript: true)
        let screens = [NSRect(x: 0, y: 0, width: 1440, height: 875)]
        func placement(capsuleY: CGFloat) -> TranscriptPlacement {
            HudLayout.placement(capsuleFrame: NSRect(x: 600, y: capsuleY, width: 280, height: 64),
                                reserve: reserve, screens: screens)
        }
        XCTAssertEqual(placement(capsuleY: 64), .above)
        // Exactly enough room for the reserve above the capsule.
        XCTAssertEqual(placement(capsuleY: 875 - 64 - reserve), .above)
        XCTAssertEqual(placement(capsuleY: 875 - 64 - reserve + 1), .below)
        XCTAssertEqual(placement(capsuleY: 800), .below)
        // No transcript, nothing to flip.
        XCTAssertEqual(HudLayout.placement(capsuleFrame: NSRect(x: 600, y: 800, width: 280, height: 64),
                                           reserve: 0, screens: screens), .above)
    }

    func testFlipUsesTheScreenTheCapsuleIsOn() {
        let reserve = HudLayout.reserve(liveTranscript: true)
        let screens = [
            NSRect(x: 0, y: 0, width: 1440, height: 875),
            NSRect(x: 1440, y: 0, width: 2560, height: 1415),
        ]
        // Near the top of the short screen's height, but on the tall one.
        let capsule = NSRect(x: 2000, y: 800, width: 280, height: 64)
        XCTAssertEqual(HudLayout.placement(capsuleFrame: capsule, reserve: reserve,
                                           screens: screens), .above)
        let onShort = NSRect(x: 200, y: 800, width: 280, height: 64)
        XCTAssertEqual(HudLayout.placement(capsuleFrame: onShort, reserve: reserve,
                                           screens: screens), .below)
    }

    // MARK: - Content view

    @MainActor
    func testTranscriptOffContentIsExactlyTheCapsule() {
        let content = HudContentView(theme: .classic, liveTranscript: false)
        XCTAssertEqual(content.frame.size, HudTheme.classic.size)
        XCTAssertEqual(content.capsuleFrame, content.bounds)
        XCTAssertEqual(content.subviews.count, 1)
        content.setTranscript("Hello there.", animated: false)
        XCTAssertNil(content.openTranscriptFrame)
    }

    @MainActor
    func testCapsuleSitsOnThePanelsOppositeEdge() {
        let content = HudContentView(theme: .classic, liveTranscript: true)
        let capsule = HudTheme.classic.size
        XCTAssertEqual(content.frame.size.height, capsule.height + 6 + 83)
        XCTAssertEqual(content.capsuleFrame.origin, .zero)
        content.placement = .below
        XCTAssertEqual(content.capsuleFrame.maxY, content.bounds.maxY)
    }

    @MainActor
    func testPanelOpensOnTextAndTracksLineCount() throws {
        let content = HudContentView(theme: .classic, liveTranscript: true)
        XCTAssertNil(content.openTranscriptFrame)

        content.setTranscript("Okay.", animated: false)
        let one = try XCTUnwrap(content.openTranscriptFrame)
        XCTAssertEqual(one.height, HudLayout.panelHeight(lineCount: 1))
        XCTAssertEqual(one.minY, content.capsuleFrame.maxY + 6)
        XCTAssertEqual(one.width, content.capsuleFrame.width)

        content.setTranscript(String(repeating: "A long dictated sentence. ", count: 12),
                              animated: false)
        XCTAssertEqual(content.openTranscriptFrame?.height, HudLayout.panelMaxHeight)

        content.placement = .below
        let below = try XCTUnwrap(content.openTranscriptFrame)
        XCTAssertEqual(below.maxY, content.capsuleFrame.minY - 6)

        content.setTranscript("", animated: false)
        XCTAssertNil(content.openTranscriptFrame)
    }

    @MainActor
    func testReservedSpaceIsClickThroughUntilThePanelOpens() {
        let content = HudContentView(theme: .classic, liveTranscript: true)
        let capsule = content.capsuleFrame
        let reserved = NSPoint(x: capsule.midX, y: capsule.maxY + 20)
        XCTAssertNotNil(content.hitTest(NSPoint(x: capsule.midX, y: capsule.midY)))
        XCTAssertNil(content.hitTest(reserved))

        content.setTranscript("Okay.", animated: false)
        XCTAssertNotNil(content.hitTest(reserved))
        // Above a one-line panel is still empty reserve.
        XCTAssertNil(content.hitTest(NSPoint(x: capsule.midX, y: content.bounds.maxY - 2)))
    }
}
