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

    func testOnlyThePartsAirFlowActsOnAreReadOnEverySample() {
        let slow: Set<SensorGroup> = [.cpu, .gpu, .memory, .storage, .battery, .enclosure, .power, .wireless]
        XCTAssertEqual(ThermalMonitor.groups(forSample: 0, followed: [], listsEverySensor: false), slow, "The first sample reads every part")
        for number in 1..<ThermalMonitor.slowGroupInterval {
            XCTAssertEqual(ThermalMonitor.groups(forSample: number, followed: [], listsEverySensor: false), [.cpu, .gpu])
        }
        XCTAssertEqual(ThermalMonitor.groups(forSample: ThermalMonitor.slowGroupInterval, followed: [], listsEverySensor: false), slow)
        XCTAssertEqual(ThermalMonitor.groups(forSample: 3, followed: [.battery], listsEverySensor: false), [.cpu, .gpu, .battery], "A part a preset follows is read every time")
        XCTAssertEqual(ThermalMonitor.groups(forSample: 3, followed: [.other], listsEverySensor: false), [.cpu, .gpu, .other])
        XCTAssertFalse(ThermalMonitor.groups(forSample: 0, followed: [], listsEverySensor: false).contains(.other), "The sensors of no part are read only for a page that lists them")
        XCTAssertEqual(ThermalMonitor.groups(forSample: 3, followed: [], listsEverySensor: true), Set(SensorGroup.allCases))
        XCTAssertEqual(ThermalMonitor.slowGroupInterval, 5)
    }

    func testTheMonitorAsksTheReaderForThosePartsSampleBySample() async {
        let source = GroupRecorder()
        let monitor = ThermalMonitor(sampler: HardwareSampler(makeSource: { source }))
        monitor.followedGroups = [.battery]
        for _ in 0...ThermalMonitor.slowGroupInterval { await monitor.refresh() }
        let asked = source.asked
        XCTAssertEqual(asked.count, ThermalMonitor.slowGroupInterval + 1)
        XCTAssertEqual(asked.first?.count, 8)
        XCTAssertEqual(Array(asked[1..<ThermalMonitor.slowGroupInterval]), Array(repeating: [.cpu, .gpu, .battery], count: ThermalMonitor.slowGroupInterval - 1))
        XCTAssertEqual(asked.last?.count, 8)
        monitor.surfacesListingEverySensor += 1
        await monitor.refresh()
        XCTAssertEqual(source.asked.last, Set(SensorGroup.allCases), "A page that lists every sensor has every sensor read")
        monitor.surfacesListingEverySensor -= 1
        await monitor.refresh()
        XCTAssertEqual(source.asked.last, [.cpu, .gpu, .battery])
        XCTAssertEqual(monitor.history.count, source.asked.count)
    }

    func testThePartsThatPresetsAndRulesFollowAreFound() {
        let snapshot = Fixtures.snapshot()
        let battery = Preset(name: "Lap", icon: .airplane, fallback: .sensorBased(SensorRule(source: .group(.battery, .average), startCelsius: 33, maxCelsius: 43)))
        var mixed = Preset(name: "Mixed", icon: .sliders, fallback: .constant(rpm: 2000))
        mixed.setControl(.sensorBased(SensorRule(source: .key("Tg01"), startCelsius: 50, maxCelsius: 80)), for: Fixtures.fan(1))
        XCTAssertEqual(AppModel.followedGroups(presets: [.automatic, .adaptive, .fullBlast], rules: [], snapshot: snapshot), [])
        XCTAssertEqual(AppModel.followedGroups(presets: [battery, mixed], rules: [], snapshot: snapshot), [.battery, .gpu], "A single sensor counts as its part")
        let rule = AutomationRule(trigger: .temperatureAbove(source: .group(.storage, .hottest), celsius: 60), presetID: battery.id)
        let other = AutomationRule(trigger: .powerSource(.battery), presetID: battery.id)
        XCTAssertEqual(AppModel.followedGroups(presets: [], rules: [rule, other], snapshot: snapshot), [.storage])
        var unknown = mixed
        unknown.setControl(.sensorBased(SensorRule(source: .key("Tzzz"), startCelsius: 50, maxCelsius: 80)), for: Fixtures.fan(0))
        XCTAssertEqual(AppModel.followedGroups(presets: [unknown], rules: [], snapshot: snapshot), Set(SensorGroup.allCases), "A sensor the Mac does not report could be of any part")
    }

    func testReadingsMoveEverySecondWhileSomethingShowsThem() {
        XCTAssertEqual(ThermalMonitor.visibleInterval, .seconds(1))
        XCTAssertGreaterThan(ThermalMonitor.backgroundInterval, ThermalMonitor.visibleInterval)
    }
}

/// A reader that keeps the parts it was asked to read, sample by sample.
final class GroupRecorder: SnapshotSource, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Set<SensorGroup>] = []

    var asked: [Set<SensorGroup>] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func snapshot(at date: Date, groups: Set<SensorGroup>) -> ThermalSnapshot {
        lock.lock()
        recorded.append(groups)
        lock.unlock()
        return Fixtures.snapshot(date: date)
    }
}
