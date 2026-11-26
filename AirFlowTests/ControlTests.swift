import XCTest
@testable import AirFlow

final class FanPlannerTests: XCTestCase {
    private let rule = SensorRule(source: .cpuAverage, startCelsius: 50, maxCelsius: 90)

    func testASensorRuleRisesInAStraightLineBetweenItsTemperatures() {
        XCTAssertEqual(rule.fraction(at: 30), 0)
        XCTAssertEqual(rule.fraction(at: 50), 0)
        XCTAssertEqual(rule.fraction(at: 70), 0.5)
        XCTAssertEqual(rule.fraction(at: 90), 1)
        XCTAssertEqual(rule.fraction(at: 120), 1)
        XCTAssertEqual(rule.rpm(at: 70, fan: Fixtures.fan()), 3000)
    }

    func testARuleCannotBeACliffOrLeaveTheRange() {
        let cliff = SensorRule(source: .cpuAverage, startCelsius: 80, maxCelsius: 80)
        XCTAssertEqual(cliff.maxCelsius - cliff.startCelsius, SensorRule.minimumSpan)
        let inverted = SensorRule(source: .cpuAverage, startCelsius: 90, maxCelsius: 40)
        XCTAssertGreaterThan(inverted.maxCelsius, inverted.startCelsius)
        let wild = SensorRule(source: .cpuAverage, startCelsius: -500, maxCelsius: 9000)
        XCTAssertEqual(wild.startCelsius, SensorRule.temperatureRange.lowerBound)
        XCTAssertEqual(wild.maxCelsius, SensorRule.temperatureRange.upperBound)
        let high = SensorRule(source: .cpuAverage, startCelsius: 500, maxCelsius: 500)
        XCTAssertLessThanOrEqual(high.maxCelsius, SensorRule.temperatureRange.upperBound)
        XCTAssertEqual(high.maxCelsius - high.startCelsius, SensorRule.minimumSpan)
    }

    func testEachControlBecomesACommandWithinTheFansRange() {
        let fan = Fixtures.fan()
        let snapshot = Fixtures.snapshot(cpu: 70)
        XCTAssertEqual(FanPlanner.command(for: .automatic, fan: fan, snapshot: snapshot), .automatic)
        XCTAssertEqual(FanPlanner.command(for: .constant(rpm: 2500), fan: fan, snapshot: snapshot), .speed(2500))
        XCTAssertEqual(FanPlanner.command(for: .constant(rpm: 99_999), fan: fan, snapshot: snapshot), .speed(5000))
        XCTAssertEqual(FanPlanner.command(for: .constant(rpm: 1), fan: fan, snapshot: snapshot), .speed(1000))
        XCTAssertEqual(FanPlanner.command(for: .constantFraction(0.25), fan: fan, snapshot: snapshot), .speed(2000))
        XCTAssertEqual(FanPlanner.command(for: .constantFraction(7), fan: fan, snapshot: snapshot), .speed(5000))
        XCTAssertEqual(FanPlanner.command(for: .sensorBased(rule), fan: fan, snapshot: snapshot), .speed(3000))
    }

    func testARuleWhoseSensorIsMissingLeavesTheFanToTheSystem() {
        let memory = SensorRule(source: .group(.memory, .average), startCelsius: 40, maxCelsius: 60)
        XCTAssertEqual(FanPlanner.command(for: .sensorBased(memory), fan: Fixtures.fan(), snapshot: Fixtures.snapshot()), .automatic)
    }

    func testAFanWithNoRangeIsNeverCommanded() {
        var fan = Fixtures.fan()
        fan.maximumRPM = fan.minimumRPM
        XCTAssertEqual(FanPlanner.command(for: .constantFraction(1), fan: fan, snapshot: Fixtures.snapshot()), .automatic)
    }

    func testBuiltInPresets() {
        let snapshot = Fixtures.snapshot()
        XCTAssertEqual(FanPlanner.plan(preset: .automatic, snapshot: snapshot), [0: .automatic, 1: .automatic])
        XCTAssertEqual(FanPlanner.plan(preset: .fullBlast, snapshot: snapshot), [0: .speed(5000), 1: .speed(5000)])
    }

    func testAPresetCanTreatEachFanDifferently() {
        var preset = Preset(name: "Mixed", icon: .sliders, fallback: .constant(rpm: 2000))
        preset.setControl(.automatic, for: Fixtures.fan(1))
        XCTAssertEqual(FanPlanner.plan(preset: preset, snapshot: Fixtures.snapshot()), [0: .speed(2000), 1: .automatic])
    }

