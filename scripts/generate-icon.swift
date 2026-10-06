// Renders the artwork layers of Resources/AppIcon.icon:
//   button.png  the sunset push-to-talk button on a transparent canvas
//   plate.png   a white square that icon.json tints per appearance
//
// Usage: swift scripts/generate-icon.swift <AppIcon.icon/Assets>
// scripts/make-icon.sh runs this and then compiles the package with actool.

import CoreGraphics
import Foundation
import ImageIO

let S: CGFloat = 1024

func color(_ hex: String, _ alpha: CGFloat = 1) -> CGColor {
    var h = Substring(hex)
    if h.hasPrefix("#") { h = h.dropFirst() }
    let v = UInt32(h, radix: 16)!
    return CGColor(
        red: CGFloat((v >> 16) & 0xFF) / 255,
        green: CGFloat((v >> 8) & 0xFF) / 255,
        blue: CGFloat(v & 0xFF) / 255,
        alpha: alpha
    )
}

func makeContext() -> CGContext {
    CGContext(
        data: nil, width: Int(S), height: Int(S),
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
}

func write(_ image: CGImage, to path: String) -> Bool {
    guard let dest = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil
    ) else { return false }
    CGImageDestinationAddImage(dest, image, nil)
    return CGImageDestinationFinalize(dest)
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: stops.map { $0.1 } as CFArray,
        locations: stops.map { $0.0 }
    )!
}

func fillLinear(_ ctx: CGContext, _ path: CGPath, from: CGPoint, to: CGPoint, stops: [(CGFloat, CGColor)]) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(gradient(stops), start: from, end: to,
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

func fillRadial(_ ctx: CGContext, center: CGPoint, radius: CGFloat, stops: [(CGFloat, CGColor)]) {
    ctx.drawRadialGradient(gradient(stops), startCenter: center, startRadius: 0,
                           endCenter: center, endRadius: radius, options: [])
}

// MARK: Button

let ringColor = "#FF9A6B"
let dotStart = "#FFC46B"
let dotEnd = "#FF6FA3"

/// One round push-to-talk button, dead center, with a dot-matrix waveform
/// lit in sunset colors. The button is 38.6% of the canvas in radius, which
/// matches how it sat on the inset plate in the design mockups.
func drawButton(_ ctx: CGContext) {
    let center = CGPoint(x: S / 2, y: S / 2)
    let radius = S * 0.386
    let face = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    let facePath = CGPath(ellipseIn: face, transform: nil)

    // Face with a soft drop shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.03), blur: S * 0.1, color: CGColor(gray: 0, alpha: 0.65))
    ctx.addPath(facePath)
    ctx.setFillColor(color("#140C18"))
    ctx.fillPath()
    ctx.restoreGState()
    fillLinear(ctx, facePath, from: CGPoint(x: 0, y: face.maxY), to: CGPoint(x: 0, y: face.minY), stops: [
        (0, color("#2A1C30")), (1, color("#140C18")),
    ])

    // Coral ring with a glow.
    let ringRect = face.insetBy(dx: S * 0.015, dy: S * 0.015)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: S * 0.05, color: color(ringColor, 0.5))
    ctx.addEllipse(in: ringRect)
    ctx.setLineWidth(S * 0.025)
    ctx.setStrokeColor(color(ringColor, 0.9))
    ctx.strokePath()
    ctx.restoreGState()

    // Dot matrix: 9 columns, 7 rows, lit cells trace a symmetric waveform.
    let columns = 9, rows = 7
    let envelope = [1, 2, 3, 5, 7, 5, 3, 2, 1]
    let area = face.insetBy(dx: S * 0.1, dy: S * 0.1)
    let cell = min(area.width / CGFloat(columns), area.height / CGFloat(rows))
    let dot = cell * 0.58
    let x0 = area.midX - cell * CGFloat(columns) / 2 + cell / 2
    let start = color(dotStart).components!
    let end = color(dotEnd).components!
    ctx.saveGState()
    ctx.addEllipse(in: face.insetBy(dx: S * 0.05, dy: S * 0.05))
    ctx.clip()
    for column in 0..<columns {
        let t = CGFloat(column) / CGFloat(columns - 1)
        let lit = CGColor(
            red: start[0] + (end[0] - start[0]) * t,
            green: start[1] + (end[1] - start[1]) * t,
            blue: start[2] + (end[2] - start[2]) * t,
            alpha: 1
        )
        for row in 0..<rows {
            let offset = row - rows / 2
            let x = x0 + cell * CGFloat(column)
            let y = area.midY + cell * CGFloat(offset)
            let rect = CGRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot)
            if abs(offset) * 2 <= envelope[column] {
                ctx.saveGState()
                ctx.setShadow(offset: .zero, blur: cell * 0.5, color: lit)
                ctx.setFillColor(lit)
                ctx.fillEllipse(in: rect)
                ctx.restoreGState()
            } else {
                ctx.setFillColor(CGColor(gray: 1, alpha: 0.06))
                ctx.fillEllipse(in: rect)
            }
        }
    }
    ctx.restoreGState()
}

// MARK: Main

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: generate-icon.swift <AppIcon.icon/Assets>\n".utf8))
    exit(2)
}
let assets = CommandLine.arguments[1]

let button = makeContext()
drawButton(button)

let plate = makeContext()
plate.setFillColor(CGColor(gray: 1, alpha: 1))
plate.fill(CGRect(x: 0, y: 0, width: S, height: S))

guard write(button.makeImage()!, to: assets + "/button.png"),
      write(plate.makeImage()!, to: assets + "/plate.png")
else {
    FileHandle.standardError.write(Data("error: could not write icon layers to \(assets)\n".utf8))
    exit(1)
}
