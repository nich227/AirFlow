import AppKit
import SwiftUI

// The design tokens. DESIGN.md describes each one. Change both together.

/// Ant Design's spacing steps, on a 4 point grid.
enum Space {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 24
    static let xl: CGFloat = 32
    static let xxl: CGFloat = 48
}

/// Ant Design's corner radii, then the radius of a glass card. Glass controls take their shape
/// from the system instead.
enum Radius {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 6
    static let md: CGFloat = 8
    static let card: CGFloat = 16
}

enum IconSize {
    static let inline: CGFloat = 14
    static let row: CGFloat = 16
    static let title: CGFloat = 20
    static let state: CGFloat = 28
    static let rotor: CGFloat = 44
    static let illustration: CGFloat = 72
}

enum Layout {
    static let sidebarWidth: CGFloat = 220
    static let inspectorWidth: CGFloat = 280
    static let detailMaxWidth: CGFloat = 720
    /// Wide enough for the sidebar, a page, and the readings side by side at their widest.
    static let windowMinWidth: CGFloat = 1120
    static let panelWidth: CGFloat = 340
    static let settingsWidth: CGFloat = 520
    static let trackHeight: CGFloat = 8
    static let curveHeight: CGFloat = 168
    static let statusDot: CGFloat = 8
}

enum Palette {
    static let accent = Color.accentColor

    /// Fills on the window background. They use the label color, so they darken a light
    /// window and lighten a dark one.
    static func fill(_ contrast: ColorSchemeContrast) -> Color {
        Color.primary.opacity(contrast == .increased ? 0.12 : 0.06)
    }

    static func fillStrong(_ contrast: ColorSchemeContrast) -> Color {
        Color.primary.opacity(contrast == .increased ? 0.22 : 0.11)
    }

    static func hairline(_ contrast: ColorSchemeContrast) -> Color {
        Color.primary.opacity(contrast == .increased ? 0.40 : 0.12)
    }

    /// The temperature scale, one step per band: sky, emerald, amber, orange, rose.
    static func temperature(_ band: TemperatureBand) -> Color {
        switch band {
        case .cool: return Color("TempCool")
        case .mild: return Color("TempMild")
        case .warm: return Color("TempWarm")
        case .hot: return Color("TempHot")
        case .critical: return Color("TempCritical")
        }
    }

    /// The temperature scale as a gradient across a range of temperatures, for a part's bands.
    static func temperatureStops(for group: SensorGroup, in range: ClosedRange<Double>, opacity: Double = 1) -> [Gradient.Stop] {
        let thresholds = TemperatureBand.thresholds(for: group)
        let span = range.upperBound - range.lowerBound
        // One stop in the middle of each band, so one band's color runs into the next.
        return TemperatureBand.allCases.map { band in
            let lower = band.rawValue == 0 ? range.lowerBound : thresholds[band.rawValue - 1]
            let upper = band.rawValue < thresholds.count ? thresholds[band.rawValue] : range.upperBound
            let middle = ((lower + upper) / 2 - range.lowerBound) / span
            return Gradient.Stop(color: temperature(band).opacity(opacity), location: min(max(middle, 0), 1))
        }
    }

    /// The lines of the temperature chart, each a run of two colors from left to right: pink into
    /// violet for the CPU, and cyan into mint for the GPU. They are not steps of the temperature
    /// scale, so a line's color never reads as how hot the part is.
    static let cpu = [Color(light: 0xDB2777, dark: 0xF472B6), Color(light: 0x7C3AED, dark: 0xA78BFA)]
    static let gpu = [Color(light: 0x0891B2, dark: 0x22D3EE), Color(light: 0x059669, dark: 0x6EE7B7)]

    /// The line of a fan in the fan chart, by the fan's index. The first fan has the accent, and
    /// the next ones teal, pink, and amber. A Mac with more fans starts the colors again.
    static func fan(_ index: Int) -> Color {
        let others = [Color(light: 0x0D9488, dark: 0x2DD4BF), Color(light: 0xDB2777, dark: 0xF472B6), Color(light: 0xB45309, dark: 0xFBBF24)]
        let place = ((index % (others.count + 1)) + others.count + 1) % (others.count + 1)
        return place == 0 ? accent : others[place - 1]
    }