    func testABuiltInPresetCannotBeChanged() {
        var preset = Preset.fullBlast
        preset.setControl(.automatic, for: Fixtures.fan())
        XCTAssertEqual(preset, .fullBlast)
    }

    func testOnlyARealChangeIsWorthSending() {
        XCTAssertFalse(FanPlanner.differs(.speed(2010), from: .speed(2000)))
        XCTAssertTrue(FanPlanner.differs(.speed(2030), from: .speed(2000)))
        XCTAssertTrue(FanPlanner.differs(.speed(2000), from: .automatic))
        XCTAssertTrue(FanPlanner.differs(.automatic, from: .speed(2000)))
        XCTAssertFalse(FanPlanner.differs(.automatic, from: .automatic))
        XCTAssertTrue(FanPlanner.differs(.automatic, from: nil))
    }

    func testStarterPresetsFitAnyMac() {
        let starters = Preset.starters()
        XCTAssertEqual(starters.map(\.name), ["Quiet", "Heavy Workload", "Travel"])
        XCTAssertTrue(starters.allSatisfy { $0.controls.isEmpty && $0.kind == .custom })
        let quiet = FanPlanner.plan(preset: starters[0], snapshot: Fixtures.snapshot(cpu: 60))
        let heavy = FanPlanner.plan(preset: starters[1], snapshot: Fixtures.snapshot(cpu: 60))
        XCTAssertEqual(quiet[0], .speed(1000), "Quiet stays at the minimum at 60 degrees")
        XCTAssertEqual(heavy[0], .speed(3000), "Heavy Workload is halfway up at 60 degrees")
    }
}

final class SafeguardTests: XCTestCase {
    func testItEngagesAtTheLimitAndHoldsUntilWellBelowIt() {
        var safeguard = Safeguard()
        safeguard.update(snapshot: Fixtures.snapshot(cpu: 94), limit: 95, isEnabled: true)
        XCTAssertFalse(safeguard.isEngaged)
        safeguard.update(snapshot: Fixtures.snapshot(cpu: 96), limit: 95, isEnabled: true)
        XCTAssertTrue(safeguard.isEngaged)
        XCTAssertEqual(safeguard.trigger, .cpu)
        safeguard.update(snapshot: Fixtures.snapshot(cpu: 99), limit: 95, isEnabled: true)
        XCTAssertEqual(safeguard.peak, 99)
        safeguard.update(snapshot: Fixtures.snapshot(cpu: 90), limit: 95, isEnabled: true)
        XCTAssertTrue(safeguard.isEngaged, "Just under the limit is not cool enough to let go")
        safeguard.update(snapshot: Fixtures.snapshot(cpu: 86), limit: 95, isEnabled: true)
        XCTAssertFalse(safeguard.isEngaged)
    }

    func testTheGPUCountsToo() {
        var safeguard = Safeguard()
        safeguard.update(snapshot: Fixtures.snapshot(cpu: 60, gpu: 97), limit: 95, isEnabled: true)
        XCTAssertTrue(safeguard.isEngaged)
        XCTAssertEqual(safeguard.trigger, .gpu)
    }

    func testTurningItOffReleasesIt() {
        var safeguard = Safeguard()
        safeguard.update(snapshot: Fixtures.snapshot(cpu: 99), limit: 95, isEnabled: true)
        safeguard.update(snapshot: Fixtures.snapshot(cpu: 99), limit: 95, isEnabled: false)
        XCTAssertFalse(safeguard.isEngaged)
    }

    func testABatteryIsNotWhatItWatches() {
        var safeguard = Safeguard()
        safeguard.update(snapshot: Fixtures.snapshot(cpu: 60, battery: 99), limit: 95, isEnabled: true)
        XCTAssertFalse(safeguard.isEngaged)
    }
}

@MainActor
final class FanControllerTests: XCTestCase {
    private let recorder = CommandRecorder()
    private lazy var controller = FanController(commander: recorder)
    private let quiet = Preset(name: "Constant", icon: .sliders, fallback: .constant(rpm: 2000))

    private func tick(_ snapshot: ThermalSnapshot, _ preset: Preset, limit: Double = 95, now: Date = Date()) async {
        controller.tick(snapshot: snapshot, preset: preset, safeguardEnabled: true, safeguardLimit: limit, now: now)
        await Fixtures.settle()
    }

