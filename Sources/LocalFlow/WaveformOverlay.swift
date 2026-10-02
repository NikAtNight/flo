import AppKit

/// Floating "listening" HUD shown while the hotkey is held: a non-activating
/// panel at the bottom-center of the screen, draggable to wherever the user
/// wants it (the spot persists across launches). The visual itself is
/// whichever HudTheme the user picked — system glass for Liquid Glass, a
/// frosted capsule for most themes, and no chrome for the bare themes. With
/// live transcript on, a text panel opens above the capsule once the first
/// words arrive.
@MainActor
final class WaveformOverlay {
    private let panel: NSPanel
    private var content: HudContentView
    private var acceptsTranscript = false
    private var hideGeneration = 0
    private var previewTimer: Timer?
    // Distinguishes the app's own present/layout moves from a user drag —
    // only drags may persist the origin.
    private var programmaticMove = false
    private var moveObserver: NSObjectProtocol?
    // Audio buffers can arrive much faster than the HUD's 30 fps refresh.
    // Coalesce their peaks so the capture queue never floods the main queue
    // with redundant view updates.
    nonisolated private let inputLock = NSLock()
    nonisolated(unsafe) private var pendingLevel: Float?
    nonisolated(unsafe) private var pendingSpectrum: [Float]?
    nonisolated(unsafe) private var inputDrainScheduled = false