    /// The six colors of the rainbow, from the top down: green, yellow, orange, red, purple, blue.
    /// They color the fan while Adaptive is the current preset.
    static let rainbow: [Color] = [0x61BB46, 0xFDB827, 0xF5821F, 0xE03A3E, 0x963D97, 0x009DDC].map { Color(light: $0, dark: $0) }

    /// The rainbow as rings from a fan's hub outward. The hub and the housing share the first color.
    static let rainbowRings: [Gradient.Stop] = zip([0, 0.19, 0.27, 0.39, 0.51, 0.63, 0.75, 0.86, 1], [0, 0, 1, 2, 3, 4, 5, 0, 0]).map {
        Gradient.Stop(color: rainbow[$1], location: $0)
    }

    /// The color of a kind of work, from the temperature scale: emerald for light work, amber for
    /// bursts, and orange for a long load. The word is always beside it.
    static func workload(_ regime: WorkloadRegime) -> Color {
        switch regime {
        case .light: return temperature(.mild)
        case .bursty: return temperature(.warm)
        case .sustained: return temperature(.hot)
        }
    }

    static let success = Color("TempMild")
    static let caution = Color("TempWarm")
    static let danger = Color("TempCritical")
}

extension Color {
    /// A color with one value for Light Mode and one for Dark Mode, as sRGB hex.
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1
            )
        })
    }
}

/// The type roles. Text uses Hedvig Letters Sans. Every reading (a fan's speed with its unit, a
/// temperature, any other number that is read) uses IBM Plex Mono. So a changing number never
/// shifts its neighbors. The app carries both faces.
enum AirType {
    case display, title, statistic, body, label, caption

    /// The family of the text face. It has one weight, so the roles differ by size alone.
    static let textFamily = "Hedvig Letters Sans"
    /// The family of the monospaced face. The app carries its regular and medium weights.
    static let readingFamily = "IBM Plex Mono"

    var size: CGFloat {
        switch self {
        case .display, .statistic: return 24
        case .title: return 16
        case .body: return 13
        case .label: return 12
        case .caption: return 11
        }
    }

    /// The weight of the role as a reading. The text face has one weight.
    var weight: Font.Weight {
        switch self {
        case .display, .title: return .semibold
        case .statistic, .label: return .medium
        case .body, .caption: return .regular
        }
    }

    var font: Font {
        self == .statistic ? readingFont : .custom(Self.textFamily, fixedSize: size)
    }

    /// The role in the monospaced face, for a reading.
    var readingFont: Font {
        .custom(Self.readingFamily, fixedSize: size).weight(weight == .regular ? .regular : .medium)
    }
}

extension View {
    func airFont(_ role: AirType) -> some View {
        font(role.font)
    }

    /// A reading: a fan speed or a temperature, in the monospaced face.
    func readingFont(_ role: AirType) -> some View {
        font(role.readingFont)
    }
}

enum Anim {
    static let quick = Animation.easeOut(duration: 0.2)
    static let standard = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.35)

    /// Nil when nothing may move.
    static func allowed(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}

enum Animations {
    static let rotor = "rotor"
    static let breeze = "breeze"
    static let done = "done"
    static let spark = "spark"
    static let all = [rotor, breeze, done, spark]
    static let stillMarker = "reduced motion"
}

/// Finds the readings in a sentence, so each one can be set in the monospaced face.
enum ReadingText {
    /// A number with what belongs to it: its separators, and a degree sign with its scale, a
    /// percent sign, or RPM.
    private static let reading = /\d+(?:[.,:]\d+)*(?:\s?°[CF]?|\s?%|\sRPM)?/

    static func ranges(in sentence: String) -> [Range<String.Index>] {
        sentence.ranges(of: reading)
    }

    static func attributed(_ sentence: String, role: AirType) -> AttributedString {
        var text = AttributedString(sentence)
        for range in ranges(in: sentence) {
            // The space between a number and its unit stays in the text face. A monospaced
            // space is a whole cell wide, which reads as two spaces inside a sentence.
            for piece in sentence[range].split(whereSeparator: \.isWhitespace) {
                if let lower = AttributedString.Index(piece.startIndex, within: text),
                   let upper = AttributedString.Index(piece.endIndex, within: text) {
                    text[lower..<upper].font = role.readingFont
                }
            }
        }
        return text
    }
}

extension Text {
    /// A sentence whose numbers are readings: each one, with its unit, is in the monospaced face.
    init(readings sentence: String, role: AirType = .body) {
        self.init(ReadingText.attributed(sentence, role: role))
    }
}

