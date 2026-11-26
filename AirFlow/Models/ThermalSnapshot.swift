import Foundation

/// Everything read from the SMC at one moment.
struct ThermalSnapshot: Equatable, Sendable {
    var date: Date
    var fans: [Fan]
    var sensors: [Sensor] {
        didSet { index = Index(sensors) }
    }
    /// The power the whole Mac draws, in watts, or nil on a Mac that does not report it.
    var systemWatts: Double?

    /// Each group's summary and each sensor's place, worked out once when the sensors are set.
    /// A fan, a rule, and each row of a view all ask for them every second.
    private var index: Index

    init(date: Date, fans: [Fan], sensors: [Sensor], systemWatts: Double? = nil) {
        self.date = date
        self.fans = fans
        self.sensors = sensors
        self.systemWatts = systemWatts
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

    /// The most points a chart draws. A chart builds every mark again at each reading, and
    /// fifteen minutes of one reading a second took half a processor core to draw.
    static let chartLimit = 100
    /// The spans of time one point of a chart can stand for, in seconds.
    static let chartIntervals: [TimeInterval] = [1, 2, 5, 10, 30, 60]

    /// How much time one point of a chart stands for, so that a history of this many seconds
    /// makes no more than `chartLimit` points.
    static func chartInterval(forSpan seconds: TimeInterval) -> TimeInterval {
        chartIntervals.first { seconds / $0 <= Double(chartLimit) } ?? chartIntervals[chartIntervals.count - 1]
    }

    /// The history as a chart draws it: the readings of each span of time as one point with
    /// their averages. A point has the time of its last reading, so a span that is over keeps
    /// its point, and the newest point is at the newest reading.
    static func thinned(_ history: some Collection<HistoryPoint>) -> [HistoryPoint] {
        guard let first = history.first, let last = history.reversed().first else { return [] }
        let interval = chartInterval(forSpan: last.date.timeIntervalSince(first.date))
        var result: [HistoryPoint] = []
        var bucket: [HistoryPoint] = []
        var number = 0.0
        for point in history {
            let own = (point.date.timeIntervalSinceReferenceDate / interval).rounded(.down)
            if own != number, !bucket.isEmpty {
                result.append(average(bucket))
                bucket.removeAll(keepingCapacity: true)
            }
            number = own
            bucket.append(point)
        }
        if !bucket.isEmpty { result.append(average(bucket)) }
        return result
    }

    /// One point for several: the average of each reading, at the time of the last point.
    private static func average(_ points: [HistoryPoint]) -> HistoryPoint {
        func mean(_ values: [Double]) -> Double? {
            values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        }
        let fans = points.last?.fanFractions.count ?? 0
        return HistoryPoint(
            date: points.last?.date ?? .distantPast,
            cpu: mean(points.compactMap(\.cpu)),
            gpu: mean(points.compactMap(\.gpu)),
            fanFractions: (0..<fans).map { index in
                mean(points.compactMap { $0.fanFractions.indices.contains(index) ? $0.fanFractions[index] : nil }) ?? 0
            }
        )
    }
}
