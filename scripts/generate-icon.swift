// Renders the artwork layers of Resources/AppIcon.icon:
//   wave.png    the lit sunset dots of the dot-matrix wave
//   grid.png    the unlit dots in white, which icon.json tints per appearance
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

// MARK: Dot wave

let dotStart = "#FFC46B"
let dotMid = "#FF9A6B"
let dotEnd = "#FF6FA3"

/// An 11 by 9 dot matrix. Dots near one cycle of a sine wave light up in
/// sunset colors, amber on the left to pink on the right; the rest form a
/// faint grid. `lit` picks which of the two sets to draw, since the grid is
/// its own layer so icon.json can tint it per appearance.
func drawDots(_ ctx: CGContext, lit: Bool) {
    let columns = 11, rows = 9
    let cell = S / 16
    let x0 = S / 2 - cell * CGFloat(columns - 1) / 2
    let y0 = S / 2 - cell * CGFloat(rows - 1) / 2
    let stops = [dotStart, dotMid, dotEnd].map { color($0).components! }
    for column in 0..<columns {
        let t = CGFloat(column) / CGFloat(columns - 1)
        // Row the wave passes through in this column, 0 at the top.
        let crest = CGFloat(rows / 2) - 2.5 * sin(2 * .pi * t)
        let (from, to, u) = t < 0.5 ? (stops[0], stops[1], t * 2) : (stops[1], stops[2], t * 2 - 1)
        let tint = CGColor(
            red: from[0] + (to[0] - from[0]) * u,
            green: from[1] + (to[1] - from[1]) * u,
            blue: from[2] + (to[2] - from[2]) * u,
            alpha: 1
        )
        for row in 0..<rows {
            let distance = abs(CGFloat(row) - crest)
            guard (distance < 1.05) == lit else { continue }
            // Core Graphics counts y up from the bottom; rows count down.
            let center = CGPoint(x: x0 + cell * CGFloat(column), y: S - (y0 + cell * CGFloat(row)))
            let radius = lit ? S * (27 - distance * 7) / 1024 : S * 14 / 1024
            let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            ctx.saveGState()
            if lit { ctx.setShadow(offset: .zero, blur: S * 0.025, color: tint) }
            ctx.setFillColor(lit ? tint : CGColor(gray: 1, alpha: 1))
            ctx.fillEllipse(in: rect)
            ctx.restoreGState()
        }
    }
}

// MARK: Main

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: generate-icon.swift <AppIcon.icon/Assets>\n".utf8))
    exit(2)
}
let assets = CommandLine.arguments[1]

let wave = makeContext()
drawDots(wave, lit: true)

let grid = makeContext()
drawDots(grid, lit: false)

let plate = makeContext()
plate.setFillColor(CGColor(gray: 1, alpha: 1))
plate.fill(CGRect(x: 0, y: 0, width: S, height: S))

guard write(wave.makeImage()!, to: assets + "/wave.png"),
      write(grid.makeImage()!, to: assets + "/grid.png"),
      write(plate.makeImage()!, to: assets + "/plate.png")
else {
    FileHandle.standardError.write(Data("error: could not write icon layers to \(assets)\n".utf8))
    exit(1)
}