    init() {
        content = HudContentView(theme: HudTheme.current, liveTranscript: Settings.liveTranscript)
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: content.frame.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        // Draggable, and .nonactivatingPanel keeps the drag from stealing
        // focus from the app being dictated into. The empty space reserved
        // for the transcript panel stays click-through via HudContentView's
        // hitTest.
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentView = content

        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.programmaticMove, self.panel.isVisible else { return }
                // The saved origin is the capsule's, so it survives the
                // transcript panel being turned on or off or flipping sides.
                Settings.hudOrigin = HudLayout.capsuleOrigin(
                    windowOrigin: self.panel.frame.origin,
                    placement: self.content.placement,
                    reserve: self.content.reserve
                )
            }
        }
    }

    private func rebuildContent() {
        content.hudView.stopAnimating() // the outgoing view's timer must not outlive it
        content = HudContentView(theme: HudTheme.current, liveTranscript: Settings.liveTranscript)
        programmaticMove = true
        panel.setContentSize(content.frame.size)
        programmaticMove = false
        panel.contentView = content
    }

    /// Thread-safe: callable from the audio capture thread.
    nonisolated func push(level: Float) {
        inputLock.lock()
        pendingLevel = max(pendingLevel ?? level, level)
        let shouldSchedule = !inputDrainScheduled
        inputDrainScheduled = true
        inputLock.unlock()

        if shouldSchedule {
            DispatchQueue.main.async { [weak self] in self?.drainInput() }
        }
    }

    /// Thread-safe: callable from the audio capture thread.
    nonisolated func push(spectrum: [Float]) {
        inputLock.lock()
        if var pendingSpectrum {
            if pendingSpectrum.count < spectrum.count {
                pendingSpectrum.append(contentsOf: spectrum[pendingSpectrum.count...])
            }
            for i in 0..<min(pendingSpectrum.count, spectrum.count) {
                pendingSpectrum[i] = max(pendingSpectrum[i], spectrum[i])
            }
            self.pendingSpectrum = pendingSpectrum
        } else {
            pendingSpectrum = spectrum
        }
        let shouldSchedule = !inputDrainScheduled
        inputDrainScheduled = true
        inputLock.unlock()

        if shouldSchedule {
            DispatchQueue.main.async { [weak self] in self?.drainInput() }
        }
    }

    private func drainInput() {
        inputLock.lock()
        let level = pendingLevel
        let spectrum = pendingSpectrum
        pendingLevel = nil
        pendingSpectrum = nil
        inputDrainScheduled = false
        inputLock.unlock()

        if let level { content.hudView.ingest(level: level) }
        if let spectrum { content.hudView.ingest(spectrum: spectrum) }
    }

    /// Hotkey pressed: the mic engine is starting but no audio has arrived
    /// yet — a Bluetooth mic can take seconds.
    func show() {
        cancelPreview()
        present(phase: .warming)
    }

    /// First real audio buffer arrived — snap to the full-brightness waveform.
    func captureLive() {
        content.setPhase(.live)
    }

    /// Hotkey released: keep the panel up as an indeterminate loading state
    /// until the pipeline resolves and the caller hides it (or a new press
    /// takes the panel over via show()).
    func beginProcessing() {
        content.setPhase(.processing)
    }

    /// Raw text of the chunks finished so far. Ignored once the HUD is
    /// hiding, so a late chunk can't write into the next press's panel.
    func showTranscript(_ text: String) {
        guard acceptsTranscript else { return }
        content.setTranscript(text, animated: true)
    }

    func hide() {
        cancelPreview()
        acceptsTranscript = false
        hideGeneration += 1
        let generation = hideGeneration
        content.hudView.stopAnimating()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // Skip the orderOut if show() ran again during the fade.
                guard let self, self.hideGeneration == generation else { return }
                self.panel.orderOut(nil)
            }
        })
    }

    private func present(phase: HudView.Phase) {
        if HudTheme.current != content.theme || Settings.liveTranscript != content.showsTranscript {
            rebuildContent()
        }
        hideGeneration += 1
        content.setTranscript("", animated: false)
        acceptsTranscript = true

        let screens = NSScreen.screens.map(\.visibleFrame)
        let capsuleSize = content.theme.size
        let reserve = content.reserve
        let capsuleOrigin: NSPoint
        if let saved = Settings.hudOrigin,
           Self.isVisible(origin: HudLayout.windowOrigin(
                              capsuleOrigin: saved,
                              placement: HudLayout.placement(
                                  capsuleFrame: NSRect(origin: saved, size: capsuleSize),
                                  reserve: reserve, screens: screens),
                              reserve: reserve),
                          size: content.frame.size,
                          on: screens) {
            capsuleOrigin = saved
        } else {
            // Default bottom-center — also the fallback when the saved spot
            // is on a screen that is no longer connected.
            guard let screen = NSScreen.main else { return }
            capsuleOrigin = NSPoint(x: screen.visibleFrame.midX - capsuleSize.width / 2,
                                    y: screen.visibleFrame.minY + 64)
        }
        content.placement = HudLayout.placement(
            capsuleFrame: NSRect(origin: capsuleOrigin, size: capsuleSize),
            reserve: reserve, screens: screens)
        programmaticMove = true
        panel.setFrameOrigin(HudLayout.windowOrigin(capsuleOrigin: capsuleOrigin,
                                                    placement: content.placement,
                                                    reserve: reserve))
        programmaticMove = false

        content.hudView.reset()
        content.setPhase(phase)
        content.hudView.startAnimating()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }
    }

    /// Whether a window of `size` at `origin` still lands on any connected
    /// screen — a position saved on a since-removed display must not leave
    /// the HUD invisible and undraggable.
    nonisolated static func isVisible(
        origin: NSPoint,
        size: NSSize,
        on screenFrames: [NSRect]
    ) -> Bool {
        let rect = NSRect(origin: origin, size: size)
        return screenFrames.contains { $0.intersects(rect) }
    }

    // MARK: - Menu preview

    /// Sample dictation fed to the theme preview when live transcript is on,
    /// so picking a theme also shows how its text panel looks.
    private static let previewLines: [(at: TimeInterval, text: String)] = [
        (0.5, "Okay, quick note for tomorrow."),
        (1.3, "Move the design review to two."),
        (2.1, "Ask Priya for the final mockups"),
        (2.8, "and book a room with a screen."),
    ]

    /// Shows the HUD for a few seconds fed by synthesized "speech" so a theme
    /// picked from the menu can be judged without dictating anything.
    func preview() {
        cancelPreview()
        present(phase: .live)
        acceptsTranscript = false // real chunks never land in a preview
        let start = Date()
        var linesShown = 0
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let t = Date().timeIntervalSince(start)
                if t > 3.6 {
                    self.cancelPreview()
                    self.hide()
                    return
                }
                let level = SyntheticSpeech.level(at: t)
                self.content.hudView.ingest(level: level)
                self.content.hudView.ingest(spectrum: SyntheticSpeech.spectrum(at: t, level: level))
                let due = Self.previewLines.filter { $0.at <= t }.count
                if due > linesShown {
                    linesShown = due
                    let text = Self.previewLines.prefix(due).map(\.text).joined(separator: " ")
                    self.content.setTranscript(text, animated: true)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        previewTimer = timer
    }

    private func cancelPreview() {
        previewTimer?.invalidate()
        previewTimer = nil
    }
}