    func testNothingIsSentWithoutTheHelper() async {
        await tick(Fixtures.snapshot(), .fullBlast)
        XCTAssertEqual(controller.mode, .monitoring)
        XCTAssertTrue(recorder.calls.isEmpty)
        XCTAssertEqual(controller.plan[0], .speed(5000), "The plan is still worked out, to show what the preset would do")
    }

    func testAutomaticSendsNothingSoAnIdleAppNeverWakesTheHelper() async {
        controller.isControlAllowed = true
        await tick(Fixtures.snapshot(), .automatic)
        XCTAssertEqual(controller.mode, .controlling)
        XCTAssertTrue(recorder.calls.isEmpty)
        XCTAssertFalse(controller.holdsAnyFan)
    }

    func testASpeedIsSentOnceThenKeptAlive() async {
        controller.isControlAllowed = true
        await tick(Fixtures.snapshot(), quiet)
        XCTAssertEqual(recorder.calls, [.speed(0, 2000), .speed(1, 2000)])
        XCTAssertTrue(controller.holdsAnyFan)
        let held = [Fixtures.fan(0, manual: true), Fixtures.fan(1, manual: true)]
        await tick(Fixtures.snapshot(fans: held), quiet)
        XCTAssertEqual(recorder.calls, [.speed(0, 2000), .speed(1, 2000), .keepAlive])
    }

    func testAFanTheSystemTookBackIsSetAgain() async {
        controller.isControlAllowed = true
        await tick(Fixtures.snapshot(), quiet)
        await tick(Fixtures.snapshot(fans: [Fixtures.fan(0, manual: true), Fixtures.fan(1, manual: false)]), quiet)
        XCTAssertEqual(recorder.calls.last, .speed(1, 2000))
        XCTAssertEqual(recorder.calls.count, 3)
    }

    func testChangingToAutomaticGivesTheFansBack() async {
        controller.isControlAllowed = true
        await tick(Fixtures.snapshot(), quiet)
        let held = [Fixtures.fan(0, manual: true), Fixtures.fan(1, manual: true)]
        await tick(Fixtures.snapshot(fans: held), .automatic)
        XCTAssertEqual(Array(recorder.calls.suffix(2)), [.automatic(0), .automatic(1)])
        XCTAssertFalse(controller.holdsAnyFan)
    }

    func testTheSafeguardOverridesThePreset() async {
        controller.isControlAllowed = true
        await tick(Fixtures.snapshot(cpu: 60), .fullBlast)
        let held = [Fixtures.fan(0, manual: true), Fixtures.fan(1, manual: true)]
        await tick(Fixtures.snapshot(cpu: 97, fans: held), .fullBlast)
        XCTAssertEqual(controller.mode, .safeguard)
        XCTAssertEqual(Array(recorder.calls.suffix(2)), [.automatic(0), .automatic(1)])
        await tick(Fixtures.snapshot(cpu: 80), .fullBlast)
        XCTAssertEqual(controller.mode, .controlling)
        XCTAssertEqual(Array(recorder.calls.suffix(2)), [.speed(0, 5000), .speed(1, 5000)])
    }

    func testAFailureIsReportedAndNotRetriedAtOnce() async {
        controller.isControlAllowed = true
        recorder.failure = HelperError.refused("The system did not hand over fan 1.")
        let now = Date()
        await tick(Fixtures.snapshot(), quiet, now: now)
        XCTAssertEqual(controller.lastError, "The system did not hand over fan 1.")
        XCTAssertEqual(recorder.calls.count, 1, "The first failure stops the batch")
        await tick(Fixtures.snapshot(), quiet, now: now.addingTimeInterval(1))
        XCTAssertEqual(recorder.calls.count, 1)
        recorder.failure = nil
        await tick(Fixtures.snapshot(), quiet, now: Date().addingTimeInterval(FanController.retryDelay + 1))
        XCTAssertNil(controller.lastError)
        XCTAssertEqual(recorder.calls.count, 3)
    }

    func testAfterWakeEveryCommandGoesOutAgain() async {
        controller.isControlAllowed = true
        await tick(Fixtures.snapshot(), quiet)
        controller.forgetSentCommands()
        await tick(Fixtures.snapshot(), quiet)
        XCTAssertEqual(recorder.calls, [.speed(0, 2000), .speed(1, 2000), .speed(0, 2000), .speed(1, 2000)])
    }

    func testReleasingReturnsEveryFan() async {
        controller.isControlAllowed = true
        await tick(Fixtures.snapshot(), quiet)
        await controller.releaseAll()
        XCTAssertEqual(recorder.calls.last, .resetAll)
        XCTAssertFalse(controller.holdsAnyFan)
    }
}
