import AppKit

/// The menubar walkie-talkie. Drawn as a template image so it follows the
/// menubar's light and dark appearance. Geometry is on a 24-unit grid shared
/// with the website's SVG logo and scaled to the 18 pt status item.
enum WalkieIcon {
    enum Pose: Equatable {
        /// Ready: button out, quiet.
        case idle
        /// Recording: button held in, radio waves ripple out.
        case talking
        /// Transcribing: button out, dots cycle on the screen.
        case thinking
    }

    /// Frames per animation loop for the animated poses.
    static let frameCount = 3

    static func image(_ pose: Pose, frame: Int = 0, accessibilityDescription: String? = nil) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { _ in
            NSGraphicsContext.current?.cgContext.scaleBy(x: size.width / 24, y: size.height / 24)
            draw(pose, frame: frame % frameCount)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription
        return image
    }

    private static func draw(_ pose: Pose, frame: Int) {
        NSColor.black.setFill()

        // Antenna, body, and the push-to-talk button on the left edge. The
        // button sits flush with the body while it's held down.
        NSBezierPath(roundedRect: NSRect(x: 6, y: 1.5, width: 2, height: 6), xRadius: 1, yRadius: 1).fill()
        let body = NSBezierPath(roundedRect: NSRect(x: 4, y: 6, width: 11, height: 16.5), xRadius: 2.5, yRadius: 2.5)
        let buttonX: CGFloat = pose == .talking ? 3.2 : 2
        body.append(NSBezierPath(roundedRect: NSRect(x: buttonX, y: 10, width: 4 - buttonX + 1, height: 4), xRadius: 0.6, yRadius: 0.6))
        body.fill()

        // Screen and speaker grille are knocked out of the body.
        let context = NSGraphicsContext.current
        context?.compositingOperation = .clear
        NSBezierPath(roundedRect: NSRect(x: 6.5, y: 8.75, width: 6, height: 4.5), xRadius: 1, yRadius: 1).fill()
        for y in [16.0, 18.5] {
            NSBezierPath(roundedRect: NSRect(x: 6.5, y: y, width: 6, height: 1.1), xRadius: 0.55, yRadius: 0.55).fill()
        }
        context?.compositingOperation = .sourceOver

        switch pose {
        case .idle:
            break
        case .talking:
            // Inner wave leads, outer wave follows, so the pair reads as
            // signal moving away from the antenna.
            let alphas: [(CGFloat, CGFloat)] = [(1, 0.25), (1, 1), (0.35, 1)]
            let (inner, outer) = alphas[frame]
            wave(radius: 3.5, alpha: inner)
            wave(radius: 6.5, alpha: outer)
        case .thinking:
            for index in 0...frame {
                NSBezierPath(ovalIn: NSRect(x: 7.4 + CGFloat(index) * 1.6, y: 10.3, width: 1.2, height: 1.2)).fill()
            }
        }
    }

    private static func wave(radius: CGFloat, alpha: CGFloat) {
        let path = NSBezierPath()
        // Flipped context: positive angles sweep downward, so -45...45 opens right.
        path.appendArc(withCenter: NSPoint(x: 15, y: 9), radius: radius, startAngle: -45, endAngle: 45)
        path.lineWidth = 1.6
        path.lineCapStyle = .round
        NSColor.black.withAlphaComponent(alpha).setStroke()
        path.stroke()
    }
}
