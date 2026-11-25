import Foundation

enum TemperatureUnit: String, CaseIterable, Identifiable, Codable, Sendable {
    case celsius, fahrenheit

    var id: String { rawValue }

    var title: String { self == .celsius ? "Celsius" : "Fahrenheit" }

    var symbol: String { self == .celsius ? "°C" : "°F" }

    func value(fromCelsius celsius: Double) -> Double {
        self == .celsius ? celsius : celsius * 9 / 5 + 32
    }

    func celsius(from value: Double) -> Double {
        self == .celsius ? value : (value - 32) * 5 / 9
    }
}

/// Writes temperatures and speeds the same way everywhere.
struct ReadingFormat: Equatable, Sendable {
    var unit: TemperatureUnit = .celsius
    var isPrecise = false

    /// "62°" or "62.4°". The degree sign stands alone where the unit is clear from context.
    func temperature(_ celsius: Double?) -> String {
        guard let celsius else { return "--" }
        return number(unit.value(fromCelsius: celsius)) + "°"
    }

    /// "62 °C", for a place where the unit must be stated.
    func temperatureWithUnit(_ celsius: Double?) -> String {
        guard let celsius else { return "--" }
        return number(unit.value(fromCelsius: celsius)) + " " + unit.symbol
    }

    /// A temperature as VoiceOver should say it.
    func spokenTemperature(_ celsius: Double?) -> String {
        guard let celsius else { return "not available" }
        return number(unit.value(fromCelsius: celsius)) + " degrees " + unit.title
    }

    private func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(isPrecise ? 1 : 0)))
    }

    static func rpm(_ rpm: Double) -> String {
        rpm.rounded().formatted(.number.precision(.fractionLength(0)))
    }

    static func rpmWithUnit(_ rpm: Double) -> String {
        self.rpm(rpm) + " RPM"
    }

    static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    /// "9:30 AM" for minutes after midnight.
    static func time(minuteOfDay: Int) -> String {
        var components = DateComponents()
        components.hour = minuteOfDay / 60
        components.minute = minuteOfDay % 60
        guard let date = Calendar.current.date(from: components) else { return "" }
        return date.formatted(date: .omitted, time: .shortened)
    }
}

/// How hot a reading is for the part it belongs to. The band picks the color and the word, so a
/// 45 degree battery reads as hot while a 45 degree CPU reads as cool.
enum TemperatureBand: Int, CaseIterable, Comparable, Sendable {
    case cool, mild, warm, hot, critical

    static func < (lhs: TemperatureBand, rhs: TemperatureBand) -> Bool { lhs.rawValue < rhs.rawValue }

    var word: String {
        switch self {
        case .cool: return "Cool"
        case .mild: return "Normal"
        case .warm: return "Warm"
        case .hot: return "Hot"
        case .critical: return "Very Hot"
        }
    }

    /// The temperatures where each band above `cool` begins.
    static func thresholds(for group: SensorGroup) -> [Double] {
        switch group {
        case .cpu, .gpu, .other: return [50, 70, 85, 95]
        case .battery: return [30, 35, 40, 45]
        case .storage: return [40, 50, 60, 70]
        case .memory, .enclosure, .power, .wireless: return [45, 55, 65, 80]
        }
    }

    static func band(for celsius: Double, in group: SensorGroup) -> TemperatureBand {
        let passed = thresholds(for: group).filter { celsius >= $0 }.count
        return TemperatureBand(rawValue: passed) ?? .critical
    }
}