/// The drawing surface: latches the loudest level and band energies between
/// ticks (audio buffers arrive slower than 30 fps), applies auto-gain to the
/// spectrum so any mic lands in 0…1, and hands each frame to the renderer.
/// Flipped so renderer coordinates are y-down, matching the design prototypes.
final class HudView: NSView {
    override var isFlipped: Bool { true }

    /// Lifecycle states drawn on top of (or instead of) the theme renderer,
    /// so all 17 themes get them without per-renderer changes:
    /// warming = mic starting but no audio yet, live = normal waveform,
    /// processing = transcription running after release.
    enum Phase {
        case warming, live, processing
    }

    private let renderer: HudRenderer
    private(set) var phase: Phase = .live
    private var phaseStart: CGFloat = 0 // `time` when the phase was entered
    private var latchedLevel: CGFloat = 0
    private var latchedSpectrum = [CGFloat](repeating: 0, count: 12)
    private var frameLevel: CGFloat = 0
    private var frameSpectrum = [CGFloat](repeating: 0, count: 12)
    private var agcReference: CGFloat = 0.0035
    private var agcSpeechPeak: CGFloat = 0.3
    private var agcNoiseFloor: CGFloat = 0.05
    private var lastLevelIngest: TimeInterval = 0
    private(set) var time: CGFloat = 0 // seconds since reset(), i.e. since the HUD appeared
    private var timer: Timer?
    /// Runs after every frame step, so the transcript panel's caret and
    /// timer share the HUD's clock.
    var onTick: (() -> Void)?

    /// Seconds the dictation has run, frozen once processing starts.
    var elapsed: CGFloat { phase == .processing ? phaseStart : time }

