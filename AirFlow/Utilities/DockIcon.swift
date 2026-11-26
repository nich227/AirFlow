import AppKit
import QuartzCore

/// The icon AirFlow shows in the Dock while it runs: the app icon, with the fan's blades in the
/// accent the person chose in System Settings. The icon in the Finder and in a Dock where AirFlow
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

    /// Puts the icon in the Dock, in the accent and the appearance of this moment.
    @MainActor
    static func update() {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        // The accent is read under the app's appearance, so it is the color the person sees.
        var accent = NSColor.controlAccentColor
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .controlAccentColor
        }
        let isRainbow = AppModel.shared.settings.activePresetID == Preset.adaptiveID
        // The bundled icons are Icon Composer documents, so macOS draws them in Liquid Glass: one
        // with the fan in the rainbow, and one for each accent. The drawing above stands in only
        // if a bundled icon is missing.
        let name = bundledName(isRainbow: isRainbow)
        // With the first icon, macOS draws the app's own icon, which also follows the icon style
        // the person chose (Dark, Clear, or Tinted). The other icons are set as pictures.
        NSApp.applicationIconImage = name == "AppIcon" ? nil
            : Bundle.main.image(forResource: name) ?? image(accent: accent, isDark: isDark, isRainbow: isRainbow)
    }

    /// The bundled icon for the accent in System Settings. macOS stores the accent as a number,
    /// and stores nothing for Multicolor, whose accent is blue.
    static func bundledName(isRainbow: Bool, accent: Int? = UserDefaults.standard.object(forKey: "AppleAccentColor") as? Int) -> String {
        if isRainbow { return "AppIconRainbow" }
        switch accent {
        case -1: return "AppIconGraphite"
        case 0: return "AppIconRed"
        case 1: return "AppIconOrange"
        case 2: return "AppIconYellow"
        case 3: return "AppIconGreen"
        case 5: return "AppIconPurple"
        case 6: return "AppIconPink"
        default: return "AppIcon"
        }
    }
}
