// Draws the fan in the six colors of the rainbow, in rings from the hub outward, for the app icon that
// AirFlow shows while Adaptive is the current preset. The picture is a layer of the Icon Composer
// document AppIconRainbow.icon, so macOS gives it Liquid Glass like the first icon.
//
//   swift scripts/make-rainbow-icon.swift
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let parts = root.appendingPathComponent("AirFlow/Resources/AppIcon.icon/Assets")
let out = root.appendingPathComponent("AirFlow/Resources/AppIconRainbow.icon/Assets/fan-rainbow.png")
let side = 1024
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("no bitmap") }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
let rect = NSRect(x: 0, y: 0, width: side, height: side)
for name in ["housing.svg", "blades.svg"] {
    guard let part = NSImage(contentsOf: parts.appendingPathComponent(name)) else { fatalError("no \(name)") }
    part.draw(in: rect)
}
// The hub is one solid disc: the mark's dot, filled out a little, with a gap left before the blades.
NSColor.black.setFill()
NSBezierPath(ovalIn: NSRect(x: side / 2 - 96, y: side / 2 - 96, width: 192, height: 192)).fill()
// The rainbow runs outward in rings, drawn through the fan. The hub is one color, the blades step
// through the others, and the housing comes back to the hub's color.
context.cgContext.setBlendMode(.sourceIn)
let stops: [(CGFloat, UInt32)] = [(0, 0x61BB46), (0.19, 0x61BB46), (0.27, 0xFDB827), (0.39, 0xF5821F), (0.51, 0xE03A3E), (0.63, 0x963D97), (0.75, 0x009DDC), (0.86, 0x61BB46), (1, 0x61BB46)]
let ringColors = stops.map { stop in
    CGColor(srgbRed: CGFloat((stop.1 >> 16) & 0xFF) / 255, green: CGFloat((stop.1 >> 8) & 0xFF) / 255, blue: CGFloat(stop.1 & 0xFF) / 255, alpha: 1)
}
guard let rings = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: ringColors as CFArray, locations: stops.map(\.0)) else { fatalError("no gradient") }
let middle = CGPoint(x: side / 2, y: side / 2)
context.cgContext.drawRadialGradient(rings, startCenter: middle, startRadius: 0, endCenter: middle, endRadius: CGFloat(side) / 2, options: [.drawsAfterEndLocation])
NSGraphicsContext.restoreGraphicsState()
guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("no PNG") }
try data.write(to: out)
print("wrote \(out.path)")