    init(frame: NSRect, renderer: HudRenderer) {
        self.renderer = renderer
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func ingest(level: Float) {
        // Wall-clock dt: this runs per audio buffer, and cadence varies
        // wildly by route (~100/s for the desk mic, ~50/s for HFP), so
        // per-call smoothing factors drift by mic.
        let now = ProcessInfo.processInfo.systemUptime
        let dt = lastLevelIngest > 0
            ? min(0.25, max(0.001, CGFloat(now - lastLevelIngest)))
            : 0.02
        lastLevelIngest = now
        let raw = CGFloat(level)

        // Room-noise estimate: falls fast in silence, creeps up slowly so
        // sustained speech can't masquerade as room tone (inter-word dips
        // keep pulling it back down to the true floor).
        agcNoiseFloor = raw < agcNoiseFloor
            ? agcNoiseFloor + (raw - agcNoiseFloor) * (1 - exp(-dt / 0.5))
            : min(raw, agcNoiseFloor + 0.008 * dt)

        // Work in log-ratio above the room, not linear gap: a far-field
        // desk mic's conversational speech peaks a mere ~5 dB over its own
        // room tone (-45 vs -50 dBFS measured), so any linear span crushes
        // it to nothing — while the same voice on AirPods' compressed HFP
        // route sits ~40 dB up. The ratio is what carries the voice on
        // every route.
        let snr = max(0, log(raw / max(0.02, agcNoiseFloor)))

        // Speech-peak envelope: how far above the room this speaker + mic
        // reaches when talking normally. The slow attack means a raised
        // voice pins the display for seconds before it recalibrates; the
        // slow release means pauses don't reset the calibration.
        agcSpeechPeak = snr > agcSpeechPeak
            ? agcSpeechPeak + (snr - agcSpeechPeak) * (1 - exp(-dt / 6))
            : max(agcSpeechPeak * exp(-dt / 25), 0.3)

        // Ceiling = the speaker's usual peak + ~6 dB of headroom, so
        // conversational speech reads mid-strip and louder-than-usual
        // still has somewhere to tower. The exponent keeps room-tone
        // jitter hugging the centerline.
        let normalized = min(1, snr / (agcSpeechPeak + 0.35))
        latchedLevel = max(latchedLevel, pow(normalized, 1.3))
    }

    func ingest(spectrum: [Float]) {
        let n = min(spectrum.count, latchedSpectrum.count)
        var peak: CGFloat = 0
        for i in 0..<n { peak = max(peak, CGFloat(spectrum[i])) }
        // Slow-decay reference: band energies vary wildly across mics, so
        // normalize against the recent loudest band rather than a constant.
        agcReference = max(agcReference * 0.995, peak, 0.0035)
        for i in 0..<n {
            let v = min(1, pow(CGFloat(spectrum[i]) / agcReference, 0.75))
            latchedSpectrum[i] = max(latchedSpectrum[i], v)
        }
    }

    func setPhase(_ newPhase: Phase) {
        guard newPhase != phase else { return }
        phase = newPhase
        phaseStart = time
        needsDisplay = true
    }

    func reset() {
        time = 0
        phaseStart = 0
        latchedLevel = 0
        latchedSpectrum = [CGFloat](repeating: 0, count: 12)
        frameLevel = 0
        frameSpectrum = [CGFloat](repeating: 0, count: 12)
        renderer.reset()
        needsDisplay = true
    }

    func startAnimating() {
        stopAnimating()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopAnimating() {
        timer?.invalidate()
        timer = nil
    }

    func tick() {
        time += 1.0 / 30.0
        frameLevel = min(1, latchedLevel)
        latchedLevel = 0
        frameSpectrum = latchedSpectrum
        // Decay instead of clearing: audio buffers arrive slower than ticks,
        // and a hard clear makes spectrum-driven themes strobe.
        for i in latchedSpectrum.indices { latchedSpectrum[i] *= 0.55 }
        needsDisplay = true
        onTick?()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        switch phase {
        case .live:
            renderTheme(in: ctx)
        case .warming:
            // No theme while waiting — its appearance IS the "talk now"
            // signal, which a dimmed rendering muddied on themes whose idle
            // motion looks like their live one (starfields). Dots appear
            // after a grace delay, so a mic that goes live quickly never
            // shows the explicit "wait" treatment.
            let breath = 0.5 + 0.5 * sin(time * 3.0)
            let fade = min(1, max(0, (time - phaseStart - 0.18) / 0.25))
            if fade > 0 {
                drawWaitBackdrop(in: ctx, alpha: fade)
                let pulse = 0.55 + 0.4 * breath
                drawDots(in: ctx, alphas: [CGFloat](repeating: pulse * fade, count: 3))
            }
        case .processing:
            let fade = min(1, max(0, (time - phaseStart) / 0.2))
            drawWaitBackdrop(in: ctx, alpha: fade)
            // Left-to-right chase: indeterminate "working", distinct from
            // the warming state's in-unison pulse.
            let alphas = (0..<3).map { i -> CGFloat in
                let wave = max(0, sin(time * 5.0 - CGFloat(i) * 1.1))
                return (0.4 + 0.55 * wave) * fade
            }
            drawDots(in: ctx, alphas: alphas)
        }
    }

    /// Dark capsule behind the waiting dots. The waiting states hide the
    /// theme, and several themes draw their own background — without this
    /// the dots sit directly on the desktop and can disappear against it.
    private func drawWaitBackdrop(in ctx: CGContext, alpha: CGFloat) {
        let capsule = CGRect(x: bounds.midX - 48, y: bounds.midY - 16,
                             width: 96, height: 32)
        let path = CGPath(roundedRect: capsule, cornerWidth: 16,
                          cornerHeight: 16, transform: nil)
        ctx.saveGState()
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.55 * alpha).cgColor)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.restoreGState()
    }

    private func renderTheme(in ctx: CGContext) {
        renderer.render(in: ctx, bounds: bounds, t: time, dt: 1.0 / 30.0,
                        level: frameLevel, spectrum: frameSpectrum)
    }

    /// Three small dots centered in the HUD — the shared theme-agnostic
    /// vocabulary for both waiting states. The soft shadow keeps them
    /// readable when a bare theme puts them straight over a light desktop.
    private func drawDots(in ctx: CGContext, alphas: [CGFloat]) {
        let radius: CGFloat = 4
        let spacing: CGFloat = 17
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 4,
                      color: NSColor.black.withAlphaComponent(0.5).cgColor)
        for (i, alpha) in alphas.enumerated() {
            let x = bounds.midX + (CGFloat(i) - 1) * spacing
            ctx.setFillColor(NSColor.white.withAlphaComponent(alpha).cgColor)
            ctx.fillEllipse(in: CGRect(x: x - radius, y: bounds.midY - radius,
                                       width: radius * 2, height: radius * 2))
        }
        ctx.restoreGState()
    }
}

