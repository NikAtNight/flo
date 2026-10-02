import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Watches for Escape while a dictation is recording or processing, so the
/// user can throw away an accidental press. One keyDown tap, created on
/// first use and kept disabled outside a dictation: a disabled tap gets no
/// events, so ordinary typing never reaches LocalFlow. Escape doesn't work
/// inside Secure Input (password fields); keystroke taps see nothing there.
final class CancelKeyMonitor {
    /// Called on the main queue when Escape is pressed while active.
    var onCancel: (() -> Void)?

    // Main-thread only.
    private var tap: CFMachPort?
    private var tapRunLoop: CFRunLoop?
    private var isActive = false
    private var lastCreateFailureLog: Date?
    // Touched only on the tap run loop. A system re-enable after
    // tapDisabledByTimeout must not wake a tap we turned off on purpose.
    private var wantsEnabled = false
    private var threadTap: CFMachPort?

    /// Escape with no Control, Shift or left Command. Option, Fn and Right
    /// Command are allowed because the user may still be holding the
    /// push-to-talk key. Command without a device bit counts as left.
    static func shouldCancel(keyCode: Int64, flags: CGEventFlags) -> Bool {
        guard keyCode == Int64(kVK_Escape) else { return false }
        guard flags.intersection([.maskControl, .maskShift]).isEmpty else { return false }
        if flags.contains(.maskCommand) {
            let leftCommand = CGEventFlags(rawValue: 0x08) // NX_DEVICELCMDKEYMASK
            let rightCommand = CGEventFlags(rawValue: 0x10) // NX_DEVICERCMDKEYMASK
            return flags.contains(rightCommand) && !flags.contains(leftCommand)
        }
        return true
    }

    func activate() {
        guard !isActive else { return }
        // macOS invalidates the tap when Accessibility is revoked. Rebuild it
        // so Escape works again after a re-grant without a relaunch.
        if let tap, !CFMachPortIsValid(tap) {
            DiagLog.log("cancel key tap was invalidated; recreating it")
            discardTap()
        }
        if tap == nil, !createTap() { return }
        isActive = true
        setTapEnabled(true)
    }

    func deactivate() {
        guard isActive else { return }
        isActive = false
        setTapEnabled(false)
    }

    /// Stops the tap thread's run loop so the thread exits, and forgets the
    /// tap. The next `createTap` starts a fresh thread.
    private func discardTap() {
        if let tapRunLoop {
            CFRunLoopStop(tapRunLoop)
        }
        tap = nil
        tapRunLoop = nil
    }

    private func setTapEnabled(_ enabled: Bool) {
        guard let tapRunLoop else { return }
        CFRunLoopPerformBlock(tapRunLoop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            guard let self, let threadTap = self.threadTap else { return }
            self.wantsEnabled = enabled
            CGEvent.tapEnable(tap: threadTap, enable: enabled)
        }
        CFRunLoopWakeUp(tapRunLoop)
    }

    /// Tries an active tap first so Escape is swallowed. A listen-only tap
    /// still cancels, but the frontmost app sees the Escape too.
    private func createTap() -> Bool {
        for option in [CGEventTapOptions.defaultTap, .listenOnly] {
            if createTap(option) {
                DiagLog.log("cancel key tap created (%@)",
                      option == .listenOnly ? "listen-only" : "active")
                return true
            }
        }
        // activate() retries on every dictation; log at most once a minute.
        if lastCreateFailureLog.map({ Date().timeIntervalSince($0) >= 60 }) ?? true {
            lastCreateFailureLog = Date()
            DiagLog.log("cancel key tap could not be created; Escape won't cancel dictations")
        }
        return false
    }

    private func createTap(_ option: CGEventTapOptions) -> Bool {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<CancelKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            return monitor.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: option,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        self.tap = tap

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        // Same reason as HotkeyManager: a tap on the main run loop would
        // stall system input whenever the main thread is busy.
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            if let self {
                self.tapRunLoop = CFRunLoopGetCurrent()
                self.threadTap = tap
            }
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: false)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "LocalFlow.CancelKeyTap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        return true
    }

    /// Returns true when the event should be swallowed.
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        // macOS disables taps that stall; re-enable if we still want it on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if wantsEnabled, let threadTap { CGEvent.tapEnable(tap: threadTap, enable: true) }
            DispatchQueue.main.async {
                DiagLog.log("cancel key tap disabled by system (%d)", type.rawValue)
            }
            return false
        }
        guard type == .keyDown, wantsEnabled,
              Self.shouldCancel(keyCode: event.getIntegerValueField(.keyboardEventKeycode),
                                flags: event.flags) else { return false }
        DispatchQueue.main.async {
            // Dropped if the dictation ended while this hop was queued.
            guard self.isActive else { return }
            self.onCancel?()
        }
        return true
    }
}
