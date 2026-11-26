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
    /// The readings panel, whose corners follow the window's at 8 points in from its edge.
    static let panel: CGFloat = 18
    /// The corners of a sheet as macOS draws it, for the shadow under one.
    static let sheet: CGFloat = 26
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
    /// An app's icon in the grid that adds apps, the size the Finder's icon view starts at.
    static let appIcon: CGFloat = 64
    static let appPickerSize = CGSize(width: 680, height: 540)
}

enum Palette {
    /// The main color of the palette the person chose. It marks what is selected and what acts.
    static var accent: Color { Color(ColorPalette.current.accent) }

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

    /// The temperature scale, one step per band, in the palette the person chose. In Aurora the
    /// steps are sky, emerald, amber, orange, and rose.
    static func temperature(_ band: TemperatureBand, in palette: ColorPalette = .current) -> Color {
        Color(palette.temperatures[band.rawValue])
    }

    /// The color of a status dot beside a part's reading: the part's band on the temperature
    /// scale, or the part's own color if the person colors the dots by part.
    static func dot(_ band: TemperatureBand, of group: SensorGroup?) -> Color {
        guard let group, DotColoring.current == .part else { return temperature(band) }
        return Color(ColorPalette.current.part(group))
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

    /// The lines of the temperature chart, each a run of two colors from left to right. In Aurora
    /// they are pink into violet for the CPU, and cyan into mint for the GPU. They are not steps
    /// of the temperature scale, so a line's color never reads as how hot the part is.
    static func cpu(in palette: ColorPalette = .current) -> [Color] { palette.cpu.map(Color.init) }
    static func gpu(in palette: ColorPalette = .current) -> [Color] { palette.gpu.map(Color.init) }
    static var cpu: [Color] { cpu() }
    static var gpu: [Color] { gpu() }

    /// The line of a fan in the fan chart, by the fan's index, in the palette's colors for fans.
    /// A Mac with more fans than colors starts the colors again.
    static func fan(_ index: Int) -> Color {
        let colors = ColorPalette.current.fans
        return Color(colors[((index % colors.count) + colors.count) % colors.count])
    }

    /// The six colors of the rainbow, from the top down: green, yellow, orange, red, purple, blue.
    /// They color the fan while Adaptive is the current preset.
    static let rainbow: [Color] = [0x61BB46, 0xFDB827, 0xF5821F, 0xE03A3E, 0x963D97, 0x009DDC].map { Color(light: $0, dark: $0) }

    /// The color of a kind of work, from the temperature scale: emerald for light work, amber for
    /// bursts, and orange for a long load. The word is always beside it.
    static func workload(_ regime: WorkloadRegime) -> Color {
        switch regime {
        case .light: return temperature(.mild)
        case .bursty: return temperature(.warm)
        case .sustained: return temperature(.hot)
        }
    }

    /// What an alert means is the same in every palette, so these keep Aurora's colors.
    static let success = temperature(.mild, in: .aurora)
    static let caution = temperature(.warm, in: .aurora)
    static let danger = temperature(.critical, in: .aurora)
}

extension Color {
    init(_ shade: ColorPalette.Shade) {
        self.init(light: shade.light, dark: shade.dark)
    }

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
    static let readings = "readings"
    static let all = [rotor, breeze, done, spark, readings]
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
    /// True while some part of the backdrop's window is on screen.
    @State private var isOnScreen = true

