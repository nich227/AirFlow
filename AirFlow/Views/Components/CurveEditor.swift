import SwiftUI

/// A sensor rule drawn as speed against temperature. The two handles move the temperatures where
/// the fan starts to rise and where it reaches full speed. A dot shows where the sensor is on the
/// line right now.
struct CurveEditor: View {
    @Binding var rule: SensorRule
    let fan: Fan
    let currentCelsius: Double?
    let group: SensorGroup
    let format: ReadingFormat
    var isEditable = true

    @Environment(\.colorSchemeContrast) private var contrast

    private static let leading: CGFloat = 44
    private static let bottom: CGFloat = 20
    private static let top: CGFloat = 10
    private static let trailing: CGFloat = 10
    private static let handle: CGFloat = 16
    private static let handleTarget: CGFloat = 28

    var body: some View {
        GeometryReader { proxy in
            let plot = Plot(size: proxy.size)
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    drawGrid(in: &context, plot: plot)
                    drawCurve(in: &context, plot: plot)
                    drawLivePoint(in: &context, plot: plot)
                }
                if isEditable {
                    handle(at: plot.point(celsius: rule.startCelsius, fraction: 0), plot: plot) { celsius in
                        rule = SensorRule(
                            source: rule.source,
                            startCelsius: min(celsius, rule.maxCelsius - SensorRule.minimumSpan),
                            maxCelsius: rule.maxCelsius, belowStart: rule.belowStart
                        )
                    }
                    handle(at: plot.point(celsius: rule.maxCelsius, fraction: 1), plot: plot) { celsius in
                        rule = SensorRule(
                            source: rule.source,
                            startCelsius: rule.startCelsius,
                            maxCelsius: max(celsius, rule.startCelsius + SensorRule.minimumSpan), belowStart: rule.belowStart
                        )
                    }
                }
            }
        }
        .frame(height: Layout.curveHeight)
        .accessibilityElement()
        .accessibilityLabel("Fan curve")
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        var value = "Minimum speed up to \(format.spokenTemperature(rule.startCelsius)), full speed at \(format.spokenTemperature(rule.maxCelsius))."
        if let currentCelsius {
            value += " The sensor is at \(format.spokenTemperature(currentCelsius)), which asks for \(ReadingFormat.rpmWithUnit(rule.rpm(at: currentCelsius, fan: fan)))."
        }
        return value
    }

    /// Maps temperatures and speed fractions onto the drawing.
    struct Plot {
        let frame: CGRect
        static let range = SensorRule.temperatureRange

        init(size: CGSize) {
            frame = CGRect(
                x: CurveEditor.leading, y: CurveEditor.top,
                width: max(size.width - CurveEditor.leading - CurveEditor.trailing, 1),
                height: max(size.height - CurveEditor.top - CurveEditor.bottom, 1)
            )
        }

        func x(_ celsius: Double) -> CGFloat {
            let share = (celsius - Self.range.lowerBound) / (Self.range.upperBound - Self.range.lowerBound)
            return frame.minX + frame.width * min(max(share, 0), 1)
        }

        func y(_ fraction: Double) -> CGFloat {
            frame.maxY - frame.height * min(max(fraction, 0), 1)
        }

        func point(celsius: Double, fraction: Double) -> CGPoint {
            CGPoint(x: x(celsius), y: y(fraction))
        }

        func celsius(atX x: CGFloat) -> Double {
            let share = Double((x - frame.minX) / frame.width)
            return Self.range.lowerBound + min(max(share, 0), 1) * (Self.range.upperBound - Self.range.lowerBound)
        }
    }

    private func drawGrid(in context: inout GraphicsContext, plot: Plot) {
        let hairline = Palette.hairline(contrast)
        for celsius in stride(from: Plot.range.lowerBound, through: Plot.range.upperBound, by: 10) {
            var line = Path()
            line.move(to: CGPoint(x: plot.x(celsius), y: plot.frame.minY))
            line.addLine(to: CGPoint(x: plot.x(celsius), y: plot.frame.maxY))
            context.stroke(line, with: .color(hairline), lineWidth: 1)
            // The first label would sit on the speed axis's lowest label.
            if Int(celsius) % 20 == 0, celsius > Plot.range.lowerBound {
                let label = Text(format.temperature(celsius)).font(AirType.caption.readingFont).foregroundStyle(.secondary)
                context.draw(label, at: CGPoint(x: plot.x(celsius), y: plot.frame.maxY + 11), anchor: .center)
            }
        }
        for (fraction, rpm) in [(0.0, fan.minimumRPM), (1.0, fan.maximumRPM)] {
            var line = Path()
            line.move(to: CGPoint(x: plot.frame.minX, y: plot.y(fraction)))
            line.addLine(to: CGPoint(x: plot.frame.maxX, y: plot.y(fraction)))
            context.stroke(line, with: .color(hairline), lineWidth: 1)
            let label = Text(ReadingFormat.rpm(rpm)).font(AirType.caption.readingFont).foregroundStyle(.secondary)
            context.draw(label, at: CGPoint(x: plot.frame.minX - 6, y: plot.y(fraction)), anchor: .trailing)
        }
    }

    private func drawCurve(in context: inout GraphicsContext, plot: Plot) {
        let points = [
            plot.point(celsius: Plot.range.lowerBound, fraction: 0),
            plot.point(celsius: rule.startCelsius, fraction: 0),
            plot.point(celsius: rule.maxCelsius, fraction: 1),
            plot.point(celsius: Plot.range.upperBound, fraction: 1),
        ]
        var area = Path()
        area.move(to: CGPoint(x: plot.frame.minX, y: plot.frame.maxY))
        points.forEach { area.addLine(to: $0) }
        area.addLine(to: CGPoint(x: plot.frame.maxX, y: plot.frame.maxY))
        area.closeSubpath()

        // The background under the line is the temperature scale for the part the rule follows, so
        // the line reads against how hot each temperature is for that part.
        let start = CGPoint(x: plot.frame.minX, y: 0), end = CGPoint(x: plot.frame.maxX, y: 0)
        let ground = Palette.temperatureStops(for: group, in: Plot.range, opacity: contrast == .increased ? 0.34 : 0.24)
        context.fill(area, with: .linearGradient(Gradient(stops: ground), startPoint: start, endPoint: end))

        var line = Path()
        line.move(to: points[0])
        points.dropFirst().forEach { line.addLine(to: $0) }
        // The line has the color of each temperature it passes, over a soft light of the same color.
        let scale = GraphicsContext.Shading.linearGradient(
            Gradient(stops: Palette.temperatureStops(for: group, in: Plot.range)), startPoint: start, endPoint: end
        )
        var glow = context
        glow.addFilter(.blur(radius: 5))
        glow.opacity = 0.6
        glow.stroke(line, with: scale, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
        context.stroke(line, with: scale, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
    }

    private func drawLivePoint(in context: inout GraphicsContext, plot: Plot) {
        guard let currentCelsius else { return }
        let point = plot.point(celsius: currentCelsius, fraction: rule.fraction(at: currentCelsius))
        var guide = Path()
        guide.move(to: CGPoint(x: point.x, y: plot.frame.maxY))
        guide.addLine(to: point)
        context.stroke(guide, with: .color(.secondary), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        let band = TemperatureBand.band(for: currentCelsius, in: group)
        let dot = Path(ellipseIn: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10))
        var glow = context
        glow.addFilter(.blur(radius: 4))
        glow.fill(dot, with: .color(Palette.temperature(band)))
        context.fill(dot, with: .color(Palette.temperature(band)))
        context.stroke(dot, with: .color(.primary), lineWidth: 1.5)
    }

    private func handle(at point: CGPoint, plot: Plot, move: @escaping (Double) -> Void) -> some View {
        Circle()
            .strokeBorder(Palette.accent, lineWidth: 2)
            .frame(width: Self.handle, height: Self.handle)
            .antGlass(tint: Palette.accent, radius: nil, isInteractive: true)
            .frame(width: Self.handleTarget, height: Self.handleTarget)
            .contentShape(Circle())
            .position(point)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local).onChanged { value in
                    move(plot.celsius(atX: value.location.x).rounded())
                }
            )
            .accessibilityHidden(true)
    }
}
