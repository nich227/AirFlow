import Foundation

/// The part of the Mac a temperature sensor belongs to.
enum SensorGroup: String, CaseIterable, Codable, Sendable, Identifiable {
    case cpu, gpu, memory, storage, battery, enclosure, power, wireless, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .memory: return "Memory"
        case .storage: return "Storage"
        case .battery: return "Battery"
        case .enclosure: return "Enclosure"
        case .power: return "Power"
        case .wireless: return "Wireless"
        case .other: return "Other"
        }
    }

    /// The groups a person reads at a glance. `other` holds sensors with no known meaning.
    static let primary: [SensorGroup] = [.cpu, .gpu, .memory, .storage, .battery, .enclosure, .power, .wireless]
}

enum SensorReduction: String, Codable, Sendable, CaseIterable {
    case average, hottest

    var title: String { self == .average ? "Average" : "Hottest" }
}

/// What a rule or a readout follows: a whole group reduced to one number, or one sensor.
enum SensorSource: Hashable, Codable, Sendable {
    case group(SensorGroup, SensorReduction)
    case key(String)

    static let cpuAverage = SensorSource.group(.cpu, .average)
}

/// One temperature sensor. The backend names it: a sensor whose meaning is known gets a plain
/// name, and any other is named for its group and its key.
struct Sensor: Identifiable, Equatable, Sendable {
    let key: String
    let name: String
    let group: SensorGroup
    var celsius: Double
    /// False for a sensor whose meaning is not known. Its name is its part's, with a number.
    var isKnown = true

    var id: String { key }
}