/// Which side of the capsule the transcript panel opens on. Above is the
/// default; below is for a capsule parked near the top of its screen, where
/// growing upward would run off the edge.
enum TranscriptPlacement {
    case above, below
}

/// Pure geometry for the HUD window. The window is the capsule plus, when
/// live transcript is on, a reserve of `gap + panelMaxHeight` on the
/// panel's side, so the panel can open without moving or resizing the
/// window. `Settings.hudOrigin` is always the capsule's bottom-left.
enum HudLayout {
    static let gap: CGFloat = 6
    static let fontSize: CGFloat = 15
    static let lineHeight: CGFloat = fontSize * 1.35
    static let maxLines = 3
    /// Padding on the panel's edge away from the capsule and next to it.
    static let farPadding: CGFloat = 12
    static let nearPadding: CGFloat = 10
    static let sidePadding: CGFloat = 14

    /// Panel height for `lineCount` wrapped lines: 0 while closed, capped at
    /// `maxLines` (older lines scroll off under the top fade).
    static func panelHeight(lineCount: Int) -> CGFloat {
        guard lineCount > 0 else { return 0 }
        let lines = CGFloat(min(lineCount, maxLines))
        return ceil(farPadding + lines * lineHeight + nearPadding)
    }

    static var panelMaxHeight: CGFloat { panelHeight(lineCount: maxLines) }

    /// Extra window height beyond the capsule.
    static func reserve(liveTranscript: Bool) -> CGFloat {
        liveTranscript ? gap + panelMaxHeight : 0
    }

    static func windowSize(capsule: NSSize, reserve: CGFloat) -> NSSize {
        NSSize(width: capsule.width, height: capsule.height + reserve)
    }

    /// The capsule sits at the bottom of the window when the panel opens
    /// above it, and at the top when the panel opens below.
    static func capsuleOffset(placement: TranscriptPlacement, reserve: CGFloat) -> CGFloat {
        placement == .below ? reserve : 0
    }

    static func windowOrigin(capsuleOrigin: NSPoint, placement: TranscriptPlacement,
                             reserve: CGFloat) -> NSPoint {
        NSPoint(x: capsuleOrigin.x,
                y: capsuleOrigin.y - capsuleOffset(placement: placement, reserve: reserve))
    }

    static func capsuleOrigin(windowOrigin: NSPoint, placement: TranscriptPlacement,
                              reserve: CGFloat) -> NSPoint {
        NSPoint(x: windowOrigin.x,
                y: windowOrigin.y + capsuleOffset(placement: placement, reserve: reserve))
    }

    /// Opens the panel below the capsule when there isn't room for it above
    /// on the capsule's screen (the visible frame, so the menu bar counts).
    static func placement(capsuleFrame: NSRect, reserve: CGFloat,
                          screens: [NSRect]) -> TranscriptPlacement {
        guard reserve > 0 else { return .above }
        let center = NSPoint(x: capsuleFrame.midX, y: capsuleFrame.midY)
        guard let screen = screens.first(where: { $0.contains(center) })
                ?? screens.first(where: { $0.intersects(capsuleFrame) }) else { return .above }
        return capsuleFrame.maxY + reserve > screen.maxY ? .below : .above
    }
}

/// Everything inside the HUD window: the theme's capsule, unchanged, and,
/// when live transcript is on, the transcript panel in the reserved space.
final class HudContentView: NSView {
    let theme: HudTheme
    let showsTranscript: Bool
    let hudView: HudView
    let reserve: CGFloat
    private let capsule: NSView
    private let transcript: TranscriptPanelView?
    private var panelOpen = false

    var placement: TranscriptPlacement = .above {
        didSet {
            guard placement != oldValue else { return }
            layoutPieces()
        }
    }

