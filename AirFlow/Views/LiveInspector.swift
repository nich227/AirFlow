import Charts
import SwiftUI

/// The Mac's readings, beside whatever the window is showing: each part's temperature, then the
/// last few minutes of temperature and fan speed.
struct LiveInspector: View {
    @Environment(AppModel.self) private var model
    @State private var expanded: Set<SensorGroup> = []
    @State private var explanation: Explanation = .none

    enum Explanation: Equatable {
        case none
        case working
        case text(String)
        case failed(String)
    }

    var body: some View {
        let snapshot = model.monitor.snapshot
        let format = model.settings.format
        ScrollView {
            VStack(alignment: .leading, spacing: Space.md) {
                sectionTitle("Temperatures")
                if snapshot.summaries.isEmpty {
                    Text(model.monitor.hasLoaded ? "No temperature sensors found." : "Loading sensors…")
                        .airFont(.body)
                        .foregroundStyle(.secondary)
                } else {
                    GlassCard(padding: Space.sm) {
                        VStack(spacing: 0) {
                            ForEach(snapshot.summaries, id: \.group) { summary in
                                groupRow(summary, snapshot: snapshot, format: format)
                            }
                        }
                    }
                }
                sectionTitle("Last 15 Minutes")
                    .padding(.top, Space.xs)
                GlassCard(padding: Space.sm) {
                    HistoryChart(history: model.monitor.history, format: format)
                }
                explanationView
            }
            .padding(Space.md)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .airFont(.label)
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }

    private func groupRow(_ summary: ThermalSnapshot.GroupSummary, snapshot: ThermalSnapshot, format: ReadingFormat) -> some View {
        let isOpen = Binding {
            expanded.contains(summary.group)
        } set: { open in
            if open { expanded.insert(summary.group) } else { expanded.remove(summary.group) }
        }
        let band = TemperatureBand.band(for: summary.average, in: summary.group)
        return DisclosureGroup(isExpanded: isOpen) {
            VStack(spacing: Space.xxs) {
                if summary.count > 1 {
                    detailRow("Hottest", format.temperature(summary.hottest))
                }
                ForEach(snapshot.sensors(in: summary.group).filter(\.isKnown)) { sensor in
                    detailRow(sensor.name, format.temperature(sensor.celsius))
                }
                if summary.count > 1 {
                    detailRow("Sensors", "\(summary.count)")
                }
            }
            .padding(.leading, Space.md)
            .padding(.bottom, Space.xs)
        } label: {
            HStack(spacing: Space.xs) {
                StatusDot(band: band)
                Text(summary.group.title)
                    .airFont(.body)
                Spacer()
                Text(format.temperature(summary.average))
                    .readingFont(.body)
            }
            .padding(.vertical, Space.xxs)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(summary.group.title)
            .accessibilityValue("\(format.spokenTemperature(summary.average)), \(band.word)")
        }
    }

    private func detailRow(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(value).readingFont(.label)
        }
        .airFont(.label)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var explanationView: some View {
        let availability = model.intelligence.availability
        switch explanation {
        case .none:
            Button {
                explain()
            } label: {
                Label("Explain These Readings", image: "ant-sparkles")
                    .airFont(.body)
            }
            .buttonStyle(.glass)
            .disabled(!availability.isAvailable)
            .help(availability.reason ?? "Apple Intelligence describes the last few minutes in plain words")
        case .working:
            HStack(spacing: Space.xs) {
                AirAnimation(name: Animations.spark, loops: true)
                    .frame(width: IconSize.state, height: IconSize.state)
                Text("Summarizing recent readings…")
                    .airFont(.body)
                    .foregroundStyle(.secondary)
            }
        case .text(let text):
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(readings: text)
                    .airFont(.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text("Summarized by Apple Intelligence on this Mac.")
                    .airFont(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    explain()
                } label: {
                    Text("Explain Again")
                        .airFont(.body)
                }
                .buttonStyle(.glass)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(message)
                    .airFont(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    explain()
                } label: {
                    Text("Try Again")
                        .airFont(.body)
                }
                .buttonStyle(.glass)
            }
        }
    }

    private func explain() {
        explanation = .working
        let digest = ThermalDigest(history: model.monitor.history, presetName: model.activePreset.name)
        let format = model.settings.format
        Task {
            do {
                explanation = .text(try await model.intelligence.explain(digest, format: format))
            } catch {
                explanation = .failed(error.localizedDescription)
            }
        }
    }
}

/// CPU and GPU temperature over time, above the fastest fan's speed over the same time.
struct HistoryChart: View {
    let history: ArraySlice<HistoryPoint>
    let format: ReadingFormat

