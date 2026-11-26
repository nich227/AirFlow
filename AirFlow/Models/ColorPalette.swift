import Foundation

/// The colors of AirFlow: its accent, the temperature scale, and the lines of the charts. The
/// person chooses one in Settings.
enum ColorPalette: String, CaseIterable, Identifiable, Codable, Sendable {
    case bliss, aurora, matrix, girlypop, synthwave, nord, catppuccin

    /// The palette of a copy of AirFlow in which the person has chosen none.
    static let standard = ColorPalette.bliss

    /// One color as sRGB hex, with a value for Light Mode and one for Dark Mode.
    struct Shade: Equatable, Sendable {
        let light: UInt32
        let dark: UInt32

        init(_ light: UInt32, _ dark: UInt32) {
            self.light = light
            self.dark = dark
        }
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bliss: return "Bliss"
        case .aurora: return "Aurora"
        case .matrix: return "Matrix"
        case .girlypop: return "Girlypop"
        case .synthwave: return "Synthwave"
        case .nord: return "Nord"
        case .catppuccin: return "Catppuccin"
        }
    }

    /// The temperature scale, one color for each band from cool to very hot.
    var temperatures: [Shade] {
        switch self {
        case .bliss:
            // A green hill under a blue sky: sky, grass, the sunlit side of the hill, then the
            // orange and the red of a window's own buttons from the same years.
            return [Shade(0x1F64C8, 0x6CB4F5), Shade(0x3F7D1A, 0x7CC243), Shade(0x8F8500, 0xD9E04A), Shade(0xC76A00, 0xF5A623), Shade(0xC8321A, 0xF0563B)]
        case .aurora:
            return [Shade(0x0369A1, 0x38BDF8), Shade(0x047857, 0x34D399), Shade(0xB45309, 0xFBBF24), Shade(0xC2410C, 0xFB923C), Shade(0xBE123C, 0xFB7185)]
        case .matrix:
            // Greens that grow brighter with heat, up to the near white at the head of a line of code.
            return [Shade(0x003B00, 0x008F11), Shade(0x00570A, 0x00C030), Shade(0x00730E, 0x00FF41), Shade(0x008F11, 0xA4F644), Shade(0x00A814, 0xE8FFE0)]
        case .girlypop:
            return [Shade(0x0284C7, 0x7DD3FC), Shade(0x7C3AED, 0xC4B5FD), Shade(0xDB2777, 0xF9A8D4), Shade(0xC026D3, 0xE879F9), Shade(0xE11D48, 0xFB7185)]
        case .synthwave:
            return [Shade(0x0B8F8C, 0x36F9F6), Shade(0x148F5B, 0x72F1B8), Shade(0xA67C00, 0xFEDE5D), Shade(0xC8442F, 0xF97E72), Shade(0xC2182B, 0xFE4450)]
        case .nord:
            return [Shade(0x4C6E96, 0x88C0D0), Shade(0x5B7A3F, 0xA3BE8C), Shade(0x9A7420, 0xEBCB8B), Shade(0xA85A3C, 0xD08770), Shade(0xA3414B, 0xBF616A)]
        case .catppuccin:
            return [Shade(0x04A5E5, 0x89DCEB), Shade(0x40A02B, 0xA6E3A1), Shade(0xDF8E1D, 0xF9E2AF), Shade(0xFE640B, 0xFAB387), Shade(0xD20F39, 0xF38BA8)]
        }
    }

    /// The two colors the CPU's line runs between in the temperature chart.
    var cpu: [Shade] {
        switch self {
        case .bliss: return [Shade(0x245EDC, 0x8CC4FA), Shade(0x0F3FA8, 0x4A90E2)]
        case .aurora: return [Shade(0xDB2777, 0xF472B6), Shade(0x7C3AED, 0xA78BFA)]
        case .matrix: return [Shade(0x008F11, 0x00FF41), Shade(0x003B00, 0x008F11)]
        case .girlypop: return [Shade(0xDB2777, 0xF472B6), Shade(0x7C3AED, 0xC4B5FD)]
        case .synthwave: return [Shade(0xC2259B, 0xFF7EDB), Shade(0x0B8F8C, 0x36F9F6)]
        case .nord: return [Shade(0x8C5E84, 0xB48EAD), Shade(0x4C6E96, 0x81A1C1)]
        case .catppuccin: return [Shade(0xEA76CB, 0xF5C2E7), Shade(0x8839EF, 0xCBA6F7)]
        }
    }

    /// The two colors the GPU's line runs between.
    var gpu: [Shade] {
        switch self {
        case .bliss: return [Shade(0x3F7D1A, 0x7CC243), Shade(0x6E8F00, 0xC3D94E)]
        case .aurora: return [Shade(0x0891B2, 0x22D3EE), Shade(0x059669, 0x6EE7B7)]
        case .matrix: return [Shade(0x4F8A10, 0xA4F644), Shade(0x2F8F5B, 0x5EC986)]
        case .girlypop: return [Shade(0x0284C7, 0x7DD3FC), Shade(0xC026D3, 0xF0ABFC)]
        case .synthwave: return [Shade(0xA67C00, 0xFEDE5D), Shade(0x148F5B, 0x72F1B8)]
        case .nord: return [Shade(0x3F7F7D, 0x8FBCBB), Shade(0x5B7A3F, 0xA3BE8C)]
        case .catppuccin: return [Shade(0x209FB5, 0x74C7EC), Shade(0x179299, 0x94E2D5)]
        }
    }

    /// The lines of the fans in the fan chart. None is a color of the CPU's or the GPU's line, so
    /// the two charts never read as one.
    var fans: [Shade] {
        switch self {
        case .bliss: return [Shade(0xC76A00, 0xF5A623), Shade(0x6B7280, 0xC0C7D0), Shade(0x8F8500, 0xD9E04A)]
        case .aurora: return [Shade(0xB45309, 0xFBBF24), Shade(0x4D7C0F, 0xA3E635), Shade(0xC2410C, 0xFB923C)]
        case .matrix: return [Shade(0x4B6B4F, 0xD4FFD0), Shade(0x0F766E, 0x2EE6C0), Shade(0x6B7A00, 0xD9F04A)]
        case .girlypop: return [Shade(0xEA580C, 0xFDBA74), Shade(0x059669, 0x6EE7B7), Shade(0xCA8A04, 0xFDE047)]
        case .synthwave: return [Shade(0xD9620A, 0xFF8B39), Shade(0x7B4FB3, 0xB893CE), Shade(0xC2182B, 0xFE4450)]
        case .nord: return [Shade(0xA85A3C, 0xD08770), Shade(0x9A7420, 0xEBCB8B), Shade(0xA3414B, 0xBF616A)]
        case .catppuccin: return [Shade(0xFE640B, 0xFAB387), Shade(0xDF8E1D, 0xF9E2AF), Shade(0x40A02B, 0xA6E3A1)]
        }
    }

    /// The palette's main color. It marks what is selected and what acts, in place of the accent
    /// from System Settings, and it is the color of the fan in the app's icon. Each is dark enough
    /// in both appearances for white text to be read on it.
    var accent: Shade {
        switch self {
        case .bliss: return Shade(0x245EDC, 0x3B82F6)
        case .aurora: return Shade(0x0D9488, 0x0FA394)
        case .matrix: return Shade(0x008F11, 0x00A828)
        case .girlypop: return Shade(0xDB2777, 0xEC4899)
        case .synthwave: return Shade(0xC2259B, 0xE23FB8)
        case .nord: return Shade(0x4C6E96, 0x5E81AC)
        case .catppuccin: return Shade(0x8839EF, 0x9D6BF0)
        }
    }

    /// The name of the palette's app icon among the bundled ones. The first palette's is the
    /// app's own icon.
    var iconName: String {
        self == .standard ? "AppIcon" : "AppIcon" + title
    }

    /// The palette in use. `AppSettings` sets it when it loads and when the person chooses another.
    /// Views read it only on the main thread, where it is also written.
    nonisolated(unsafe) static var current: ColorPalette = .standard
}