    init(theme: HudTheme, liveTranscript: Bool) {
        self.theme = theme
        showsTranscript = liveTranscript
        reserve = HudLayout.reserve(liveTranscript: liveTranscript)
        let size = theme.size
        let bounds = NSRect(origin: .zero, size: size)
        hudView = HudView(frame: bounds, renderer: theme.makeRenderer())
        hudView.autoresizingMask = [.width, .height]
        capsule = Self.makeCapsule(theme: theme, hudView: hudView, bounds: bounds)
        transcript = liveTranscript ? TranscriptPanelView(theme: theme, width: size.width) : nil
        super.init(frame: NSRect(origin: .zero,
                                 size: HudLayout.windowSize(capsule: size, reserve: reserve)))
        addSubview(capsule)
        if let transcript { addSubview(transcript) }
        hudView.onTick = { [weak self] in self?.tick() }
        layoutPieces()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static func makeCapsule(theme: HudTheme, hudView: HudView, bounds: NSRect) -> NSView {
        guard let surface = makeSurface(theme: theme, frame: bounds,
                                        cornerRadius: bounds.height / 2) else {
            let bare = NSView(frame: bounds)
            bare.addSubview(hudView)
            return bare
        }
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), let glass = surface as? NSGlassEffectView {
            glass.contentView = hudView
            return glass
        }
        #endif
        surface.addSubview(hudView)
        return surface
    }

    /// The theme's background: system glass for Liquid Glass, a frosted blur
    /// with a hairline for the rest, nil for bare themes. Shared by the
    /// capsule and the transcript panel so the two pieces read as one card.
    static func makeSurface(theme: HudTheme, frame: NSRect, cornerRadius: CGFloat) -> NSView? {
        if theme.isBare { return nil }
        if theme == .liquidGlass {
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                let glass = NSGlassEffectView(frame: frame)
                glass.style = .regular
                glass.cornerRadius = cornerRadius
                glass.tintColor = NSColor.white.withAlphaComponent(0.025)
                glass.wantsLayer = true
                glass.layer?.cornerRadius = cornerRadius
                glass.layer?.cornerCurve = .continuous
                glass.layer?.masksToBounds = true
                return glass
            }
            #endif
        }
        let blur = NSVisualEffectView(frame: frame)
        blur.material = .hudWindow
        blur.state = .active
        blur.blendingMode = .behindWindow
        blur.wantsLayer = true
        blur.layer?.cornerRadius = cornerRadius
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true
        blur.layer?.borderWidth = 1
        blur.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        return blur
    }

    func setPhase(_ phase: HudView.Phase) {
        hudView.setPhase(phase)
        tick()
    }

    /// Opens the panel on the first non-empty text, then tracks its line
    /// count. Empty text closes it at once (a new dictation starting).
    func setTranscript(_ rawText: String, animated: Bool) {
        guard let transcript else { return }
        let text = rawText.replacingOccurrences(of: "\n", with: " ")
        transcript.text = text
        tick()
        let height = HudLayout.panelHeight(lineCount: text.isEmpty ? 0 : transcript.lineCount)
        guard height > 0 else {
            panelOpen = false
            transcript.alphaValue = 0
            transcript.frame = panelFrame(height: 0)
            return
        }
        let opening = !panelOpen
        panelOpen = true
        guard animated else {
            transcript.alphaValue = 1
            transcript.frame = panelFrame(height: height)
            return
        }
        if opening {
            // Pop in from slightly narrower, anchored on the capsule side.
            transcript.frame = panelFrame(height: 0, widthScale: 0.96)
            transcript.alphaValue = 0
        } else if transcript.frame.height == height {
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = opening ? 0.3 : 0.2
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
            transcript.animator().frame = panelFrame(height: height)
            transcript.animator().alphaValue = 1
        }
    }

    /// The reserved space must not swallow clicks meant for whatever is
    /// under it: only the capsule and an open panel are hit-testable.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        let inPanel = openTranscriptFrame?.contains(local) ?? false
        guard capsule.frame.contains(local) || inPanel else { return nil }
        return super.hitTest(point)
    }

    var capsuleFrame: NSRect { capsule.frame }

    /// The transcript panel's frame while it is open; nil while closed.
    var openTranscriptFrame: NSRect? { panelOpen ? transcript?.frame : nil }

    private func layoutPieces() {
        capsule.setFrameOrigin(NSPoint(
            x: 0, y: HudLayout.capsuleOffset(placement: placement, reserve: reserve)))
        guard let transcript else { return }
        transcript.placement = placement
        transcript.frame = panelFrame(height: transcript.frame.height)
    }

    private func panelFrame(height: CGFloat, widthScale: CGFloat = 1) -> NSRect {
        let width = (bounds.width * widthScale).rounded()
        let x = ((bounds.width - width) / 2).rounded()
        switch placement {
        case .above:
            return NSRect(x: x, y: capsule.frame.maxY + HudLayout.gap, width: width, height: height)
        case .below:
            return NSRect(x: x, y: capsule.frame.minY - HudLayout.gap - height,
                          width: width, height: height)
        }
    }

    private func tick() {
        transcript?.update(time: hudView.time, elapsed: hudView.elapsed,
                           listening: hudView.phase != .processing)
    }
}

