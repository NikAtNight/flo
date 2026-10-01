import XCTest
import AppKit
@testable import LocalFlow

final class TextInjectorTests: XCTestCase {
    @MainActor
    func testSelectionReadsFocusedTextWithoutPostingCopyOrUsingClipboard() throws {
        let element = AXUIElementCreateApplication(getpid())
        var attributes: [String] = []
        var results: [Result<String?, TextInjector.SelectionError>] = []
        TextInjector.copySelection(isSecureInputEnabled: { false }, focusedApplication: { element }, readAttribute: { _, attribute in
            attributes.append(attribute as String)
            if attribute as String == kAXSelectedTextAttribute {
                return (.success, "Selected words." as CFString)
            }
            return (.success, element)
        }, completion: { results.append($0) })

        XCTAssertEqual(attributes, [kAXFocusedUIElementAttribute, kAXSelectedTextAttribute])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(try results[0].get(), "Selected words.")
    }

    @MainActor
    func testEmptySelectionAllowsGenerationButUnsupportedSelectionFails() throws {
        let element = AXUIElementCreateApplication(getpid())
        for (error, value, expected) in [
            (AXError.success, "" as CFTypeRef?, Result<String?, TextInjector.SelectionError>.success(nil)),
            (AXError.noValue, nil, .success(nil)),
            (AXError.attributeUnsupported, nil, .failure(.unavailable)),
            (AXError.cannotComplete, nil, .failure(.unavailable))
        ] {
            var result: Result<String?, TextInjector.SelectionError>?
            TextInjector.copySelection(isSecureInputEnabled: { false }, focusedApplication: { element }, readAttribute: { _, attribute in
                attribute as String == kAXSelectedTextAttribute ? (error, value) : (.success, element)
            }, completion: { result = $0 })
            XCTAssertEqual(result, expected)
        }
    }

    @MainActor
    func testMissingFocusOrInvalidAttributeDoesNotGenerateFromUnrelatedData() {
        let element = AXUIElementCreateApplication(getpid())
        for value: CFTypeRef? in [nil, "Unrelated clipboard contents" as CFString] {
            var result: Result<String?, TextInjector.SelectionError>?
            TextInjector.copySelection(isSecureInputEnabled: { false }, focusedApplication: { element }, readAttribute: { _, _ in
                (.success, value)
            }, completion: { result = $0 })
            XCTAssertEqual(result, .failure(.unavailable))
        }
    }

    @MainActor
    func testMissingFrontmostApplicationFailsWithoutReadingAnotherApp() {
        var result: Result<String?, TextInjector.SelectionError>?
        TextInjector.copySelection(isSecureInputEnabled: { false }, focusedApplication: { nil }, readAttribute: { _, _ in
            XCTFail("No app is available to read")
            return (.success, nil)
        }, completion: { result = $0 })
        XCTAssertEqual(result, .failure(.unavailable))
    }

    @MainActor
    func testPreparingElectronEnablesItsTreeOnlyWhenDisabled() {
        let element = AXUIElementCreateApplication(getpid())
        for (error, value, expectedWrites) in [
            (AXError.success, kCFBooleanFalse as CFTypeRef?, 1),
            (AXError.success, kCFBooleanTrue as CFTypeRef?, 0),
            (AXError.attributeUnsupported, nil, 0),
            (AXError.cannotComplete, nil, 0),
            (AXError.success, "unexpected" as CFTypeRef?, 0)
        ] {
            var writes = 0
            TextInjector.prepareSelectionAccess(focusedApplication: { element }, readAttribute: { app, attribute in
                XCTAssertTrue(CFEqual(app, element))
                XCTAssertEqual(attribute as String, "AXManualAccessibility")
                return (error, value)
            }, writeAttribute: { app, attribute, enabled in
                writes += 1
                XCTAssertTrue(CFEqual(app, element))
                XCTAssertEqual(attribute as String, "AXManualAccessibility")
                XCTAssertEqual(enabled as? Bool, true)
                return .success
            })
            XCTAssertEqual(writes, expectedWrites)
        }
    }

    @MainActor
    func testPreparationFailureDoesNotGenerateFromUnreadableSelection() {
        let element = AXUIElementCreateApplication(getpid())
        TextInjector.prepareSelectionAccess(focusedApplication: { element }, readAttribute: { _, _ in
            (.success, kCFBooleanFalse)
        }, writeAttribute: { _, _, _ in .cannotComplete })
        var result: Result<String?, TextInjector.SelectionError>?
        TextInjector.copySelection(isSecureInputEnabled: { false }, focusedApplication: { element }, readAttribute: { _, _ in
            (.noValue, nil)
        }, completion: { result = $0 })
        XCTAssertEqual(result, .failure(.unavailable))
    }

    @MainActor
    func testSecureInputDoesNotReadSelectionAttributes() throws {
        var result: Result<String?, TextInjector.SelectionError>?
        TextInjector.copySelection(isSecureInputEnabled: { true }, readAttribute: { _, _ in
            XCTFail("Secure fields must not be read")
            return (.failure, nil)
        }, completion: { result = $0 })
        XCTAssertNil(try XCTUnwrap(result).get())
    }

    @MainActor
    func testEmptyInputReportsFailureOnceWithoutDispatching() {
        var results: [TextInjector.InjectionResult] = []
        var dispatchCount = 0

        TextInjector.inject("", onDispatch: { dispatchCount += 1 }) {
            results.append($0)
        }

        XCTAssertEqual(results, [.dispatchFailed])
        XCTAssertEqual(dispatchCount, 0)
    }

    @MainActor
    func testDeliveryWarningsFitMenuWithoutTruncation() throws {
        XCTAssertNil(TextInjector.InjectionResult.dispatched.userFacingIssue)
        for result in [TextInjector.InjectionResult.clipboardChanged, .dispatchFailed] {
            let issue = try XCTUnwrap(result.userFacingIssue)
            XCTAssertEqual(issue.menuSummary, issue.summary)
            XCTAssertFalse(issue.details.isEmpty)
        }
    }

    func testUTF16ChunksRoundTripWithoutSplittingSurrogatePairs() async {
        // Nine ASCII units followed by an emoji puts the high surrogate exactly
        // at a naive ten-unit boundary.
        let text = "123456789😀tail"
        let chunks = await TextInjector.utf16Chunks(text, maxUnits: 10)

        XCTAssertEqual(chunks.flatMap { $0 }, Array(text.utf16))
        XCTAssertTrue(chunks.allSatisfy { !$0.isEmpty && $0.count <= 10 })
        for chunk in chunks {
            XCTAssertFalse((0xD800 ... 0xDBFF).contains(chunk.last!))
            XCTAssertFalse((0xDC00 ... 0xDFFF).contains(chunk.first!))
        }
    }

    func testUTF16ChunksHandlesEmptyAndASCIIText() async {
        let empty = await TextInjector.utf16Chunks("")
        let ascii = await TextInjector.utf16Chunks("abcdefgh", maxUnits: 3)

        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(ascii.map(\.count), [3, 3, 2])
        XCTAssertEqual(ascii.flatMap { $0 }, Array("abcdefgh".utf16))
    }
}
