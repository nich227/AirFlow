import Foundation

enum PowerSource: String, Codable, Sendable, CaseIterable, Identifiable {
    case battery, adapter

    var id: String { rawValue }

    var title: String { self == .battery ? "Battery" : "Power Adapter" }
}

/// The condition that makes a rule match.
enum AutomationTrigger: Equatable, Codable, Sendable {
    case appIsFrontmost(bundleID: String, name: String)
    case powerSource(PowerSource)
    case temperatureAbove(source: SensorSource, celsius: Double)
    /// Minutes after midnight. A range that ends before it starts runs past midnight.
    case timeRange(startMinute: Int, endMinute: Int)

    enum Kind: String, CaseIterable, Identifiable {
        case app, power, temperature, time

        var id: String { rawValue }

        var title: String {
            switch self {
            case .app: return "App Is Frontmost"
            case .power: return "Power Source"
            case .temperature: return "Temperature Rises Above"
            case .time: return "Time of Day"
            }
        }

        var iconName: String {
            switch self {
            case .app: return "ant-appstore"
            case .power: return "ant-thunderbolt"
            case .temperature: return "ant-fire"
            case .time: return "ant-clock-circle"
            }
        }
    }

    var kind: Kind {
        switch self {
        case .appIsFrontmost: return .app
        case .powerSource: return .power
        case .temperatureAbove: return .temperature
        case .timeRange: return .time
        }
    }
}

/// When the trigger holds, Autopilot applies the preset.
struct AutomationRule: Identifiable, Equatable, Codable, Sendable {
    var id: UUID = UUID()
    var trigger: AutomationTrigger
    var presetID: UUID
    var isEnabled: Bool = true
}

/// What the rules are judged against.
struct AutomationContext: Equatable, Sendable {
    var frontmostBundleID: String?
    var powerSource: PowerSource
    /// Minutes after midnight, local time.
    var minuteOfDay: Int
    var snapshot: ThermalSnapshot
}

/// Picks the rule that applies. The first enabled rule that matches wins, so the order of the
/// rules is their priority.
struct AutomationEngine: Equatable {
    /// A temperature rule keeps matching until the sensor falls this far below its threshold.
    static let temperatureHysteresis: Double = 5

    /// The temperature rules that are currently holding.
    private(set) var latched: Set<UUID> = []

    mutating func match(rules: [AutomationRule], context: AutomationContext, presets: Set<UUID>) -> AutomationRule? {
        latched.formIntersection(rules.map(\.id))
        var winner: AutomationRule?
        for rule in rules where rule.isEnabled && presets.contains(rule.presetID) {
            if matches(rule, context: context), winner == nil {
                winner = rule
            }
        }
        return winner
    }

    private mutating func matches(_ rule: AutomationRule, context: AutomationContext) -> Bool {
        switch rule.trigger {
        case .appIsFrontmost(let bundleID, _):
            return context.frontmostBundleID == bundleID
        case .powerSource(let source):
            return context.powerSource == source
        case .timeRange(let start, let end):
            return Self.minute(context.minuteOfDay, isBetween: start, and: end)
        case .temperatureAbove(let source, let threshold):
            guard let celsius = context.snapshot.celsius(for: source) else {
                latched.remove(rule.id)
                return false
            }
            let floor = latched.contains(rule.id) ? threshold - Self.temperatureHysteresis : threshold
            if celsius >= floor {
                latched.insert(rule.id)
                return true
            }
            latched.remove(rule.id)
            return false
        }
    }

    static func minute(_ minute: Int, isBetween start: Int, and end: Int) -> Bool {
        if start == end { return false }
        if start < end { return minute >= start && minute < end }
        return minute >= start || minute < end
    }
}
