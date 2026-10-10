// Generates the monochrome dotted-wave layer for Resources/AppIcon.icon.
// icon.json supplies the black/white colors for light and dark appearances.
// Usage: swift scripts/generate-icon.swift <AppIcon.icon/Assets>
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: generate-icon.swift <AppIcon.icon/Assets>\n".utf8))
    exit(2)
}

let assets = URL(fileURLWithPath: CommandLine.arguments[1])
let circles = (0..<19).map { index in
    let t = Double(index) / 18
    let x = 142 + 740 * t
    let y = 512 - 132 * sin(t * .pi * 2 * 1.28)
    let radius = 12 + 5 * (0.5 + 0.5 * sin(t * .pi * 4 - 1))
    return String(format: "<circle cx=\"%.2f\" cy=\"%.2f\" r=\"%.2f\"/>", x, y, radius)
}.joined()
let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 1024 1024\"><g fill=\"#fff\">\(circles)</g></svg>"

do {
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
    try svg.write(to: assets.appendingPathComponent("wave.svg"), atomically: true, encoding: .utf8)
} catch {
    FileHandle.standardError.write(Data("error: could not write icon layer: \(error.localizedDescription)\n".utf8))
    exit(1)
}