    /// The seconds the field of color takes to go once around the middle, and the seconds the
    /// middle of it takes. The middle turns faster, which is what makes a swirl.
    private static let turn: TimeInterval = 24
    private static let innerTurn: TimeInterval = 10

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || !isOnScreen)) { timeline in
                swirl(at: reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate)
            }
            // More contrast asks for a calmer ground under the text.
            .opacity(contrast == .increased ? 0.3 : (scheme == .dark ? 0.72 : 0.85))
        }
        .background(WindowVisibility(isOnScreen: $isOnScreen))
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    /// Two fields of color about one middle. The wide one goes around slowly, and a smaller one
    /// that fades toward its edge goes around faster inside it.
    private func swirl(at time: TimeInterval) -> some View {
        GeometryReader { proxy in
            // A square as wide as the window's diagonal covers the window at every angle.
            let side = hypot(proxy.size.width, proxy.size.height)
            ZStack {
                mesh(at: time)
                    .frame(width: side, height: side)
                    .rotationEffect(Self.angle(at: time, every: Self.turn))
                mesh(at: time + 17)
                    .frame(width: side * 0.66, height: side * 0.66)
                    .rotationEffect(Self.angle(at: time, every: Self.innerTurn))
                    .mask(RadialGradient(colors: [.black, .black.opacity(0)], center: .center, startRadius: side * 0.06, endRadius: side * 0.33))
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
    }

    static func angle(at time: TimeInterval, every period: TimeInterval) -> Angle {
        .degrees(time.truncatingRemainder(dividingBy: period) / period * 360)
    }

    /// Nine fields of color a ninth of the rainbow apart. The hues move on with time, and the
    /// points between the corners sway, so the colors run into each other as they go around.
    private func mesh(at time: TimeInterval) -> MeshGradient {
        let turn = time / 5
        let drift = Float(time / 7)
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

/// Reports whether any part of the window that holds it is on screen, so a backdrop turns only
/// where a person can see it: in a window behind another app's, but not in a hidden window or in
/// the menu bar panel while it is closed.
private struct WindowVisibility: NSViewRepresentable {
    @Binding var isOnScreen: Bool

    func makeNSView(context: Context) -> Probe {
        Probe()
    }

    func updateNSView(_ probe: Probe, context: Context) {
        probe.report = { visible in
            if isOnScreen != visible { isOnScreen = visible }
        }
    }

    final class Probe: NSView {
        var report: ((Bool) -> Void)?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.send() }
            }
            send()
        }

        private func send() {
            guard let window else { return }
            let visible = window.occlusionState.contains(.visible)
            // The window's state can change during a layout pass, so the report waits a turn.
            DispatchQueue.main.async { [weak self] in self?.report?(visible) }
        }
    }
}

extension EnvironmentValues {
    /// True while Adaptive is the current preset. The fans' rotors are then drawn in the rainbow.
    @Entry var airRainbow = false
}

extension View {
    /// Makes a sheet cast a shadow on AirFlow's window. The sheet's content tells the window its
    /// size, and the window draws the shadow (`SheetShadow`), because macOS gives a sheet none.
    func castsSheetShadow() -> some View {
        modifier(SheetShadowCaster())
    }
}

private struct SheetShadowCaster: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { size in
                model.openSheetSize = size
            }
            .onDisappear { model.openSheetSize = nil }
    }
}

/// The shadow a sheet casts on the window under it: a soft dark shape the size of the sheet, a
/// little below it. macOS puts a sheet in the middle of its window, so the shape goes there too,
/// and the sheet covers all of it but its edge.
struct SheetShadow: View {
    let size: CGSize?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            // This view may not span the window, so the middle of the window is found from the
            // window's own size.
            let origin = proxy.frame(in: .global).origin
            if let size, let window = Self.windowSize {
                let middle = CGPoint(x: window.width / 2 - origin.x, y: window.height / 2 - origin.y)
                ZStack {
                    // A wide soft shadow that falls below the sheet, and a close dark one at its edge.
                    RoundedRectangle(cornerRadius: Radius.sheet)
                        .fill(.black.opacity(scheme == .dark ? 1 : 0.6))
                        .frame(width: size.width + 24, height: size.height + 24)
                        .blur(radius: 30)
                        .position(x: middle.x, y: middle.y + 26)
                    RoundedRectangle(cornerRadius: Radius.sheet)
                        .fill(.black.opacity(scheme == .dark ? 0.8 : 0.4))
                        .frame(width: size.width, height: size.height)
                        .blur(radius: 6)
                        .position(x: middle.x, y: middle.y + 4)
                }
                .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .animation(Anim.allowed(Anim.standard, reduceMotion: reduceMotion), value: size)
    }

    /// The size of AirFlow's window. A sheet stops the window from changing size, so the size
    /// read when the sheet opens holds while it is open.
    private static var windowSize: CGSize? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(AirFlowApp.mainWindowID) == true }?.frame.size
    }
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
