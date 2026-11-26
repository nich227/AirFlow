import AppKit
import QuartzCore

/// The icon AirFlow shows in the Dock while it runs: the app icon, with the fan in the main color
/// of the palette the person chose. The icon in the Finder and in a Dock where AirFlow
/// is not running is the bundled one, because macOS draws that without asking the app.
enum DockIcon {
    /// Draws the icon.
    /// - Parameters:
    ///   - accent: the color of the blades.
    ///   - isDark: whether the plate is dark, as in Dark Mode.
    static func image(accent: NSColor, isDark: Bool, isRainbow: Bool = false) -> NSImage {
        let side: CGFloat = 1024
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { canvas in
            // The plate has the margins and the corners of a Mac app icon.
            let plate = canvas.insetBy(dx: 100, dy: 100)
            let shape = NSBezierPath(roundedRect: plate, xRadius: 185, yRadius: 185)

            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
            shadow.shadowBlurRadius = 20
            shadow.shadowOffset = NSSize(width: 0, height: -10)
            shadow.set()
            NSColor.black.setFill()
            shape.fill()
            NSGraphicsContext.restoreGraphicsState()

            let top = isDark ? NSColor(white: 0.20, alpha: 1) : NSColor(white: 1, alpha: 1)
            let bottom = isDark ? NSColor(white: 0.05, alpha: 1) : NSColor(white: 0.88, alpha: 1)
            NSGradient(starting: top, ending: bottom)?.draw(in: shape, angle: -90)

            // The mark sits at four fifths of the plate, as in the bundled icon.
            let mark = plate.insetBy(dx: plate.width * 0.1, dy: plate.height * 0.1)
            let housing = isDark ? NSColor(white: 0.96, alpha: 1) : NSColor(white: 0.05, alpha: 1)
            // While Adaptive is the current preset, the whole fan has the rainbow: its housing and
            // its blades. The plate behind it stays plain.
            tinted("MarkHousing", with: housing, around: isRainbow ? rainbow : nil)?.draw(in: mark)
            // The blades are lit from above: the accent, lighter at the top.
            let light = accent.blended(withFraction: 0.35, of: .white) ?? accent
            tinted("MarkBlades", with: accent, fall: isRainbow ? nil : [light, accent], around: isRainbow ? rainbow : nil)?.draw(in: mark)

            // A rim of light along the top edge, as on a pane of glass.
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            let rim = NSBezierPath(roundedRect: plate.insetBy(dx: 3, dy: 3), xRadius: 182, yRadius: 182)
            rim.lineWidth = 6
            NSColor.white.withAlphaComponent(isDark ? 0.18 : 0.6).setStroke()
            rim.stroke()
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
    }

    /// A template image from the asset catalog, painted in one color or in a fall of two.
    private static let rainbow: [NSColor] = [0x61BB46, 0xFDB827, 0xF5821F, 0xE03A3E, 0x963D97, 0x009DDC].map { hex in
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    /// - Parameters:
    ///   - fall: colors from the top down, or nil.
    ///   - around: colors that run around the middle like a color wheel, or nil.
    private static func tinted(_ name: String, with color: NSColor, fall: [NSColor]? = nil, around: [NSColor]? = nil) -> NSImage? {
        guard let template = NSImage(named: name) else { return nil }
        let size = NSSize(width: 824, height: 824)
        return NSImage(size: size, flipped: false) { rect in
            template.draw(in: rect)
            NSGraphicsContext.current?.compositingOperation = .sourceIn
            if let around, let context = NSGraphicsContext.current?.cgContext {
                // The rainbow runs around the hub and comes back to its first color.
                let wheel = CAGradientLayer()
                wheel.type = .conic
                wheel.frame = rect
                wheel.startPoint = CGPoint(x: 0.5, y: 0.5)
                wheel.endPoint = CGPoint(x: 0.5, y: 0)
                wheel.colors = (around + around.prefix(1)).map(\.cgColor)
                // The layer is drawn through the mark, so only the fan takes its colors.
                context.beginTransparencyLayer(auxiliaryInfo: nil)
                wheel.render(in: context)
                context.endTransparencyLayer()
            } else if let fall {
                NSGradient(colors: fall)?.draw(in: rect, angle: -90)
            } else {
                color.setFill()
                rect.fill(using: .sourceIn)
            }
            return true
        }
    }

    /// Puts the icon in the Dock: the one of the palette the person chose, or the one with the
    /// fan in the rainbow while Adaptive is the current preset.
    @MainActor
    static func update() {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let settings = AppModel.shared.settings
        let isRainbow = settings.activePresetID == Preset.adaptiveID
        // The bundled icons are Icon Composer documents, so macOS draws them in Liquid Glass: one
        // for each palette, and one with the fan in the rainbow.
        let name = bundledName(isRainbow: isRainbow, palette: settings.colorPalette)
        // With the first icon, macOS draws the app's own icon, which also follows the icon style
        // the person chose (Dark, Clear, or Tinted). The other icons are set as pictures, so a
        // dark icon style gets the picture of the icon's Dark rendition.
        guard name != "AppIcon" else {
            NSApp.applicationIconImage = nil
            return
        }
        let dark = showsDarkIcons(isDarkMode: isDark) ? NSImage(named: darkName(for: name)) : nil
        // The drawing above stands in only if a bundled icon is missing.
        NSApp.applicationIconImage = dark ?? Bundle.main.image(forResource: name)
            ?? image(accent: NSColor(Palette.accent), isDark: isDark, isRainbow: isRainbow)
    }

    /// The bundled icon to show: the rainbow one, or the palette's.
    static func bundledName(isRainbow: Bool, palette: ColorPalette) -> String {
        isRainbow ? "AppIconRainbow" : palette.iconName
    }

    /// The default of the whole system that holds the icon style from System Settings.
    static let styleKey = "AppleIconAppearanceTheme"

    /// Whether the Dock's icons are dark. The style is a kind (Regular, Clear, Tinted) followed by
    /// Light, Dark, or Automatic, which follows Dark Mode. With no style stored, icons are light.
    static func showsDarkIcons(style: String? = UserDefaults.standard.string(forKey: styleKey), isDarkMode: Bool) -> Bool {
        guard let style else { return false }
        if style.hasSuffix("Dark") { return true }
        return style.hasSuffix("Automatic") && isDarkMode
    }

    /// The picture of a bundled icon's Dark rendition: DockRainbowDark for AppIconRainbow.
    static func darkName(for bundled: String) -> String {
        "Dock" + bundled.dropFirst("AppIcon".count) + "Dark"
    }
}
