import XCTest
@testable import AirFlow

final class ThermalSnapshotTests: XCTestCase {
    func testSummaryAveragesAndFindsTheHottest() {
        let summary = Fixtures.snapshot(cpu: 60).summary(of: .cpu)
        XCTAssertEqual(summary?.average, 60)
        XCTAssertEqual(summary?.hottest, 62)
        XCTAssertEqual(summary?.count, 2)
    }

    func testAReadingFarBelowItsGroupIsLeftOutOfTheAverage() {
        var snapshot = Fixtures.snapshot(cpu: 80)
        snapshot.sensors.append(Sensor(key: "Tp03", name: "x", group: .cpu, celsius: 80))
        snapshot.sensors.append(Sensor(key: "Tp04", name: "x", group: .cpu, celsius: 6))
        let summary = snapshot.summary(of: .cpu)
        XCTAssertEqual(summary?.average ?? 0, 80, accuracy: 0.01)
        XCTAssertEqual(summary?.count, 4)
    }

    func testAGroupWithNoSensorsHasNoSummary() {
        XCTAssertNil(Fixtures.snapshot(gpu: nil).summary(of: .gpu))
        XCTAssertNil(Fixtures.snapshot().celsius(for: .group(.memory, .average)))
    }

    func testSources() {
        let snapshot = Fixtures.snapshot(cpu: 60, battery: 31)
        XCTAssertEqual(snapshot.celsius(for: .cpuAverage), 60)
        XCTAssertEqual(snapshot.celsius(for: .group(.cpu, .hottest)), 62)
        XCTAssertEqual(snapshot.celsius(for: .key("TB1T")), 31)
        XCTAssertNil(snapshot.celsius(for: .key("none")))
        XCTAssertEqual(snapshot.name(of: .cpuAverage), "CPU Average")
        XCTAssertEqual(snapshot.name(of: .key("TB1T")), "Battery Cell 1")
    }
}

@MainActor
final class ThermalMonitorTests: XCTestCase {
    func testHistoryKeepsOnlyTheLastFifteenMinutes() {
        let monitor = ThermalMonitor(sampler: HardwareSampler(makeSource: { throw HardwareError.cannotOpenSMC }))
        let start = Date(timeIntervalSince1970: 1_000_000)
        for second in stride(from: 0, through: 1200, by: 10) {
            monitor.ingest(Fixtures.snapshot(cpu: 50, date: start.addingTimeInterval(Double(second))))
        }
        let cutoff = start.addingTimeInterval(1200 - ThermalMonitor.historyDuration)
        XCTAssertEqual(monitor.history.first?.date, cutoff)
        XCTAssertEqual(monitor.history.count, 91)
    }

    func testExtremesFollowEachSensor() {
        let monitor = ThermalMonitor(sampler: HardwareSampler(makeSource: { throw HardwareError.cannotOpenSMC }))
        monitor.ingest(Fixtures.snapshot(cpu: 50))
        monitor.ingest(Fixtures.snapshot(cpu: 70))
        monitor.ingest(Fixtures.snapshot(cpu: 60))
        XCTAssertEqual(monitor.extremes["Tp01"], 48...68)
    }

    func testAnSMCThatCannotBeOpenedIsReported() async {
        let monitor = ThermalMonitor(sampler: HardwareSampler(makeSource: { throw HardwareError.cannotOpenSMC }))
        await monitor.refresh()
        XCTAssertTrue(monitor.hasLoaded)
        XCTAssertFalse(monitor.isAvailable)
    }

    func testEachSnapshotReachesTheListener() async {
        let monitor = ThermalMonitor(sampler: HardwareSampler(makeSource: {
            guard let reader = BackendReader(sample: true) else { throw HardwareError.cannotOpenSMC }
            return reader
        }))
        var received: [ThermalSnapshot] = []
        monitor.onSnapshot = { received.append($0) }
        await monitor.refresh()
        XCTAssertTrue(monitor.isAvailable)
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.fans.count, 2)
        XCTAssertEqual(monitor.history.count, 1)
    }

    func testReadingsMoveEverySecondWhileSomethingShowsThem() {
        XCTAssertEqual(ThermalMonitor.visibleInterval, .seconds(1))
        XCTAssertGreaterThan(ThermalMonitor.backgroundInterval, ThermalMonitor.visibleInterval)
    }
}
