import AppKit
import Carbon.HIToolbox

/// Inserts text into whatever app has focus.
///
/// Default strategy (per plan): put the text on the clipboard, synthesize
/// Cmd+V, then restore the previous clipboard contents. Falls back to
/// synthesized unicode keystrokes when Secure Input is active (password
/// fields block synthesized paste but sometimes accept typed events — and
/// we must never leave dictated text on the clipboard in that case).
@MainActor
enum TextInjector {
    enum InjectionResult: Equatable {
        /// Events were posted. The target app's insertion is not observable.
        case dispatched
        /// Paste was posted, but the clipboard changed before restoration.
        case clipboardChanged
        /// Some or all keyboard events could not be created.
        case dispatchFailed

        var userFacingIssue: UserFacingIssue? {
            switch self {
            case .dispatched:
                return nil
            case .clipboardChanged:
                return UserFacingIssue(
                    summary: "Clipboard changed after paste",
                    details: "The paste shortcut was sent, but the clipboard changed before restoration. Check whether the text appeared before copying it from Recent Dictations."
                )
            case .dispatchFailed:
                return UserFacingIssue(
                    summary: "Couldn't send dictation",
                    details: "Some or all text could not be sent. Check the target app before copying the transcript from Recent Dictations."
                )
            }
        }
    }

    // All mutated on the main thread only (inject is called from the app's
    // main-actor pipeline). Tracks one save/restore cycle across possibly
    // overlapping dictations.
    private static var savedItems: [NSPasteboardItem]?
    private static var restoreWork: DispatchWorkItem?
    private static var pendingCompletion: ((_ undisturbed: Bool, _ readObserved: Bool) -> Void)?
    private static var ourChangeCount = -1
    private static var restoreGeneration = 0
    private static var dispatchedAt: TimeInterval?
    private static var readObservedAt: TimeInterval?
    // AppKit's docs don't promise the item keeps its provider alive.
    private static var pasteReceipt: PasteReceipt?

    /// When to put the user's clipboard back. Restore at the later of
    /// read + `grace` and dispatch + `floor`. With no read, restore at
    /// dispatch + `ceiling`.
    struct RestoreTiming: Equatable {
        var floor: TimeInterval = 2.5
        var grace: TimeInterval = 0.2
        var ceiling: TimeInterval = 10
        static let standard = RestoreTiming()
    }

    typealias Scheduler = (TimeInterval, DispatchWorkItem) -> Void

