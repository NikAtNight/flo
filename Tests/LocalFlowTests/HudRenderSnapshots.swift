import AppKit
import XCTest
@testable import LocalFlow

/// Offscreen renders of the HUD window content for eyeballing layout
/// changes. Skipped unless LOCALFLOW_RENDER_DIR is set:
///
///     LOCALFLOW_RENDER_DIR=/tmp/hud-renders swift test --filter HudRenderSnapshots
///
/// NSVisualEffectView and NSGlassEffectView have nothing behind them to blur
/// offscreen, so each render sits on a mid-gray backdrop that stands in for
/// the desktop.
@MainActor
final class HudRenderSnapshots: XCTestCase {
    private static let oneSentence = "Okay, quick note for tomorrow."
    private static let threeSentences = "Okay, quick note for tomorrow. Move the design review to "
        + "two o'clock and ask Priya for the final mockups before then. "
        + "Also book a room with a big screen for the whole team."

    private enum State: String, CaseIterable {
        case closed = "a-closed"
        case oneSentence = "b-one-sentence"
        case overflowLive = "c-overflow-live"
        case overflowProcessing = "d-overflow-processing"
        case transcriptOff = "e-transcript-off"
        case overflowBelow = "f-overflow-below"
    }

    func testRenderOverlayStates() throws {
        guard let dir = ProcessInfo.processInfo.environment["LOCALFLOW_RENDER_DIR"] else {
            throw XCTSkip("Set LOCALFLOW_RENDER_DIR to write HUD renders")
        }
        let directory = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for theme in [HudTheme.classic, .typeset, .ticker, .bolide, .liquidGlass] {
            for state in State.allCases {
                let content = makeContent(theme: theme, state: state)
                let png = try XCTUnwrap(render(content))
                try png.write(to: directory.appendingPathComponent("\(theme.rawValue)-\(state.rawValue).png"))
            }
            // With live transcript off the window must be the bare capsule,
            // pixel for pixel.
            let off = makeContent(theme: theme, state: .transcriptOff)
            XCTAssertEqual(off.frame.size, theme.size)
        }
    }

    private func makeContent(theme: HudTheme, state: State) -> HudContentView {
        let content = HudContentView(theme: theme, liveTranscript: state != .transcriptOff)
        if state == .overflowBelow { content.placement = .below }
        content.hudView.reset()
        content.setPhase(.live)
        // 7.5 s of synthetic speech: the theme has something to draw, the
        // timer reads 0:07, and the caret is in the "on" half of its blink.
        for frame in 0..<225 {
            let t = Double(frame) / 30
            let level = SyntheticSpeech.level(at: t)
            content.hudView.ingest(level: level)
            content.hudView.ingest(spectrum: SyntheticSpeech.spectrum(at: t, level: level))
            content.hudView.tick()
        }
        switch state {
        case .closed, .transcriptOff:
            break
        case .oneSentence:
            content.setTranscript(Self.oneSentence, animated: false)
        case .overflowLive, .overflowBelow:
            content.setTranscript(Self.threeSentences, animated: false)
        case .overflowProcessing:
            content.setTranscript(Self.threeSentences, animated: false)
            content.setPhase(.processing)
            for _ in 0..<12 { content.hudView.tick() } // let the dots fade in
        }
        return content
    }

    private func render(_ content: HudContentView) -> Data? {
        let backdrop = Backdrop(frame: content.bounds.insetBy(dx: -16, dy: -16)
            .offsetBy(dx: 16, dy: 16))
        content.setFrameOrigin(NSPoint(x: 16, y: 16))
        backdrop.addSubview(content)
        let window = NSWindow(contentRect: backdrop.bounds, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.contentView = backdrop
        backdrop.layoutSubtreeIfNeeded()
        let size = backdrop.bounds.size
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = size
        backdrop.cacheDisplay(in: backdrop.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    /// Stand-in desktop: mid-gray, so dark and light surfaces both show.
    private final class Backdrop: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor(white: 0.5, alpha: 1).setFill()
            bounds.fill()
        }
    }
}