    var body: some View {
        if history.count < 3 {
            Text("The chart fills in as AirFlow collects readings.")
                .airFont(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: Space.md) {
                let domain = Self.temperatureDomain(history, unit: format.unit)
                HStack(spacing: Space.sm) {
                    legend("CPU", color: Palette.temperature(.hot))
                    legend("GPU", color: Palette.temperature(.cool))
                }
                .accessibilityHidden(true)
                Chart {
                    ForEach(history) { point in
                        if let cpu = point.cpu {
                            temperatureMarks(point.date, format.unit.value(fromCelsius: cpu), part: "CPU", color: Palette.temperature(.hot), floor: domain.lowerBound)
                        }
                        if let gpu = point.gpu {
                            temperatureMarks(point.date, format.unit.value(fromCelsius: gpu), part: "GPU", color: Palette.temperature(.cool), floor: domain.lowerBound)
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let number = value.as(Double.self) {
                                Text("\(Int(number))°").readingFont(.caption)
                            }
                        }
                    }
                }
                .chartXAxis(.hidden)
                .chartLegend(.hidden)
                .chartYScale(domain: domain)
                .frame(height: 116)
                .accessibilityLabel("CPU and GPU temperature over the last 15 minutes")

                legend("Fastest Fan", color: Palette.accent)
                    .accessibilityHidden(true)
                Chart(history) { point in
                    AreaMark(x: .value("Time", point.date), y: .value("Fan Speed", (point.fanFractions.max() ?? 0) * 100))
                        .foregroundStyle(LinearGradient(colors: [Palette.accent.opacity(0.45), Palette.accent.opacity(0.05)], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", point.date), y: .value("Fan Speed", (point.fanFractions.max() ?? 0) * 100))
                        .foregroundStyle(Palette.accent)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
                .chartYScale(domain: 0...100)
                .chartYAxis {
                    AxisMarks(position: .leading, values: [0, 50, 100]) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let number = value.as(Int.self) {
                                Text("\(number)%").readingFont(.caption)
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(preset: .aligned, values: .automatic(desiredCount: 2)) { _ in
                        AxisValueLabel(format: .dateTime.hour().minute())
                            .font(AirType.caption.readingFont)
                    }
                }
                .frame(height: 72)
                .accessibilityLabel("Fastest fan's speed over the last 15 minutes, as a share of its range")
            }
        }
    }
}

extension HistoryChart {
    /// A bead of the series' color beside its name.
    private func legend(_ title: String, color: Color) -> some View {
        HStack(spacing: Space.xxs) {
            Circle()
                .fill(color.gradient)
                .frame(width: 7, height: 7)
                .shadow(color: color.opacity(0.7), radius: 3)
            Text(title)
                .airFont(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// One reading of a part: a fall of its color under the line, a soft light, and the line.
    @ChartContentBuilder
    private func temperatureMarks(_ date: Date, _ value: Double, part: String, color: Color, floor: Double) -> some ChartContent {
        AreaMark(x: .value("Time", date), yStart: .value("Floor", floor), yEnd: .value("Temperature", value), series: .value("Part", part))
            .foregroundStyle(LinearGradient(colors: [color.opacity(0.32), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
            .interpolationMethod(.monotone)
        LineMark(x: .value("Time", date), y: .value("Temperature", value), series: .value("Part", "\(part) light"))
            .foregroundStyle(color.opacity(0.28))
            .lineStyle(StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
            .interpolationMethod(.monotone)
        LineMark(x: .value("Time", date), y: .value("Temperature", value), series: .value("Part", part))
            .foregroundStyle(color)
            .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            .interpolationMethod(.monotone)
    }

    /// The temperatures in the history, widened to whole tens so the line never touches an edge.
    static func temperatureDomain(_ history: some Sequence<HistoryPoint>, unit: TemperatureUnit) -> ClosedRange<Double> {
        var coolest = Double.infinity
        var hottest = -Double.infinity
        for point in history {
            if let cpu = point.cpu {
                coolest = min(coolest, cpu)
                hottest = max(hottest, cpu)
            }
            if let gpu = point.gpu {
                coolest = min(coolest, gpu)
                hottest = max(hottest, gpu)
            }
        }
        guard coolest <= hottest else { return 0...100 }
        // A change of unit keeps the order, so only the two ends are converted.
        let low = unit.value(fromCelsius: coolest)
        let high = unit.value(fromCelsius: hottest)
        let lower = ((low - 3) / 10).rounded(.down) * 10
        let upper = ((high + 3) / 10).rounded(.up) * 10
        return lower...max(upper, lower + 10)
    }
}

/// Every sensor the Mac reports, with its lowest and highest reading since AirFlow opened.
struct SensorsView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var sortOrder = [KeyPathComparator(\Row.groupIndex), KeyPathComparator(\Row.name)]

    struct Row: Identifiable {
        let id: String
        let name: String
        let group: SensorGroup
        let celsius: Double
        let low: Double
        let high: Double

        /// The SMC key, which is also the row's identifier.
        var key: String { id }
        var groupIndex: Int { group.sortIndex }
    }

    private var rows: [Row] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return model.monitor.snapshot.sensors
            .filter { query.isEmpty || $0.name.lowercased().contains(query) || $0.group.title.lowercased().contains(query) || $0.key.lowercased() == query }
            .map { sensor in
                let range = model.monitor.extremes[sensor.key] ?? sensor.celsius...sensor.celsius
                return Row(id: sensor.key, name: sensor.name, group: sensor.group, celsius: sensor.celsius, low: range.lowerBound, high: range.upperBound)
            }
            .sorted(using: sortOrder)
    }

    var body: some View {
        let format = model.settings.format
        let rows = rows
        Group {
            if model.monitor.snapshot.sensors.isEmpty {
                PageEmptyState(
                    title: model.monitor.hasLoaded ? "No Sensors" : "Loading Sensors…",
                    message: model.monitor.hasLoaded ? "AirFlow can't find any temperature sensors on this Mac." : "AirFlow is reading your Mac's sensors."
                )
            } else if rows.isEmpty {
                PageEmptyState(title: "No Results for “\(search)”", message: "Check the spelling or try a new search.")
            } else {
                Table(rows, sortOrder: $sortOrder) {
                    TableColumn("Sensor", value: \.name) { row in
                        HStack(spacing: Space.xs) {
                            StatusDot(band: TemperatureBand.band(for: row.celsius, in: row.group))
                            Text(row.name)
                        }
                    }
                    TableColumn("Part", value: \.groupIndex) { row in
                        Text(row.group.title).foregroundStyle(.secondary)
                    }
                    .width(min: 70, ideal: 90, max: 120)
                    TableColumn("Key", value: \.key) { row in
                        Text(row.key).readingFont(.body).foregroundStyle(.secondary)
                    }
                    .width(min: 44, ideal: 52, max: 64)
                    TableColumn("Now", value: \.celsius) { row in
                        Text(format.temperature(row.celsius)).readingFont(.body)
                    }
                    .width(min: 50, ideal: 60, max: 80)
                    TableColumn("Low", value: \.low) { row in
                        Text(format.temperature(row.low)).readingFont(.body).foregroundStyle(.secondary)
                    }
                    .width(min: 50, ideal: 60, max: 80)
                    TableColumn("High", value: \.high) { row in
                        Text(format.temperature(row.high)).readingFont(.body).foregroundStyle(.secondary)
                    }
                    .width(min: 50, ideal: 60, max: 80)
                }
            }
        }
        .searchable(text: $search, prompt: "Search Sensors")
    }
}