    /// nspasteboard.org marker. Compliant clipboard managers skip items that
    /// carry it without reading them, so they don't fake an early receipt.
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// `completion` runs on the main queue and reports event dispatch and
    /// clipboard disturbance. Neither confirms insertion into the target app.
    static func inject(
        _ text: String,
        pasteboard: NSPasteboard = .general,
        timing: RestoreTiming = .standard,
        isSecureInputEnabled: () -> Bool = { IsSecureEventInputEnabled() },
        postPaste: @MainActor () -> Bool = { postKeystroke(virtualKey: CGKeyCode(kVK_ANSI_V), flags: .maskCommand) },
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        schedule: @escaping Scheduler = { delay, work in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) },
        onDispatch: (() -> Void)? = nil,
        completion: ((InjectionResult) -> Void)? = nil
    ) {
        let trace = DictationTrace.current
        guard !text.isEmpty else {
            completion?(.dispatchFailed)
            return
        }

        if isSecureInputEnabled() {
            // Password field or similar: avoid the clipboard entirely.
            typeString(text, trace: trace, onDispatch: onDispatch, completion: completion)
            return
        }

        // Two dictations can land within one restore window (recording while
        // the previous one transcribes is allowed). Keep the snapshot from
        // the FIRST of the sequence — snapshotting now would capture the
        // previous dictation as "the user's clipboard" and lose the real one.
        restoreWork?.cancel()
        restoreWork = nil
        restoreGeneration &+= 1
        // A superseded injection never reaches its restore work — resolve it
        // now with the same signal the work item would have used.
        resolvePending(undisturbed: pasteboard.changeCount == ourChangeCount)
        if savedItems == nil || pasteboard.changeCount != ourChangeCount {
            savedItems = snapshot(of: pasteboard)
        }

        let generation = restoreGeneration
        let scheduleRestore: (TimeInterval) -> Void = { delay in
            let work = DispatchWorkItem { restore(generation, on: pasteboard) }
            restoreWork = work
            schedule(delay, work)
        }
        // Promise the text instead of writing it, so the first reader tells
        // us the paste is being serviced.
        let receipt = PasteReceipt(text: text) {
            let read = { noteRead(generation, at: now(), timing: timing, trace: trace, scheduleRestore: scheduleRestore) }
            // In-process reads call the provider synchronously and
            // out-of-process reads are serviced on the main run loop, so
            // this is main in practice. Hop if it ever isn't.
            if Thread.isMainThread {
                MainActor.assumeIsolated(read)
            } else {
                DispatchQueue.main.async(execute: read)
            }
        }
        pasteReceipt = receipt
        let item = NSPasteboardItem()
        if !item.setDataProvider(receipt, forTypes: [.string]) {
            item.setString(text, forType: .string)
        }
        item.setData(Data(), forType: transientType)
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        ourChangeCount = pasteboard.changeCount
        guard postPaste() else {
            trace?.record(.pasteDispatched, status: .failed)
            // No Cmd-V went out — put the user's clipboard back right away.
            pasteReceipt = nil
            if let saved = savedItems {
                savedItems = nil
                pasteboard.clearContents()
                pasteboard.writeObjects(saved)
            }
            completion?(.dispatchFailed)
            return
        }
        trace?.record(.pasteDispatched, status: .success)
        let dispatched = now()
        dispatchedAt = dispatched
        onDispatch?()
        pendingCompletion = { undisturbed, readObserved in
            trace?.record(.clipboardWindowResolved, status: undisturbed ? .unchangedClipboard : .changedClipboard, fields: [
                .readObserved: readObserved ? 1 : 0,
                .restoreDelayMs: (now() - dispatched) * 1000
            ])
            completion?(undisturbed ? .dispatched : .clipboardChanged)
        }

        // Slow apps can take well over a second to service the paste, and
        // restoring too early pastes the user's old clipboard instead of the
        // dictation. Wait for a read, or the ceiling if nothing reads.
        scheduleRestore(timing.ceiling)
    }

    /// True from Cmd+V dispatch until the target app reads the paste or the
    /// clipboard is restored. While it's true the frontmost app may be
    /// blocked waiting for our main thread to fulfil the promised string, so
    /// a synchronous Accessibility call into it would stall both apps.
    static var isAwaitingPasteboardRead: Bool {
        dispatchedAt != nil && readObservedAt == nil
    }

    /// Delay from the moment the receipt arrives until the restore.
    static func restoreDelay(sinceDispatch elapsed: TimeInterval, timing: RestoreTiming) -> TimeInterval {
        max(timing.grace, timing.floor - elapsed)
    }

    /// Restores a pending snapshot now. No-op when nothing is pending.
    /// For the quit path and tests.
    static func restoreNow() {
        guard let work = restoreWork else { return }
        work.perform()
        work.cancel()
    }

    private static func noteRead(
        _ generation: Int, at time: TimeInterval, timing: RestoreTiming,
        trace: DictationTrace?, scheduleRestore: (TimeInterval) -> Void
    ) {
        // The provider runs once per item, so only the first read counts.
        guard generation == restoreGeneration, let dispatchedAt, readObservedAt == nil else { return }
        readObservedAt = time
        let elapsed = time - dispatchedAt
        trace?.record(.pasteboardRead, fields: [.readLatencyMs: elapsed * 1000])
        restoreWork?.cancel()
        scheduleRestore(restoreDelay(sinceDispatch: elapsed, timing: timing))
    }

    private static func restore(_ generation: Int, on pasteboard: NSPasteboard) {
        guard generation == restoreGeneration else { return }
        restoreWork = nil
        pasteReceipt = nil
        let saved = savedItems
        savedItems = nil
        // changeCount moved = the user copied something themselves in
        // the meantime. Theirs wins over the restore, and whether the
        // paste landed first is unknowable.
        let undisturbed = pasteboard.changeCount == ourChangeCount
        if undisturbed, let saved {
            pasteboard.clearContents()
            pasteboard.writeObjects(saved)
        }
        resolvePending(undisturbed: undisturbed)
    }

    /// Clears per-injection state before calling out, so a completion that
    /// starts the next injection sees a clean slate.
    private static func resolvePending(undisturbed: Bool) {
        guard let done = pendingCompletion else { return }
        let readObserved = readObservedAt != nil
        pendingCompletion = nil
        dispatchedAt = nil
        readObservedAt = nil
        done(undisturbed, readObserved)
    }

    enum SelectionError: Error, LocalizedError, Equatable {
        case unavailable

        var errorDescription: String? {
            "The focused app doesn't expose a readable text selection. Focus an editable text field and check Flo's Accessibility permission, then try again."
        }
    }

    typealias SelectionAttributeReader = @MainActor (AXUIElement, CFString) -> (AXError, CFTypeRef?)

    private static func frontmostAccessibilityApplication() -> AXUIElement? {
        NSWorkspace.shared.frontmostApplication.map { AXUIElementCreateApplication($0.processIdentifier) }
    }

    private static func selectionAttribute(_ element: AXUIElement, _ attribute: CFString) -> (AXError, CFTypeRef?) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &value)
        return (error, value)
    }

    /// Electron builds its text accessibility tree asynchronously. Start it
    /// before recording so the focused field is available when speech returns.
    static func prepareSelectionAccess(
        focusedApplication: @MainActor () -> AXUIElement? = frontmostAccessibilityApplication,
        readAttribute: SelectionAttributeReader = selectionAttribute,
        writeAttribute: (AXUIElement, CFString, CFTypeRef) -> AXError = AXUIElementSetAttributeValue
    ) {
        guard let application = focusedApplication() else { return }
        let attribute = "AXManualAccessibility" as CFString
        let (error, enabled) = readAttribute(application, attribute)
        guard error == .success, let enabled = enabled as? Bool, !enabled else { return }
        _ = writeAttribute(application, attribute, kCFBooleanTrue)
    }

    /// Reads selection through Accessibility without touching the clipboard.
    /// An unsupported selection is an error, not a request to generate new text.
    static func copySelection(
        isSecureInputEnabled: () -> Bool = { IsSecureEventInputEnabled() },
        focusedApplication: @MainActor () -> AXUIElement? = frontmostAccessibilityApplication,
        readAttribute: SelectionAttributeReader = selectionAttribute,
        completion: (Result<String?, SelectionError>) -> Void
    ) {
        guard !isSecureInputEnabled() else {
            completion(.success(nil))
            return
        }
        guard let appElement = focusedApplication() else {
            completion(.failure(.unavailable))
            return
        }
        let (focusError, focus) = readAttribute(appElement, kAXFocusedUIElementAttribute as CFString)
        guard focusError == .success, let focus,
              CFGetTypeID(focus) == AXUIElementGetTypeID() else {
            completion(.failure(.unavailable))
            return
        }
        let focusedElement = focus as! AXUIElement
        let (selectionError, selection) = readAttribute(focusedElement, kAXSelectedTextAttribute as CFString)
        if selectionError == .noValue {
            completion(.success(nil))
        } else if selectionError == .success, let text = selection as? String {
            completion(.success(text.isEmpty ? nil : text))
        } else {
            completion(.failure(.unavailable))
        }
    }

    // MARK: - Clipboard save/restore

    private static func snapshot(of pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    // MARK: - Synthesized events

    private static func postKeystroke(virtualKey: CGKeyCode, flags: CGEventFlags) -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)
        else { return false }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    // Serial so overlapping dictations type in order, off the main thread
    // (the per-chunk sleeps would stall it; CGEvent posting is thread-safe).
    private static let typingQueue = DispatchQueue(label: "LocalFlow.TextTyping", qos: .userInitiated)

    /// Types text as synthesized unicode keyboard events, in chunks (long
    /// strings on a single event get truncated by some apps).
    /// `completion` runs on the main queue once every chunk has been posted.
    private static func typeString(_ text: String, trace: DictationTrace?, onDispatch: (() -> Void)?, completion: ((InjectionResult) -> Void)? = nil) {
        let chunks = utf16Chunks(text)
        typingQueue.async {
            trace?.record(.typingStarted)
            let source = CGEventSource(stateID: .combinedSessionState)
            var allPosted = true

            for (index, chunk) in chunks.enumerated() {
                if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                   let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                    down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                    up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                    down.post(tap: .cghidEventTap)
                    up.post(tap: .cghidEventTap)
                } else {
                    allPosted = false
                }
                if index < chunks.count - 1 { usleep(8_000) }
            }
            trace?.record(.typingDispatched, status: allPosted ? .success : .failed)
            DispatchQueue.main.async {
                if allPosted { onDispatch?() }
                completion?(allPosted ? .dispatched : .dispatchFailed)
            }
        }
    }

    /// Splits UTF-16 at scalar boundaries. A fixed-width split can put the
    /// halves of an emoji's surrogate pair on separate CGEvents and corrupt it.
    static func utf16Chunks(_ text: String, maxUnits: Int = 20) -> [[UInt16]] {
        precondition(maxUnits >= 2)
        let units = Array(text.utf16)
        var chunks: [[UInt16]] = []
        var start = 0
        while start < units.count {
            var end = min(start + maxUnits, units.count)
            if end < units.count,
               (0xD800 ... 0xDBFF).contains(units[end - 1]),
               (0xDC00 ... 0xDFFF).contains(units[end]) {
                end -= 1
            }
            chunks.append(Array(units[start ..< end]))
            start = end
        }
        return chunks
    }
}

/// Supplies the dictation text on first read and reports that read. AppKit
/// calls the provider at most once per type, then serves cached bytes, so
/// the receipt is one-shot and can't tell the target app from anyone else.
private final class PasteReceipt: NSObject, NSPasteboardItemDataProvider {
    private var text: String?
    private let onRead: () -> Void

    init(text: String, onRead: @escaping () -> Void) {
        self.text = text
        self.onRead = onRead
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard let text else { return }
        // Set it on the item, not the pasteboard. Writing to the pasteboard
        // would bump changeCount and look like the user copied something.
        item.setString(text, forType: type)
        onRead()
    }

    /// Fires when the item leaves the pasteboard, including during our own
    /// clearContents(). Only drops the text, never drives state.
    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
        text = nil
    }
}
