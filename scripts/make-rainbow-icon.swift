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
let rainbow: [UInt32] = [0x61BB46, 0xFDB827, 0xF5821F, 0xE03A3E, 0x963D97, 0x009DDC]
let colors = (rainbow + rainbow.prefix(1)).map { hex in
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}
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
// The dot in the middle of the mark is cut out, so the rainbow fan has an open hub. The blades
// begin 128 points from the middle, and the dot is 64 points across from its middle.
context.cgContext.setBlendMode(.clear)
context.cgContext.fillEllipse(in: CGRect(x: side / 2 - 100, y: side / 2 - 100, width: 200, height: 200))
// The wheel of colors is drawn through the fan, so only the fan takes it.
context.cgContext.setBlendMode(.sourceIn)
let wheel = CAGradientLayer()
wheel.type = .conic
wheel.frame = rect
wheel.startPoint = CGPoint(x: 0.5, y: 0.5)
wheel.endPoint = CGPoint(x: 0.5, y: 0)
wheel.colors = colors
context.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
wheel.render(in: context.cgContext)
context.cgContext.endTransparencyLayer()
NSGraphicsContext.restoreGraphicsState()
guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("no PNG") }
try data.write(to: out)
print("wrote \(out.path)")