/// Live transcript above (or below) the capsule, after Handy's Live
/// overlay: up to three wrapped lines of 15 pt italic, newest at the bottom,
/// older lines dissolving under a top fade once they overflow, a blinking
/// caret while listening, and the elapsed time in the corner.
private final class TranscriptPanelView: NSView {
    private static let font: NSFont = {
        let base = NSFont.systemFont(ofSize: HudLayout.fontSize)
        let italic = base.fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: italic, size: HudLayout.fontSize) ?? base
    }()
    private static let timerFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    private static let fadeHeight: CGFloat = 18
    private static let caretBlink: CGFloat = 1.05

    var placement: TranscriptPlacement = .above {
        didSet {
            // Keep the text pinned to the capsule side while the open
            // animation resizes the panel.
            let anchor: NSView.LayerContentsPlacement = placement == .above ? .bottom : .top
            layerContentsPlacement = anchor
            subviews.forEach { $0.layerContentsPlacement = anchor }
            redraw()
        }
    }
    private(set) var lineCount = 0
    var text = "" {
        didSet {
            guard text != oldValue else { return }
            relayout()
            redraw()
        }
    }

    private let bare: Bool
    /// Text is laid out at the panel's full width even while the pop-in
    /// animation runs narrower, so lines don't reflow mid-animation.
    private let layoutWidth: CGFloat
    private let timerReserve: CGFloat
    private let storage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let container: NSTextContainer
    private var caretOn = true
    private var listening = true
    private var elapsedSeconds = 0

    override var isFlipped: Bool { true }

    init(theme: HudTheme, width: CGFloat) {
        bare = theme.isBare
        layoutWidth = width - HudLayout.sidePadding * 2
        // Sized for "m:ss"; past ten minutes the wider timer can touch a full
        // last line, which isn't worth a reflow every minute.
        timerReserve = ceil(("0:00" as NSString).size(withAttributes: [.font: Self.timerFont]).width) + 6
        container = NSTextContainer(size: NSSize(width: layoutWidth,
                                                 height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 0))
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layerContentsRedrawPolicy = .duringViewResize
        layerContentsPlacement = .bottom
        alphaValue = 0
        if let surface = HudContentView.makeSurface(theme: theme, frame: bounds, cornerRadius: 16) {
            surface.autoresizingMask = [.width, .height]
            addSubview(surface)
            let ink = TranscriptInkView(frame: bounds)
            ink.autoresizingMask = [.width, .height]
            ink.layerContentsRedrawPolicy = .duringViewResize
            ink.layerContentsPlacement = .bottom
            ink.panel = self
            addSubview(ink)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Called every HUD frame: steps the caret blink and the timer, and
    /// redraws only when one of them visibly changed.
    func update(time: CGFloat, elapsed: CGFloat, listening: Bool) {
        let caretOn = (time / (Self.caretBlink / 2)).truncatingRemainder(dividingBy: 2) < 1
        let seconds = Int(elapsed)
        guard caretOn != self.caretOn || seconds != elapsedSeconds
                || listening != self.listening else { return }
        self.caretOn = caretOn
        self.elapsedSeconds = seconds
        self.listening = listening
        redraw()
    }

    private func redraw() {
        needsDisplay = true
        subviews.forEach { $0.needsDisplay = true }
    }

    private func relayout() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = HudLayout.lineHeight
        paragraph.maximumLineHeight = HudLayout.lineHeight
        paragraph.lineBreakMode = .byWordWrapping
        let natural = Self.font.ascender - Self.font.descender
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.font,
            .foregroundColor: NSColor.white.withAlphaComponent(0.9),
            .paragraphStyle: paragraph,
            .kern: -0.003 * HudLayout.fontSize,
            // TextKit puts extra line height above the glyphs; split it.
            .baselineOffset: (HudLayout.lineHeight - natural) / 2,
        ]
        let string = NSMutableAttributedString(string: text, attributes: attributes)
        if !text.isEmpty {
            // A no-break space glued to the last word, widened by kerning,
            // keeps room on the last line for the caret and the timer.
            var tail = attributes
            tail[.kern] = timerReserve
            string.append(NSAttributedString(string: "\u{00A0}", attributes: tail))
        }
        storage.setAttributedString(string)
        layoutManager.ensureLayout(for: container)
        var count = 0
        let glyphs = layoutManager.glyphRange(for: container)
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, _, _ in
            count += 1
        }
        lineCount = text.isEmpty ? 0 : count
    }

    override func draw(_ dirtyRect: NSRect) {
        guard bare, lineCount > 0 else { return }
        // Bare themes have no frosted surface to match, so the panel gets a
        // near-opaque fill that keeps text readable on any desktop.
        let path = NSBezierPath(roundedRect: bounds, xRadius: 16, yRadius: 16)
        NSColor.black.withAlphaComponent(0.78).setFill()
        path.fill()
        drawInk()
    }

    /// Text, caret, fade and timer. Shared by the bare panel's own draw and
    /// the ink view layered over the surface.
    func drawInk() {
        guard lineCount > 0, let ctx = NSGraphicsContext.current?.cgContext else { return }
        if bare {
            let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                      xRadius: 15.5, yRadius: 15.5)
            NSColor.white.withAlphaComponent(0.14).setStroke()
            border.lineWidth = 1
            border.stroke()
        }
        let topPadding = placement == .above ? HudLayout.farPadding : HudLayout.nearPadding
        let bottomPadding = placement == .above ? HudLayout.nearPadding : HudLayout.farPadding
        let overflowing = lineCount > HudLayout.maxLines
        let blockHeight = CGFloat(lineCount) * HudLayout.lineHeight
        // Anchored on the capsule's side while it fits; pinned to the newest
        // line at the bottom once it overflows.
        let originY = placement == .below && !overflowing
            ? topPadding
            : bounds.height - bottomPadding - blockHeight
        let origin = NSPoint(x: ((bounds.width - layoutWidth) / 2).rounded(), y: originY)

        let glyphs = layoutManager.glyphRange(for: container)
        let tailGlyph = layoutManager.glyphIndexForCharacter(at: storage.length - 1)
        let tailLine = layoutManager.lineFragmentRect(forGlyphAt: tailGlyph, effectiveRange: nil)
        let tailLocation = layoutManager.location(forGlyphAt: tailGlyph)
        let baseline = origin.y + tailLine.minY + tailLocation.y

        ctx.saveGState()
        ctx.clip(to: bounds)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        layoutManager.drawGlyphs(forGlyphRange: glyphs, at: origin)
        if listening && caretOn {
            // 2 pt wide, 1.02 em tall, sitting 3 pt below the baseline.
            let height = 1.02 * HudLayout.fontSize
            let caret = NSRect(x: origin.x + tailLine.minX + tailLocation.x + 1,
                               y: baseline + 3 - height, width: 2, height: height)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: caret, xRadius: 1, yRadius: 1).fill()
        }
        if overflowing {
            // Older lines dissolve under the top edge.
            let colors = [NSColor.black.cgColor, NSColor.black.withAlphaComponent(0).cgColor]
            if let gradient = CGGradient(colorsSpace: nil, colors: colors as CFArray,
                                         locations: [0, 1]) {
                ctx.setBlendMode(.destinationOut)
                ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0),
                                       end: CGPoint(x: 0, y: Self.fadeHeight), options: [])
            }
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()

        let timer = String(format: "%d:%02d", elapsedSeconds / 60, elapsedSeconds % 60)
        let timerAttributes: [NSAttributedString.Key: Any] = [
            .font: Self.timerFont,
            .foregroundColor: NSColor.white.withAlphaComponent(0.6),
        ]
        let timerWidth = (timer as NSString).size(withAttributes: timerAttributes).width
        let timerX = bounds.width - (bounds.width - layoutWidth) / 2 - timerWidth
        (timer as NSString).draw(at: NSPoint(x: timerX, y: baseline - Self.timerFont.ascender),
                                 withAttributes: timerAttributes)
    }
}

/// Draws the panel's text above its surface view (a view's own drawing sits
/// under its subviews, so the surface would cover it).
private final class TranscriptInkView: NSView {
    weak var panel: TranscriptPanelView?
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        panel?.drawInk()
    }
}
