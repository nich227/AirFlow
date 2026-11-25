import Foundation

/// Everything read from the SMC at one moment.
struct ThermalSnapshot: Equatable, Sendable {
    var date: Date
    var fans: [Fan]
    var sensors: [Sensor] {
        didSet { index = Index(sensors) }
    }

    /// Each group's summary and each sensor's place, worked out once when the sensors are set.
    /// A fan, a rule, and each row of a view all ask for them every second.
    private var index: Index

    init(date: Date, fans: [Fan], sensors: [Sensor]) {
        self.date = date
        self.fans = fans
        self.sensors = sensors
        index = Index(sensors)
    }

    static let empty = ThermalSnapshot(date: .distantPast, fans: [], sensors: [])

    struct GroupSummary: Equatable, Sendable {
        let group: SensorGroup
        let average: Double
        let hottest: Double
        let count: Int
    }

    private struct Index: Equatable, Sendable {
        var summaries: [SensorGroup: GroupSummary] = [:]
        var positions: [String: Int] = [:]

        init(_ sensors: [Sensor]) {
            var values: [SensorGroup: [Double]] = [:]
            positions.reserveCapacity(sensors.count)
            for (position, sensor) in sensors.enumerated() {
                values[sensor.group, default: []].append(sensor.celsius)
                if positions[sensor.key] == nil { positions[sensor.key] = position }
            }
            for (group, readings) in values {
                summaries[group] = ThermalSnapshot.summarize(readings, group: group)
            }
        }
    }

    func sensors(in group: SensorGroup) -> [Sensor] {
        sensors.filter { $0.group == group }
    }

    func sensor(key: String) -> Sensor? {
        index.positions[key].map { sensors[$0] }
    }

    func summary(of group: SensorGroup) -> GroupSummary? {
        index.summaries[group]
    }

    /// A group reduced to an average and a hottest value. A reading far below the group's
    /// median is a sensor that is switched off or reports something else, so it is left out.
    private static func summarize(_ readings: [Double], group: SensorGroup) -> GroupSummary? {
        let values = readings.sorted()
        guard !values.isEmpty else { return nil }
        let median = values[values.count / 2]
        let trusted = values.filter { $0 >= median - Self.outlierMargin }
        guard let hottest = trusted.last else { return nil }
        return GroupSummary(
            group: group,
            average: trusted.reduce(0, +) / Double(trusted.count),
            hottest: hottest,
            count: values.count
        )
    }

    func celsius(for source: SensorSource) -> Double? {
        switch source {
        case .group(let group, let reduction):
            guard let summary = summary(of: group) else { return nil }
            return reduction == .average ? summary.average : summary.hottest
        case .key(let key):
            return sensor(key: key)?.celsius
        }
    }

    func name(of source: SensorSource) -> String {
        switch source {
        case .group(let group, let reduction):
            return "\(group.title) \(reduction.title)"
        case .key(let key):
            return sensor(key: key)?.name ?? key
        }
    }

    var summaries: [GroupSummary] {
        SensorGroup.primary.compactMap(summary(of:))
    }

    static let outlierMargin: Double = 25
}

/// One point of the history chart.
struct HistoryPoint: Identifiable, Equatable, Sendable {
    let date: Date
    let cpu: Double?
    let gpu: Double?
    /// Each fan's speed as a fraction of its range, by fan index.
    let fanFractions: [Double]

    var id: Date { date }
}
