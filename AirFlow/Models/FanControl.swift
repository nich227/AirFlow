import Foundation

/// A fan that follows a sensor. The speed stays at the minimum up to `startCelsius`, then rises in
/// a straight line to the maximum at `maxCelsius`. A rule can also leave the fan to the system
/// below `startCelsius`.
struct SensorRule: Equatable, Codable, Sendable {
    /// What the fan does while the sensor is below the start temperature.
    enum BelowStart: String, Codable, CaseIterable, Sendable {
        /// AirFlow holds the fan at its minimum speed.
        case minimum
        /// The system controls the fan, so it can still cool a part the rule does not follow.
        case automatic

        var title: String {
            switch self {
            case .minimum: return "Minimum Speed"
            case .automatic: return "Automatic"
            }
        }
    }

    var source: SensorSource
    var startCelsius: Double
    var maxCelsius: Double
    var belowStart: BelowStart

    static let temperatureRange: ClosedRange<Double> = 20...110
    /// The least distance between the two temperatures, so the rise is never a jump.
    static let minimumSpan: Double = 5
    /// A fan that the system has below the start temperature is taken at that temperature and
    /// given back this far below it, so it does not change hands at each small change.
    static let restMargin: Double = 2

    init(source: SensorSource, startCelsius: Double, maxCelsius: Double, belowStart: BelowStart = .minimum) {
        self.source = source
        self.belowStart = belowStart
        let range = Self.temperatureRange
        let start = min(max(startCelsius, range.lowerBound), range.upperBound - Self.minimumSpan)
        self.startCelsius = start
        self.maxCelsius = min(max(maxCelsius, start + Self.minimumSpan), range.upperBound)
    }

    private enum CodingKeys: String, CodingKey {
        case source, startCelsius, maxCelsius, belowStart
    }

    /// A stored rule goes through the same limits as any other, and one stored before
    /// `belowStart` existed holds the fan at its minimum.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            source: try values.decode(SensorSource.self, forKey: .source),
            startCelsius: try values.decode(Double.self, forKey: .startCelsius),
            maxCelsius: try values.decode(Double.self, forKey: .maxCelsius),
            belowStart: try values.decodeIfPresent(BelowStart.self, forKey: .belowStart) ?? .minimum
        )
    }

    /// Whether the rule leaves the fan to the system at a temperature.
    /// - Parameter isHeld: whether AirFlow holds the fan now.
    func rests(at celsius: Double, isHeld: Bool) -> Bool {
        guard belowStart == .automatic else { return false }
        return celsius < (isHeld ? startCelsius - Self.restMargin : startCelsius)
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

    /// - Parameter isHeld: whether AirFlow holds the fan now. Only a sensor rule that leaves the
    ///   fan to the system below its start temperature uses it.
    static func command(for control: FanControl, fan: Fan, snapshot: ThermalSnapshot, isHeld: Bool = false) -> FanCommand {
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
            if rule.rests(at: celsius, isHeld: isHeld) { return .automatic }
            return .speed(rule.rpm(at: celsius, fan: fan))
        }
    }

    /// - Parameter adaptiveFraction: the share of each fan's range that the adaptive controller
    ///   asks for. Only the Adaptive preset uses it. Without it, that preset leaves every fan
    ///   to the system.
    /// - Parameter held: the fans AirFlow holds now, by fan index.
    static func plan(
        preset: Preset, snapshot: ThermalSnapshot, adaptiveFraction: Double? = nil, held: Set<Int> = []
    ) -> [Int: FanCommand] {
        var commands: [Int: FanCommand] = [:]
        for fan in snapshot.fans {
            if preset.kind == .adaptive {
                commands[fan.index] = adaptiveCommand(fan: fan, fraction: adaptiveFraction)
            } else {
                commands[fan.index] = command(
                    for: preset.control(for: fan), fan: fan, snapshot: snapshot, isHeld: held.contains(fan.index)
                )
            }
        }
        return commands
    }

    /// The adaptive controller's share of the range as a speed for one fan, between the fan's
    /// own limits.
    static func adaptiveCommand(fan: Fan, fraction: Double?) -> FanCommand {
        guard fan.hasUsableRange, let fraction, fraction.isFinite else { return .automatic }
        return .speed(fan.clamp((fan.rpm(atFraction: fraction) / rpmStep).rounded() * rpmStep))
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

/// Returns the fans to the system when the CPU or the GPU runs past a limit. It holds them there
/// until the temperature falls well below the limit.
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
