import Foundation

/// A fan that follows a sensor: minimum speed up to `startCelsius`, then a straight rise to the
/// maximum speed at `maxCelsius`.
struct SensorRule: Equatable, Codable, Sendable {
    var source: SensorSource
    var startCelsius: Double
    var maxCelsius: Double

    static let temperatureRange: ClosedRange<Double> = 20...110
    /// The least distance between the two temperatures, so the rise is never a cliff.
    static let minimumSpan: Double = 5

    init(source: SensorSource, startCelsius: Double, maxCelsius: Double) {
        self.source = source
        let range = Self.temperatureRange
        let start = min(max(startCelsius, range.lowerBound), range.upperBound - Self.minimumSpan)
        self.startCelsius = start
        self.maxCelsius = min(max(maxCelsius, start + Self.minimumSpan), range.upperBound)
    }

    /// How far up its range the fan runs at a temperature, from 0 to 1.
    func fraction(at celsius: Double) -> Double {
        min(max((celsius - startCelsius) / (maxCelsius - startCelsius), 0), 1)
    }

    func rpm(at celsius: Double, fan: Fan) -> Double {
        fan.clamp((fan.rpm(atFraction: fraction(at: celsius)) / FanPlanner.rpmStep).rounded() * FanPlanner.rpmStep)
    }
}

/// How one fan is controlled.
enum FanControl: Equatable, Codable, Sendable {
    case automatic
    case constant(rpm: Double)
    /// A constant speed given as a share of the fan's range, so one preset fits any Mac.
    case constantFraction(Double)
    case sensorBased(SensorRule)

    enum Kind: String, CaseIterable, Identifiable {
        case automatic, constant, sensorBased

        var id: String { rawValue }

        var title: String {
            switch self {
            case .automatic: return "Automatic"
            case .constant: return "Constant"
            case .sensorBased: return "Sensor-Based"
            }
        }
    }

    var kind: Kind {
        switch self {
        case .automatic: return .automatic
        case .constant, .constantFraction: return .constant
        case .sensorBased: return .sensorBased
        }
    }
}

/// What to tell the helper about one fan.
enum FanCommand: Equatable, Sendable {
    case automatic
    case speed(Double)
}

/// Turns a preset and a snapshot into one command per fan. It has no state and touches no hardware.
enum FanPlanner {
    static let rpmStep: Double = 10

    static func command(for control: FanControl, fan: Fan, snapshot: ThermalSnapshot) -> FanCommand {
        guard fan.hasUsableRange else { return .automatic }
        switch control {
        case .automatic:
            return .automatic
        case .constant(let rpm):
            return .speed(fan.clamp(rpm))
        case .constantFraction(let fraction):
            return .speed(fan.rpm(atFraction: fraction))
        case .sensorBased(let rule):
            // A rule whose sensor is gone cannot be followed, so the system takes the fan.
            guard let celsius = snapshot.celsius(for: rule.source) else { return .automatic }
            return .speed(rule.rpm(at: celsius, fan: fan))
        }
    }

    static func plan(preset: Preset, snapshot: ThermalSnapshot) -> [Int: FanCommand] {
        var commands: [Int: FanCommand] = [:]
        for fan in snapshot.fans {
            commands[fan.index] = command(for: preset.control(for: fan), fan: fan, snapshot: snapshot)
        }
        return commands
    }

    /// Whether a new command is different enough from the last one sent to send it.
    static func differs(_ new: FanCommand, from old: FanCommand?, threshold: Double = 30) -> Bool {
        switch (new, old) {
        case (.automatic, .automatic?): return false
        case (.speed(let a), .speed(let b)?): return abs(a - b) >= threshold
        default: return true
        }
    }
}

/// Returns the fans to the system when the CPU or the GPU runs past a limit, and holds them there
/// until the temperature has fallen well below it.
struct Safeguard: Equatable {
    static let limitRange: ClosedRange<Double> = 80...105
    static let defaultLimit: Double = 95
    static let releaseMargin: Double = 8

    private(set) var isEngaged = false
    private(set) var peak: Double = 0
    private(set) var trigger: SensorGroup?

    mutating func update(snapshot: ThermalSnapshot, limit: Double, isEnabled: Bool) {
        guard isEnabled else {
            self = Safeguard()
            return
        }
        let readings = [SensorGroup.cpu, .gpu].compactMap { group in
            snapshot.summary(of: group).map { (group, $0.average) }
        }
        guard let hottest = readings.max(by: { $0.1 < $1.1 }) else { return }
        if isEngaged {
            if hottest.1 < limit - Self.releaseMargin {
                self = Safeguard()
            } else {
                peak = max(peak, hottest.1)
            }
        } else if hottest.1 >= limit {
            isEngaged = true
            peak = hottest.1
            trigger = hottest.0
        }
    }
}
