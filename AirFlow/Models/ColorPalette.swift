import Foundation

/// The colors of AirFlow: its accent, the temperature scale, and the lines of the charts. The
/// person chooses one in Preferences.
enum ColorPalette: String, CaseIterable, Identifiable, Codable, Sendable {
    case aqua, cyberpunk, aurora, matrix, girlypop, synthwave, nord, catppuccin

    /// The palette of a copy of AirFlow in which the person has chosen none.
    static let standard = ColorPalette.aqua

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
        case .aqua: return "Aqua"
        case .cyberpunk: return "Cyberpunk"
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
        case .aqua:
            // The Mac's own look of 2001: the blue of a gel button, then the green, the yellow, and
            // the red of a window's three buttons, with an orange between the last two.
            return [Shade(0x1C5FB8, 0x6AABF3), Shade(0x3E8E1E, 0x58B52F), Shade(0xA86F00, 0xFFAE00), Shade(0xB85A1F, 0xE0742F), Shade(0xC22D23, 0xFF3B30)]
        case .cyberpunk:
            // Neon on black: cyan, green, the yellow of the game's name, orange, and red.
            return [Shade(0x008C99, 0x00F0FF), Shade(0x008F5A, 0x05FFA1), Shade(0x8F8600, 0xFCEE0A), Shade(0xC25A00, 0xFF7700), Shade(0xD1002F, 0xFF003C)]
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
        case .aqua: return [Shade(0x2F7DE0, 0x6AABF3), Shade(0x1C5FB8, 0x2F7DE0)]
        case .cyberpunk: return [Shade(0x8F8600, 0xFCEE0A), Shade(0xC25A00, 0xFF7700)]
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
        case .aqua: return [Shade(0x3E8E1E, 0x58B52F), Shade(0x2A9A00, 0x35CB00)]
        case .cyberpunk: return [Shade(0x008C99, 0x00F0FF), Shade(0x1A66C4, 0x2080F0)]
        case .aurora: return [Shade(0x0891B2, 0x22D3EE), Shade(0x059669, 0x6EE7B7)]
        case .matrix: return [Shade(0x4F8A10, 0xA4F644), Shade(0x2F8F5B, 0x5EC986)]
        case .girlypop: return [Shade(0x0284C7, 0x7DD3FC), Shade(0xC026D3, 0xF0ABFC)]
        case .synthwave: return [Shade(0xA67C00, 0xFEDE5D), Shade(0x148F5B, 0x72F1B8)]
        case .nord: return [Shade(0x3F7F7D, 0x8FBCBB), Shade(0x5B7A3F, 0xA3BE8C)]
        case .catppuccin: return [Shade(0x209FB5, 0x74C7EC), Shade(0x179299, 0x94E2D5)]
        }
    }

    /// The colors of the fans' lines in the fan chart, for a Mac with up to three fans (see
    /// `fan(_:of:)` for more). None is a color of the CPU's or the GPU's line, so the two charts
    /// never read as one.
    var fans: [Shade] {
        switch self {
        // A pink, the yellow of a window's middle button, and an orange: no blue and no green,
        // which are the CPU's and the GPU's.
        case .aqua: return [Shade(0xB3235A, 0xE02F6B), Shade(0xA86F00, 0xFFAE00), Shade(0xB85A1F, 0xE0742F)]
        case .cyberpunk: return [Shade(0xA800C7, 0xD800FF), Shade(0x008F5A, 0x05FFA1), Shade(0xD1002F, 0xFF003C)]
        case .aurora: return [Shade(0xB45309, 0xFBBF24), Shade(0x4D7C0F, 0xA3E635), Shade(0xC2410C, 0xFB923C)]
        case .matrix: return [Shade(0x4B6B4F, 0xD4FFD0), Shade(0x0F766E, 0x2EE6C0), Shade(0x6B7A00, 0xD9F04A)]
        case .girlypop: return [Shade(0xEA580C, 0xFDBA74), Shade(0x059669, 0x6EE7B7), Shade(0xCA8A04, 0xFDE047)]
        case .synthwave: return [Shade(0xD9620A, 0xFF8B39), Shade(0x7B4FB3, 0xB893CE), Shade(0xC2182B, 0xFE4450)]
        case .nord: return [Shade(0xA85A3C, 0xD08770), Shade(0x9A7420, 0xEBCB8B), Shade(0xA3414B, 0xBF616A)]
        case .catppuccin: return [Shade(0xFE640B, 0xFAB387), Shade(0xDF8E1D, 0xF9E2AF), Shade(0x40A02B, 0xA6E3A1)]
        }
    }

    /// The color of one fan's line among `count` fans. A Mac with no more fans than the palette
    /// has colors for takes those colors in order. A Mac with more fans gets as many colors as it
    /// has fans, spread evenly along the palette's colors, so no two fans share one.
    func fan(_ index: Int, of count: Int) -> Shade {
        let colors = fans
        let place = max(index, 0)
        guard count > colors.count else { return colors[place % colors.count] }
        let position = Double(min(place, count - 1)) / Double(count - 1) * Double(colors.count - 1)
        let lower = min(Int(position), colors.count - 2)
        let share = position - Double(lower)
        return Shade(
            Self.mix(colors[lower].light, colors[lower + 1].light, share: share),
            Self.mix(colors[lower].dark, colors[lower + 1].dark, share: share)
        )
    }

    /// A color between two colors, channel by channel.
    static func mix(_ first: UInt32, _ second: UInt32, share: Double) -> UInt32 {
        [16, 8, 0].reduce(UInt32(0)) { result, shift in
            let from = Double((first >> UInt32(shift)) & 0xFF), to = Double((second >> UInt32(shift)) & 0xFF)
            return result | (UInt32((from + (to - from) * min(max(share, 0), 1)).rounded()) << UInt32(shift))
        }
    }

    /// The palette's main color. It marks what is selected and what acts, in place of the accent
    /// from System Settings, and it is the color of the fan in the app's icon. Each is dark enough
    /// in both appearances for white text to be read on it.
    var accent: Shade {
        switch self {
        case .aqua: return Shade(0x2F7DE0, 0x4A90EC)
        // The game's yellow is too light for white text, and its red would make a note read as an
        // error, so the accent is its magenta.
        case .cyberpunk: return Shade(0xA800C7, 0xD800FF)
        case .aurora: return Shade(0x0D9488, 0x0FA394)
        case .matrix: return Shade(0x008F11, 0x00A828)
        case .girlypop: return Shade(0xDB2777, 0xEC4899)
        case .synthwave: return Shade(0xC2259B, 0xE23FB8)
        case .nord: return Shade(0x4C6E96, 0x5E81AC)
        case .catppuccin: return Shade(0x8839EF, 0x9D6BF0)
        }
    }

    /// The color of a part, for a person who colors the status dots by part. The CPU and the GPU
    /// have the colors of their lines in the chart.
    func part(_ group: SensorGroup) -> Shade {
        switch group {
        case .cpu: return cpu[0]
        case .gpu: return gpu[0]
        case .memory: return fans[0]
        case .storage: return fans[1]
        case .battery: return fans[2]
        case .enclosure: return moreParts[0]
        case .power: return moreParts[1]
        case .wireless: return moreParts[2]
        case .other: return Shade(0x6B7280, 0x9CA3AF)
        }
    }

    /// Three more colors, for the parts that have no line in a chart: the enclosure, the power
    /// supply, and the wireless card. Each is a hue the palette's lines do not use.
    private var moreParts: [Shade] {
        switch self {
        case .aqua: return [Shade(0x3263A8, 0x4B81B6), Shade(0xC22D23, 0xFF3B30), Shade(0x5A6472, 0x7D8694)]
        case .cyberpunk: return [Shade(0xC25A00, 0xFF7700), Shade(0x1A66C4, 0x2080F0), Shade(0x555D6E, 0xE8ECF2)]
        case .aurora: return [Shade(0x7C3AED, 0xA78BFA), Shade(0xBE123C, 0xFB7185), Shade(0x0369A1, 0x38BDF8)]
        case .matrix: return [Shade(0x003B00, 0x008F11), Shade(0x00A814, 0xE8FFE0), Shade(0x15803D, 0x4ADE80)]
        case .girlypop: return [Shade(0x7C3AED, 0xC4B5FD), Shade(0xC026D3, 0xE879F9), Shade(0xE11D48, 0xFB7185)]
        case .synthwave: return [Shade(0x0B8F8C, 0x36F9F6), Shade(0x148F5B, 0x72F1B8), Shade(0x495495, 0x8F9BE8)]
        case .nord: return [Shade(0x4C6E96, 0x81A1C1), Shade(0x5B7A3F, 0xA3BE8C), Shade(0x3F7F9A, 0x88C0D0)]
        case .catppuccin: return [Shade(0x8839EF, 0xCBA6F7), Shade(0xD20F39, 0xF38BA8), Shade(0x179299, 0x94E2D5)]
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

/// What the color of a status dot says.
enum DotColoring: String, CaseIterable, Identifiable, Codable, Sendable {
    /// How hot the part is for its own limits, on the temperature scale.
    case temperature
    /// Which part it is. Each part keeps one color, whatever its temperature.
    case part

    var id: String { rawValue }

    var title: String {
        switch self {
        case .temperature: return "By Temperature"
        case .part: return "By Part"
        }
    }

    /// The coloring in use. `AppSettings` sets it, as it sets `ColorPalette.current`.
    nonisolated(unsafe) static var current: DotColoring = .temperature
}
