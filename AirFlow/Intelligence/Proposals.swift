import Foundation

/// A preset as the model proposed it, before anything is trusted. Every number here is checked
/// and clamped when the proposal becomes a preset, by the same code a hand-made preset goes through.
struct PresetProposal: Equatable, Sendable {
    enum Mode: String, Equatable, Sendable {
        case automatic, constant, sensorBased
    }

    var name: String
    var mode: Mode
    /// For a constant speed: the share of the fan's range, 0 to 100.
    var speedPercent: Int
    var sensor: SensorGroup
    var startCelsius: Int
    var fullSpeedCelsius: Int
    var summary: String

    /// The control every fan gets.
    var control: FanControl {
        switch mode {
        case .automatic:
            return .automatic
        case .constant:
            return .constantFraction(Double(min(max(speedPercent, 0), 100)) / 100)
        case .sensorBased:
            return .sensorBased(SensorRule(
                source: .group(sensor, .average),
                startCelsius: Double(startCelsius),
                maxCelsius: Double(fullSpeedCelsius)
            ))
        }
    }

    func makePreset() -> Preset {
        let cleaned = Preset.cleanName(name)
        return Preset(
            name: cleaned.isEmpty ? "New Preset" : cleaned,
            icon: icon,
            fallback: control,
            summary: String(summary.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
        )
    }

    /// An icon that fits what the preset does.
    private var icon: PresetIcon {
        switch mode {
        case .automatic: return .cloud
        case .constant: return speedPercent >= 60 ? .fire : .sound
        case .sensorBased:
            if sensor == .battery { return .compass }
            return startCelsius >= 65 ? .moon : .dashboard
        }
    }
}

/// A rule as the model proposed it.
struct RuleProposal: Equatable, Sendable {
    enum Trigger: String, Equatable, Sendable {
        case app, battery, adapter, temperature, time
    }

    var trigger: Trigger
    var appName: String
    var sensor: SensorGroup
    var celsius: Int
    var startHour: Int
    var endHour: Int
    var presetName: String

    enum Failure: Error, Equatable, LocalizedError {
        case unknownPreset(String)
        case unknownApp(String)
        case emptyTimeRange

        var errorDescription: String? {
            switch self {
            case .unknownPreset(let name): return "There's no preset named “\(name)”."
            case .unknownApp(let name): return name.isEmpty ? "The rule doesn't name an app." : "AirFlow can't find an app named “\(name)”."
            case .emptyTimeRange: return "The rule's start and end times are the same."
            }
        }
    }

    func makeRule(presets: [Preset], apps: [AppDirectory.App]) throws -> AutomationRule {
        let wanted = presetName.trimmingCharacters(in: .whitespaces).lowercased()
        guard let preset = presets.first(where: { $0.name.lowercased() == wanted })
            ?? presets.first(where: { !wanted.isEmpty && $0.name.lowercased().contains(wanted) })
        else { throw Failure.unknownPreset(presetName) }

        let made: AutomationTrigger
        switch trigger {
        case .app:
            guard let app = AppDirectory.find(named: appName, among: apps) else { throw Failure.unknownApp(appName) }
            made = .appIsFrontmost(bundleID: app.bundleID, name: app.name)
        case .battery:
            made = .powerSource(.battery)
        case .adapter:
            made = .powerSource(.adapter)
        case .temperature:
            let range = SensorRule.temperatureRange
            let threshold = min(max(Double(celsius), range.lowerBound), range.upperBound)
            made = .temperatureAbove(source: .group(sensor, .average), celsius: threshold)
        case .time:
            let start = min(max(startHour, 0), 23) * 60
            let end = min(max(endHour, 0), 23) * 60
            guard start != end else { throw Failure.emptyTimeRange }
            made = .timeRange(startMinute: start, endMinute: end)
        }
        return AutomationRule(trigger: made, presetID: preset.id)
    }
}

/// The numbers the model is given to explain recent thermal behavior.
struct ThermalDigest: Equatable, Sendable {
    var minutes: Int
    var cpuLow: Double
    var cpuAverage: Double
    var cpuHigh: Double
    var fanAverage: Double
    var fanHigh: Double
    var presetName: String

    init?(history: some BidirectionalCollection<HistoryPoint>, presetName: String) {
        let cpu = history.compactMap(\.cpu)
        guard cpu.count >= 5, let first = history.first, let last = history.last,
              let low = cpu.min(), let high = cpu.max()
        else { return nil }
        let fans = history.map { $0.fanFractions.max() ?? 0 }
        minutes = max(1, Int((last.date.timeIntervalSince(first.date) / 60).rounded()))
        cpuLow = low
        cpuAverage = cpu.reduce(0, +) / Double(cpu.count)
        cpuHigh = high
        fanAverage = fans.reduce(0, +) / Double(max(fans.count, 1))
        fanHigh = fans.max() ?? 0
        self.presetName = presetName
    }

    func prompt(format: ReadingFormat) -> String {
        """
        Over the last \(minutes) minutes the Mac's CPU averaged \(format.temperatureWithUnit(cpuAverage)), \
        with a low of \(format.temperatureWithUnit(cpuLow)) and a high of \(format.temperatureWithUnit(cpuHigh)). \
        The fastest fan averaged \(ReadingFormat.percent(fanAverage)) of its range and peaked at \
        \(ReadingFormat.percent(fanHigh)). The active fan preset is "\(presetName)".
        """
    }
}
