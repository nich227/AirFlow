// Draws the brand image at the top of the README. The image is the mark above the name, once in
// dark ink for a light page and once in light ink for a dark page.
//
//   swift scripts/make-brand.swift
//
// The mark is the menu bar icon, and the name uses the app's own typeface.
import AppKit
import CoreText

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let markURL = root.appendingPathComponent("AirFlow/Resources/Assets.xcassets/MenuBarIcon.imageset/fan.svg")
let fontURL = root.appendingPathComponent("AirFlow/Resources/Fonts/HedvigLettersSans-Regular.ttf")
let folder = root.appendingPathComponent("docs/images")

guard let mark = NSImage(contentsOf: markURL) else { fatalError("no mark at \(markURL.path)") }
guard CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil),
      let font = NSFont(name: "HedvigLettersSans-Regular", size: 96) else { fatalError("no font at \(fontURL.path)") }

func draw(ink: NSColor, to name: String) throws {
    let size = NSSize(width: 640, height: 520)
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("no bitmap") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context

    // The mark is black on clear, so the ink is painted through it.
    let markSide: CGFloat = 264
    let markRect = NSRect(x: (size.width - markSide) / 2, y: size.height - markSide - 24, width: markSide, height: markSide)
    mark.draw(in: markRect)
    ink.set()
    markRect.fill(using: .sourceIn)

    let title = NSAttributedString(string: "AirFlow", attributes: [.font: font, .foregroundColor: ink, .kern: 1.5])
    let titleSize = title.size()
    title.draw(at: NSPoint(x: (size.width - titleSize.width) / 2, y: 44))

    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("no PNG") }
    try data.write(to: folder.appendingPathComponent(name))
}

try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
try draw(ink: NSColor(srgbRed: 0.11, green: 0.11, blue: 0.13, alpha: 1), to: "airflow-brand.png")
try draw(ink: NSColor(srgbRed: 0.93, green: 0.93, blue: 0.95, alpha: 1), to: "airflow-brand-dark.png")
print("wrote docs/images/airflow-brand.png and airflow-brand-dark.png")