/// Ant Design's components are drawn in Liquid Glass. The surface under a tag, an alert, or a card
/// is glass that shows what is behind the window. It is tinted where the component carries a state.
extension View {
    /// - Parameters:
    ///   - tint: the state's color, or nil for clear glass.
    ///   - radius: the corner radius, or nil for a capsule.
    ///   - isInteractive: whether the glass reacts to the pointer, for something a person presses.
    func antGlass(tint: Color? = nil, radius: CGFloat? = Radius.card, isInteractive: Bool = false) -> some View {
        modifier(AntGlass(tint: tint, radius: radius, isInteractive: isInteractive))
    }
}

private struct AntGlass: ViewModifier {
    let tint: Color?
    let radius: CGFloat?
    let isInteractive: Bool
    @Environment(\.airFlatGlass) private var isFlat

    private var shape: AnyShape {
        radius.map { AnyShape(.rect(cornerRadius: $0)) } ?? AnyShape(.capsule)
    }

    func body(content: Content) -> some View {
        if isFlat {
            content.background((tint ?? Color.primary).opacity(tint == nil ? 0.06 : 0.28), in: shape)
        } else {
            // A pane with no state is clear glass, so the desktop shows through it. A pane that
            // carries a state is regular glass in the state's color.
            content
                .glassEffect((tint.map { Glass.regular.tint($0.opacity(0.28)) } ?? Glass.clear).interactive(isInteractive), in: shape)
                .overlay {
                    // A window that is not in front loses the glass's tint. The edge keeps the
                    // pane of a state visible there.
                    if let tint {
                        shape.stroke(tint.opacity(0.35), lineWidth: 1)
                    }
                }
        }
    }
}

extension EnvironmentValues {
    /// True where glass cannot be drawn: an off-screen drawing has nothing behind it, and the
    /// system leaves out whatever sits on glass there. A flat fill stands in for the pane.
    @Entry var airFlatGlass = false
}

/// The look of the window while Adaptive is on: every color of the rainbow, turning slowly over
/// the blurred desktop. It holds still with Reduce Motion on and in a window that is not in front,
/// so it costs nothing when nobody is looking.
struct AirBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activity

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            TimelineView(.animation(minimumInterval: 1.0 / 20, paused: reduceMotion || activity == .inactive)) { timeline in
                mesh(at: reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate)
            }
            // More contrast asks for a calmer ground under the text.
            .opacity(contrast == .increased ? 0.3 : (scheme == .dark ? 0.72 : 0.85))
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    /// Nine fields of color a ninth of the rainbow apart. The hues move on with time, and the
    /// points between the corners turn about the middle, so the colors swirl.
    private func mesh(at time: TimeInterval) -> MeshGradient {
        let turn = time / 9
        let drift = Float(time / 14)
        func hue(_ place: Int) -> Color {
            let value = (Double(place) / 9 + time / 45).truncatingRemainder(dividingBy: 1)
            return Color(hue: value, saturation: scheme == .dark ? 0.72 : 0.42, brightness: scheme == .dark ? 0.5 : 1)
        }
        let x = Float(cos(turn)) * 0.2, y = Float(sin(turn)) * 0.2
        return MeshGradient(
            width: 3, height: 3,
            points: [
                [0, 0], [0.5 + 0.25 * sin(drift), 0], [1, 0],
                [0, 0.5 + 0.25 * cos(drift)], [0.5 + x, 0.5 + y], [1, 0.5 - 0.25 * cos(drift)],
                [0, 1], [0.5 - 0.25 * sin(drift), 1], [1, 1],
            ],
            colors: [hue(0), hue(1), hue(2), hue(7), hue(8), hue(3), hue(6), hue(5), hue(4)]
        )
    }
}

extension EnvironmentValues {
    /// True while Adaptive is the current preset. The fans' rotors are then drawn in the rainbow.
    @Entry var airRainbow = false
}

/// Ant Design's card as a pane of glass.
struct GlassCard<Content: View>: View {
    var padding: CGFloat = Space.md
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .antGlass()
    }
}

/// An Ant Design icon from the asset catalog, sized as a square and tinted by its context.
struct AntIcon: View {
    let name: String
    var size: CGFloat = IconSize.row

    init(_ name: String, size: CGFloat = IconSize.row) {
        self.name = name
        self.size = size
    }

    var body: some View {
        Image(name)
            .renderingMode(.template)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
