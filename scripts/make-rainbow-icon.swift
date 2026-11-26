// Draws the fan in the six colors of the rainbow, running around the hub, for the app icon that
// AirFlow shows while Adaptive is the current preset. The picture is a layer of the Icon Composer
// document AppIconRainbow.icon, so macOS gives it Liquid Glass like the first icon.
//
//   swift scripts/make-rainbow-icon.swift
import AppKit
import QuartzCore

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
// The hub is one solid disc: the mark's dot, filled out, with a gap left before the blades.
NSColor.black.setFill()
NSBezierPath(ovalIn: NSRect(x: side / 2 - 100, y: side / 2 - 100, width: 200, height: 200)).fill()
// The rainbow runs around the hub like a pinwheel, drawn through the fan.
let rainbow: [UInt32] = [0x61BB46, 0xFDB827, 0xF5821F, 0xE03A3E, 0x963D97, 0x009DDC]
context.cgContext.setBlendMode(.sourceIn)
let wheel = CAGradientLayer()
wheel.type = .conic
wheel.frame = rect
wheel.startPoint = CGPoint(x: 0.5, y: 0.5)
wheel.endPoint = CGPoint(x: 0.5, y: 0)
wheel.colors = (rainbow + rainbow.prefix(1)).map { hex in
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}
context.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
wheel.render(in: context.cgContext)
context.cgContext.endTransparencyLayer()
// Every color meets in a point at the middle. A soft light there hides the point, so the hub reads
// as a bead of the rainbow and not as a small wheel of its own.
context.cgContext.setBlendMode(.sourceAtop)
let light = [CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.6), CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0)]
if let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: light as CFArray, locations: [0, 1]) {
    let middle = CGPoint(x: side / 2, y: side / 2)
    context.cgContext.drawRadialGradient(glow, startCenter: middle, startRadius: 0, endCenter: middle, endRadius: 78, options: [])
}
NSGraphicsContext.restoreGraphicsState()
guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("no PNG") }
try data.write(to: out)
print("wrote \(out.path)")
