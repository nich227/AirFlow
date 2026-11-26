import Foundation
import Observation

/// Holds the latest readings and a short history, and feeds each new snapshot to whoever asked.
@MainActor
@Observable
final class ThermalMonitor {
    static let historyDuration: TimeInterval = 15 * 60
    /// While a window or the panel shows readings, they and the history chart move every second.
    static let visibleInterval: Duration = .seconds(1)
    static let backgroundInterval: Duration = .seconds(4)

    private(set) var snapshot: ThermalSnapshot = .empty
    /// The points of the last 15 minutes, oldest first.
    var history: ArraySlice<HistoryPoint> { points[firstLive...] }
    /// The history's storage. A point that is too old is skipped, and the storage is cut only when
    /// half of it is too old. So a reading costs the same however long the history is.
    private var points: [HistoryPoint] = []
    private var firstLive = 0
    /// False until the first read works, and again if the SMC cannot be opened.
    private(set) var isAvailable = false
    private(set) var hasLoaded = false
    /// The lowest and highest reading of each sensor since launch, by key.
    private(set) var extremes: [String: ClosedRange<Double>] = [:]

    /// Raised by each window or panel that is showing readings, so the monitor reads more often.
    var visibleSurfaces = 0

    @ObservationIgnored var onSnapshot: ((ThermalSnapshot) -> Void)?
    @ObservationIgnored private let sampler: HardwareSampler
    @ObservationIgnored private var loop: Task<Void, Never>?

    init(sampler: HardwareSampler = HardwareSampler()) {
        self.sampler = sampler
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(for: self.visibleSurfaces > 0 ? Self.visibleInterval : Self.backgroundInterval)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    func refresh() async {
        do {
            ingest(try await sampler.sample())
        } catch {
            isAvailable = false
            hasLoaded = true
            Log.hardware.error("SMC read failed: \(String(describing: error), privacy: .public)")
        }
    }

    func ingest(_ new: ThermalSnapshot) {
        isAvailable = true
        hasLoaded = true
        snapshot = new
        for sensor in new.sensors {
            if let range = extremes[sensor.key] {
                extremes[sensor.key] = min(range.lowerBound, sensor.celsius)...max(range.upperBound, sensor.celsius)
            } else {
                extremes[sensor.key] = sensor.celsius...sensor.celsius
            }
        }
        points.append(HistoryPoint(
            date: new.date,
            cpu: new.summary(of: .cpu)?.average,
            gpu: new.summary(of: .gpu)?.average,
            fanFractions: new.fans.map(\.fraction)
        ))
        let cutoff = new.date.addingTimeInterval(-Self.historyDuration)
        // The points are ordered by time, so the ones that are too old are at the front.
        while firstLive < points.count, points[firstLive].date < cutoff {
            firstLive += 1
        }
        if firstLive > points.count / 2 {
            points.removeFirst(firstLive)
            firstLive = 0
        }
        onSnapshot?(new)
    }
}
