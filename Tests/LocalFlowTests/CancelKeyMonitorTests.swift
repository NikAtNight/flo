import Carbon.HIToolbox
import CoreGraphics
import XCTest
@testable import LocalFlow

/// The Escape filter runs inside a live keyDown tap and swallows what it
/// matches, so a loose match would eat the user's own shortcuts.
final class CancelKeyMonitorTests: XCTestCase {

    func testBareEscapeCancels() {
        XCTAssertTrue(CancelKeyMonitor.shouldCancel(keyCode: 53, flags: []))
        XCTAssertEqual(kVK_Escape, 53)
    }

    func testEscapeWhileHoldingTheHotkeyCancels() {
        // Right Option and Fn are push-to-talk keys, so they're often held.
        let rightOption = CGEventFlags.maskAlternate.union(CGEventFlags(rawValue: 0x40))
        XCTAssertTrue(CancelKeyMonitor.shouldCancel(keyCode: 53, flags: rightOption))
        XCTAssertTrue(CancelKeyMonitor.shouldCancel(keyCode: 53, flags: .maskSecondaryFn))
    }

    func testEscapeChordsPassThrough() {
        for flags: CGEventFlags in [.maskCommand, .maskControl, .maskShift,
                                    [.maskCommand, .maskAlternate]] {
            XCTAssertFalse(CancelKeyMonitor.shouldCancel(keyCode: 53, flags: flags))
        }
    }

    func testOtherKeysPassThrough() {
        for keyCode in [kVK_Return, kVK_Space, kVK_Delete, kVK_ANSI_A, kVK_RightOption] {
            XCTAssertFalse(CancelKeyMonitor.shouldCancel(keyCode: Int64(keyCode), flags: []))
        }
    }
}
