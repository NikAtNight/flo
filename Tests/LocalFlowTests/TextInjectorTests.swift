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

    // MARK: - Receipt-based clipboard restore

    @MainActor
    func testRestoreDelayHonorsFloorAndGrace() {
        let timing = TextInjector.RestoreTiming.standard
        XCTAssertEqual(TextInjector.restoreDelay(sinceDispatch: 0.1, timing: timing), 2.4, accuracy: 1e-9)
        XCTAssertEqual(TextInjector.restoreDelay(sinceDispatch: 2.4, timing: timing), 0.2, accuracy: 1e-9)
        XCTAssertEqual(TextInjector.restoreDelay(sinceDispatch: 5, timing: timing), 0.2, accuracy: 1e-9)
    }

    @MainActor
    func testFirstReadSuppliesTextAndMovesRestoreToGraceAfterFloor() throws {
        let harness = PasteHarness(test: self)
        harness.inject("dictated")

        XCTAssertEqual(harness.scheduled.map(\.delay), [10])
        let changeCount = harness.board.changeCount
        harness.time += 0.5
        // An in-process read reaches the provider synchronously.
        XCTAssertEqual(harness.board.string(forType: .string), "dictated")
        XCTAssertEqual(harness.board.changeCount, changeCount, "supplying promised data must not look like a copy")
        XCTAssertEqual(harness.scheduled.map(\.delay), [10, 2.0])
        XCTAssertTrue(harness.scheduled[0].work.isCancelled)
        XCTAssertTrue(harness.results.isEmpty)

        harness.time += 2.0
        harness.scheduled[1].work.perform()

        XCTAssertEqual(harness.board.string(forType: .string), "user clipboard")
        XCTAssertEqual(harness.results, [.dispatched])
        XCTAssertEqual(harness.names, [.pasteDispatched, .pasteboardRead, .clipboardWindowResolved])
        let read = try XCTUnwrap(harness.events.events.first { $0.name == .pasteboardRead })
        XCTAssertEqual(try XCTUnwrap(read.fields["readLatencyMs"]), 500, accuracy: 1e-6)
        let resolved = try XCTUnwrap(harness.events.events.last)
        XCTAssertEqual(resolved.status, .unchangedClipboard)
        XCTAssertEqual(resolved.fields["readObserved"], 1)
        XCTAssertEqual(try XCTUnwrap(resolved.fields["restoreDelayMs"]), 2500, accuracy: 1e-6)
    }

    @MainActor
    func testUnreadTextRestoresAtCeiling() throws {
        let harness = PasteHarness(test: self)
        harness.inject("dictated")

        harness.time += 10
        try XCTUnwrap(harness.scheduled.first).work.perform()

        XCTAssertEqual(harness.board.string(forType: .string), "user clipboard")
        XCTAssertEqual(harness.results, [.dispatched])
        XCTAssertEqual(harness.scheduled.count, 1)
        let resolved = try XCTUnwrap(harness.events.events.last)
        XCTAssertEqual(resolved.name, .clipboardWindowResolved)
        XCTAssertEqual(resolved.fields["readObserved"], 0)
        XCTAssertEqual(try XCTUnwrap(resolved.fields["restoreDelayMs"]), 10_000, accuracy: 1e-6)
    }

    @MainActor
    func testUserCopyBeforeRestoreKeepsTheirClipboard() throws {
        let harness = PasteHarness(test: self)
        harness.inject("dictated")

        harness.board.clearContents()
        harness.board.setString("copied meanwhile", forType: .string)
        try XCTUnwrap(harness.scheduled.first).work.perform()

        XCTAssertEqual(harness.board.string(forType: .string), "copied meanwhile")
        XCTAssertEqual(harness.results, [.clipboardChanged])
        XCTAssertEqual(harness.events.events.last?.status, .changedClipboard)
    }

    @MainActor
    func testSupersedingInjectionKeepsFirstSnapshotAndResolvesEarlierOne() throws {
        let harness = PasteHarness(test: self)
        harness.inject("first")
        XCTAssertEqual(harness.board.string(forType: .string), "first")
        let firstRestore = try XCTUnwrap(harness.scheduled.last)

        harness.inject("second")

        XCTAssertEqual(harness.results, [.dispatched])
        XCTAssertTrue(firstRestore.work.isCancelled)
        XCTAssertEqual(harness.board.string(forType: .string), "second")
        try XCTUnwrap(harness.scheduled.last).work.perform()

        XCTAssertEqual(harness.board.string(forType: .string), "user clipboard")
        XCTAssertEqual(harness.results, [.dispatched, .dispatched])
        let resolved = harness.events.events.filter { $0.name == .clipboardWindowResolved }
        XCTAssertEqual(resolved.map { $0.fields["readObserved"] }, [1, 1])
    }

    @MainActor
    func testReadAfterRestoreIsIgnored() throws {
        let harness = PasteHarness(test: self)
        harness.inject("dictated")
        try XCTUnwrap(harness.scheduled.first).work.perform()
        let eventCount = harness.events.events.count

        XCTAssertEqual(harness.board.string(forType: .string), "user clipboard")
        TextInjector.restoreNow()

        XCTAssertEqual(harness.scheduled.count, 1)
        XCTAssertEqual(harness.events.events.count, eventCount)
        XCTAssertEqual(harness.results, [.dispatched])
    }

    @MainActor
    func testFailedPasteRestoresImmediatelyWithoutScheduling() {
        let harness = PasteHarness(test: self)
        harness.inject("dictated", postPaste: false)

        XCTAssertEqual(harness.board.string(forType: .string), "user clipboard")
        XCTAssertEqual(harness.results, [.dispatchFailed])
        XCTAssertTrue(harness.scheduled.isEmpty)
        XCTAssertEqual(harness.names, [.pasteDispatched])
        XCTAssertEqual(harness.events.events.first?.status, .failed)
    }

    @MainActor
    func testDictationIsMarkedTransientForClipboardManagers() throws {
        let harness = PasteHarness(test: self)
        harness.inject("dictated")

        let types = try XCTUnwrap(harness.board.pasteboardItems?.first).types
        XCTAssertTrue(types.contains(TextInjector.transientType))
        XCTAssertTrue(types.contains(.string))
    }

    @MainActor
    func testAwaitingPasteboardReadLastsFromDispatchUntilTheRead() {
        let harness = PasteHarness(test: self)
        XCTAssertFalse(TextInjector.isAwaitingPasteboardRead)
        harness.inject("dictated")
        XCTAssertTrue(TextInjector.isAwaitingPasteboardRead)

        XCTAssertEqual(harness.board.string(forType: .string), "dictated")

        XCTAssertFalse(TextInjector.isAwaitingPasteboardRead)
    }

    @MainActor
    func testRestoreNowResolvesPendingRestoreOnce() {
        let harness = PasteHarness(test: self)
        harness.inject("dictated")

        TextInjector.restoreNow()
        TextInjector.restoreNow()

        XCTAssertEqual(harness.board.string(forType: .string), "user clipboard")
        XCTAssertEqual(harness.results, [.dispatched])
        XCTAssertTrue(harness.scheduled[0].work.isCancelled)
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

/// Drives the paste path against a private pasteboard with a fake clock and
/// scheduler. `postPaste` is stubbed so no real Cmd+V goes out.
@MainActor
private final class PasteHarness {
    let board = NSPasteboard(name: NSPasteboard.Name("LocalFlowTests.\(UUID().uuidString)"))
    let events = TraceEvents()
    var time: TimeInterval = 100
    var scheduled: [(delay: TimeInterval, work: DispatchWorkItem)] = []
    var results: [TextInjector.InjectionResult] = []
    private lazy var trace = DictationTrace(sink: { [events] in events.append($0) })

    var names: [DictationTrace.Name] { events.events.map(\.name) }

    init(test: XCTestCase) {
        board.clearContents()
        board.setString("user clipboard", forType: .string)
        let board = board
        test.addTeardownBlock { @MainActor in
            TextInjector.restoreNow()
            board.releaseGlobally()
        }
    }

    func inject(_ text: String, postPaste: Bool = true) {
        DictationTrace.$current.withValue(trace) {
            TextInjector.inject(
                text, pasteboard: board, isSecureInputEnabled: { false }, postPaste: { postPaste },
                now: { self.time },
                schedule: { delay, work in self.scheduled.append((delay, work)) }
            ) { self.results.append($0) }
        }
    }
}
