import Foundation
@testable import AirFlow

/// Records what the control loop sends, in order.
final class CommandRecorder: FanCommanding, @unchecked Sendable {
    enum Call: Equatable {
        case speed(Int, Double)
        case automatic(Int)
        case resetAll
        case keepAlive
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    var failure: Error?

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    private func record(_ call: Call) throws {
        lock.lock()
        recorded.append(call)
        let failure = failure
        lock.unlock()
        if let failure { throw failure }
    }

    func setFan(_ index: Int, rpm: Double) async throws { try record(.speed(index, rpm)) }
    func setFanAutomatic(_ index: Int) async throws { try record(.automatic(index)) }
    func resetAllFans() async throws { try record(.resetAll) }
    func keepAlive() async { try? record(.keepAlive) }
}

enum Fixtures {
    static func fan(_ index: Int = 0, current: Double = 2000, manual: Bool = false) -> Fan {
        Fan(
            index: index, name: Fan.name(index: index, count: 2), minimumRPM: 1000, maximumRPM: 5000,
            currentRPM: current, targetRPM: current, isManual: manual
        )
    }

    static func snapshot(cpu: Double = 60, gpu: Double? = 50, battery: Double? = 30, fans: [Fan]? = nil, date: Date = Date()) -> ThermalSnapshot {
        var sensors = [
            Sensor(key: "Tp01", name: "Performance Core Sensor 1", group: .cpu, celsius: cpu - 2, isKnown: false),
            Sensor(key: "Tp02", name: "Performance Core Sensor 2", group: .cpu, celsius: cpu + 2, isKnown: false),
        ]
        if let gpu { sensors.append(Sensor(key: "Tg01", name: "GPU Sensor 1", group: .gpu, celsius: gpu, isKnown: false)) }
        if let battery { sensors.append(Sensor(key: "TB1T", name: "Battery Cell 1", group: .battery, celsius: battery)) }
        return ThermalSnapshot(date: date, fans: fans ?? [fan(0), fan(1)], sensors: sensors)
    }

    static func context(
        app: String? = nil, power: PowerSource = .adapter, minute: Int = 12 * 60, snapshot: ThermalSnapshot = snapshot()
    ) -> AutomationContext {
        AutomationContext(frontmostBundleID: app, powerSource: power, minuteOfDay: minute, snapshot: snapshot)
    }

    /// Waits for work the main actor has queued, such as the control loop's sends.
    @MainActor
    static func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
    }
}
