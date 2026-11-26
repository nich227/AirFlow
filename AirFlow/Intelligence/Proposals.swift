import Foundation

/// A preset as the model proposed it, before anything is trusted. When the proposal becomes a
/// preset, the same code that handles a hand-made preset checks and clamps every number here.
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

/// What the model proposes an app is known for. A person accepts it before it counts.
struct WorkloadProposal: Equatable, Sendable {
    var regime: WorkloadRegime
    var reason: String

    static let reasonLimit = 160

    /// The proposal with its sentence trimmed to one line of bounded length.
    var cleaned: WorkloadProposal {
        let line = reason.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return WorkloadProposal(regime: regime, reason: String(line.trimmingCharacters(in: .whitespaces).prefix(Self.reasonLimit)))
    }
}

/// How hard one installed app works the Mac, measured from its processes. A share of 1 is one
/// whole processor core.
struct AppLoad: Equatable, Sendable {
    var name: String
    var bundleID: String
    /// The share of a core the app used between two readings a moment apart.
    var coresNow: Double
    /// The share of a core the app has used on average since it opened.
    var coresOverall: Double
    /// The processor time the app has used since it opened.
    var cpuSeconds: Double

    /// An app counts as heavy if it uses half a core now, or a quarter of a core on average
    /// over at least a minute of processor time. The minute keeps out an app that just opened.
    static let heavyCoresNow = 0.5
    static let heavyCoresOverall = 0.25
    static let heavyCPUSeconds: Double = 60
    /// The model is asked only about an app that uses at least this share now or on average. Below
    /// it, the model called small utilities heavy that used a tenth of a core.
    static let listedCores = 0.15

    var isHeavy: Bool {
        coresNow >= Self.heavyCoresNow || (coresOverall >= Self.heavyCoresOverall && cpuSeconds >= Self.heavyCPUSeconds)
    }

    /// The larger of the two shares, by which the apps are ordered.
    var cores: Double { max(coresNow, coresOverall) }

    /// The loads of the installed apps that are running, the busiest first.
    /// - Parameters:
    ///   - before: the running apps at one moment.
    ///   - after: the running apps `seconds` later.
    ///   - bundleID: the identifier of the app at a path, or nil if it is not an app.
    ///   - own: AirFlow's identifier. Every copy of AirFlow is left out: this one, and one with a
    ///     longer identifier that starts with it.
    static func loads(
        before: [AppUsage], after: [AppUsage], seconds: Double, installed: [AppDirectory.App], own: String,
        bundleID: (String) -> String?
    ) -> [AppLoad] {
        let earlier = Dictionary(before.map { ($0.bundlePath, $0.cpuSeconds) }, uniquingKeysWith: { first, _ in first })
        let names = Dictionary(installed.map { ($0.bundleID, $0.name) }, uniquingKeysWith: { first, _ in first })
        var loads: [String: AppLoad] = [:]
        for usage in after {
            guard let id = bundleID(usage.bundlePath), id != own, !id.hasPrefix(own + "."), let name = names[id] else { continue }
            // An app that opened between the two readings has no earlier time, so it has no share now.
            let used = earlier[usage.bundlePath].map { max(usage.cpuSeconds - $0, 0) } ?? 0
            let now = seconds > 0 ? used / seconds : 0
            let overall = usage.runningSeconds > 0 ? usage.cpuSeconds / usage.runningSeconds : 0
            // Two copies of one app count as one.
            var load = loads[id] ?? AppLoad(name: name, bundleID: id, coresNow: 0, coresOverall: 0, cpuSeconds: 0)
            load.coresNow += now
            load.coresOverall += overall
            load.cpuSeconds += usage.cpuSeconds
            loads[id] = load
        }
        return loads.values.sorted { ($0.cores, $1.name) > ($1.cores, $0.name) }
    }
}

/// The apps to select in the grid of apps: the ones measured as heavy, the busy ones the model
/// judged heavy, and the ones AirFlow knows. The person sees them selected and decides which to add.
struct AppSelectionProposal: Equatable, Sendable {
    var names: [String]

    /// The most apps one proposal can select.
    static let limit = 24

    /// The installed apps the proposal names, without the ones that have an entry already. A name
    /// counts only if it is an installed app's whole name, whatever its case, so the model cannot
    /// select an app it was not shown.
    func apps(among installed: [AppDirectory.App], excluding added: Set<String>) -> [AppDirectory.App] {
        var seen = Set<String>()
        var result: [AppDirectory.App] = []
        for name in names {
            let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let app = installed.first(where: { $0.name.lowercased() == wanted }),
                  !added.contains(app.bundleID), seen.insert(app.bundleID).inserted
            else { continue }
            result.append(app)
            if result.count == Self.limit { break }
        }
        return result
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
