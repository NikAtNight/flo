import AppKit

/// The menubar dot wave, matching the dot-matrix app icon. Drawn as a template
/// image so it follows the menubar's light and dark appearance. Geometry is on
/// a 24-unit grid scaled to the 18 pt status item.
enum WaveIcon {
    enum Pose: Equatable {
        /// Ready: seven dots trace a still, tapered wave.
        case idle
        /// Recording: five dots ride a travelling wave.
        case talking
        /// Transcribing: five dots in a row fill in left to right.
        case thinking
    }

    /// Seconds between animation frames.
    static let frameInterval: TimeInterval = 0.11

    static func image(_ pose: Pose, frame: Int = 0, accessibilityDescription: String? = nil) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { _ in
            NSGraphicsContext.current?.cgContext.scaleBy(x: size.width / 24, y: size.height / 24)
            draw(pose, frame: frame)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription
        return image
    }

    private static func draw(_ pose: Pose, frame: Int) {
        switch pose {
        case .idle:
            for point in idleDots {
                dot(at: point, radius: 1.55)
            }
        case .talking:
            // Eight phase steps make one loop, about 0.9 s.
            let phase = CGFloat(frame % 8) * 0.8
            for index in 0..<5 {
                let y = 12 - 5 * sin(phase + CGFloat(index) * 1.1)
                dot(at: NSPoint(x: 4 + CGFloat(index) * 4, y: y), radius: 1.7)
            }
        case .thinking:
            // Each step holds for two frames so the fill reads as progress.
            let lit = frame / 2 % 5 + 1
            for index in 0..<5 {
                dot(at: NSPoint(x: 4 + CGFloat(index) * 4, y: 12), radius: 1.7, alpha: index < lit ? 1 : 0.25)
            }
        }
    }

    /// Seven dots spaced evenly along a wave that tapers to the midline at
    /// both ends. Spacing by arc length rather than x keeps the steep middle
    /// from looking sparse.
    private static let idleDots: [NSPoint] = {
        let samples = (0...400).map { step -> NSPoint in
            let x = 2 + 20 * CGFloat(step) / 400
            let t = (x - 2) / 20
            // Flipped context: smaller y is higher, so the wave rises first.
            return NSPoint(x: x, y: 12 - 7 * sin(.pi * t) * sin(2.5 * .pi * t))
        }
        var lengths: [CGFloat] = [0]
        for (a, b) in zip(samples, samples.dropFirst()) {
            lengths.append(lengths.last! + hypot(b.x - a.x, b.y - a.y))
        }
        return (0..<7).map { index in
            let target = lengths.last! * CGFloat(index) / 6
            return samples[lengths.firstIndex { $0 >= target } ?? samples.count - 1]
        }
    }()

    private static func dot(at center: NSPoint, radius: CGFloat, alpha: CGFloat = 1) {
        NSColor.black.withAlphaComponent(alpha).setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).fill()
    }
}
