import CoreML
import CreateMLComponents
import XCTest
@testable import AirFlow

/// A made-up Mac for the adaptive controller: heat comes from power, and it leaves faster the
/// faster the fans turn. 60 watts would settle near 109° with no fan and near 63° with full fans.
private struct Plant {
    var celsius = 39.0
    var fraction = 0.0
    var time: TimeInterval = 0
    let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    mutating func advance(watts: Double, seconds: TimeInterval = 1) {
        let rate = 1.0 / 60
        celsius += (1.4 * rate * watts - (celsius - 25) * rate * (1 + 1.2 * fraction)) * seconds
        time += seconds
    }

    func snapshot(watts: Double?) -> ThermalSnapshot {
        let fans = (0..<2).map { index in
            Fan(
                index: index, name: Fan.name(index: index, count: 2), minimumRPM: 1000, maximumRPM: 5000,
                currentRPM: 1000 + 4000 * fraction, targetRPM: 1000 + 4000 * fraction, isManual: true
            )
        }
        return ThermalSnapshot(
            date: start.addingTimeInterval(time), fans: fans,
            sensors: [
                Sensor(key: "Tp01", name: "Performance Core Sensor 1", group: .cpu, celsius: celsius, isKnown: false),
                Sensor(key: "Tg01", name: "GPU Sensor 1", group: .gpu, celsius: celsius - 10, isKnown: false),
            ],
            systemWatts: watts
        )
    }
}

final class RollingWindowTests: XCTestCase {
    func testTheMeanCoversOnlyTheSpan() {
        var window = RollingWindow(span: 5)
        XCTAssertNil(window.mean)
        for second in 0..<10 {
            window.add(Double(second), at: Double(second))
        }
        // Seconds 4 through 9 are within 5 seconds of the last one.
        XCTAssertEqual(window.count, 6)
        XCTAssertEqual(window.mean ?? 0, 6.5, accuracy: 1e-9)
        XCTAssertEqual(window.oldest?.value, 4)
    }

    func testAValueThatIsNotANumberAndAClockThatWentBackAreHandled() {
        var window = RollingWindow(span: 5)
        window.add(10, at: 100)
        window.add(.nan, at: 101)
        XCTAssertEqual(window.count, 1)
        window.add(20, at: 50)
        XCTAssertEqual(window.count, 1, "A clock that went backward starts the window again")
        XCTAssertEqual(window.mean, 20)
    }

    func testTheSumStaysTrueOverManyValues() {
        var window = RollingWindow(span: 30)
        for second in 0..<5000 {
            window.add(0.1 + Double(second % 7), at: Double(second))
        }
        let expected = (4970..<5000).map { 0.1 + Double($0 % 7) }.reduce(0, +) / 30
        XCTAssertEqual(window.count, 31)
        XCTAssertEqual(window.mean ?? 0, (expected * 30 + 0.1 + Double(4969 % 7)) / 31, accuracy: 1e-6)
    }
}

final class PowerScaleTests: XCTestCase {
    func testLoadIsAShareOfTheMacsOwnRange() {
        let scale = PowerScale(idle: 10, peak: 60)
        XCTAssertEqual(scale.load(10), 0)
        XCTAssertEqual(scale.load(35), 0.5)
        XCTAssertEqual(scale.load(60), 1)
        XCTAssertEqual(scale.load(500), 1)
        XCTAssertEqual(scale.load(2), 0)
    }

    func testANarrowRangeIsWidenedSoNoiseIsNotALoad() {
        let scale = PowerScale(first: 10)
        XCTAssertEqual(scale.load(12), 2 / PowerScale.minimumSpan, accuracy: 1e-9)
    }

    func testRestFallsAtOnceAndThePeakRisesAtOnce() {
        var scale = PowerScale(first: 30)
        scale.observe(restingWatts: 12, burstWatts: 80)
        XCTAssertEqual(scale.idle, 12)
        XCTAssertEqual(scale.peak, 80)
        scale.observe(restingWatts: 40, burstWatts: 20)
        XCTAssertEqual(scale.idle, 12, accuracy: 0.05, "Rest follows a higher reading slowly")
        XCTAssertEqual(scale.peak, 80, accuracy: 0.05, "The peak follows a lower reading slowly")
    }

    func testStoredNumbersThatCannotBeAScaleAreRefused() {
        XCTAssertTrue(PowerScale(idle: 10, peak: 60).isValid)
        XCTAssertFalse(PowerScale(idle: 60, peak: 10).isValid)
        XCTAssertFalse(PowerScale(idle: .nan, peak: 10).isValid)
        XCTAssertFalse(PowerScale(idle: 0, peak: 10).isValid)
        XCTAssertNil(AdaptiveController(scale: PowerScale(idle: 60, peak: 10)).scale)
    }
}

final class RegimeDetectorTests: XCTestCase {
    func testTheTreeChoosesByHowLongTheLoadLastsAndByWhatIsOpen() {
        let classify = RegimeDetector.classify
        XCTAssertEqual(classify(0.1, 0.1, nil), .light)
        XCTAssertEqual(classify(0.6, 0.2, nil), .bursty, "A short spike")
        XCTAssertEqual(classify(0.6, 0.5, nil), .sustained, "The load has lasted")
        XCTAssertEqual(classify(0.2, 0.5, nil), .sustained)
        XCTAssertEqual(classify(0.4, 0.1, nil), .light, "Not enough load with no app known for it")
        XCTAssertEqual(classify(0.4, 0.1, .bursty), .bursty)
        XCTAssertEqual(classify(0.4, 0.1, .sustained), .sustained, "An app known for long loads starts the ramp sooner")
        XCTAssertEqual(classify(0.2, 0.1, .sustained), .light, "An app that is open and idle changes nothing")
    }

    func testAHigherRegimeTakesEffectAtOnceAndALowerOneAfterTheHold() {
        var detector = RegimeDetector()
        XCTAssertEqual(detector.update(load5: 0.9, load30: 0.9, hint: nil, at: 0), .sustained)
        XCTAssertEqual(detector.update(load5: 0, load30: 0, hint: nil, at: 1), .sustained)
        XCTAssertEqual(detector.update(load5: 0, load30: 0, hint: nil, at: 1 + RegimeDetector.hold - 1), .sustained)
        XCTAssertEqual(detector.update(load5: 0, load30: 0, hint: nil, at: 1 + RegimeDetector.hold), .light)
    }

    func testALoadThatComesBackStartsTheHoldAgain() {
        var detector = RegimeDetector()
        _ = detector.update(load5: 0.9, load30: 0.9, hint: nil, at: 0)
        _ = detector.update(load5: 0, load30: 0, hint: nil, at: 5)
        _ = detector.update(load5: 0.9, load30: 0.9, hint: nil, at: 15)
        XCTAssertEqual(detector.update(load5: 0, load30: 0, hint: nil, at: 30), .sustained)
        XCTAssertEqual(detector.update(load5: 0, load30: 0, hint: nil, at: 49), .sustained)
        XCTAssertEqual(detector.update(load5: 0, load30: 0, hint: nil, at: 50), .light)
    }
}

final class ThermalForecasterTests: XCTestCase {
    func testBeforeItHasLearnedItCarriesTheSlopeOn() {
        let forecaster = ThermalForecaster()
        XCTAssertFalse(forecaster.isWarm)
        let rising = ThermalForecaster.features(celsius: 60, slope: 0.4, load: 1, fanFraction: 0)
        XCTAssertEqual(forecaster.rise(features: rising), 0.4 * ThermalForecaster.horizon, accuracy: 1e-9)
        XCTAssertEqual(forecaster.fanEffect(celsius: 60), ThermalForecaster.defaultFanEffect)
    }

    func testAForecastIsNeverFartherThanIsPlausible() {
        let forecaster = ThermalForecaster()
        let steep = ThermalForecaster.features(celsius: 60, slope: 50, load: 1, fanFraction: 0)
        XCTAssertEqual(forecaster.rise(features: steep), ThermalForecaster.plausibleRise.upperBound)
        XCTAssertEqual(forecaster.rise(features: []), 0)
    }

    func testItLearnsThisMacBetterThanTheSlopeAlone() {
        var forecaster = ThermalForecaster()
        var plant = Plant()
        var recent = RollingWindow(span: 6)
        var asked: [(time: TimeInterval, celsius: Double, learned: Double, carried: Double)] = []
        var learnedError = 0.0, carriedError = 0.0, compared = 0
        for second in 0..<4000 {
            // Load and fan speed both change, so the forecaster sees what each does.
            let watts: Double = (second / 300) % 2 == 0 ? 12 : 60
            plant.fraction = (second / 170) % 3 == 0 ? 0 : ((second / 170) % 3 == 1 ? 0.5 : 1)
            plant.advance(watts: watts)
            recent.add(plant.celsius, at: plant.time)
            let slope = recent.oldest.map { plant.time - $0.time >= 1 ? (plant.celsius - $0.value) / (plant.time - $0.time) : 0 } ?? 0
            let features = ThermalForecaster.features(celsius: plant.celsius, slope: slope, load: watts > 30 ? 1 : 0, fanFraction: plant.fraction)
            forecaster.observe(features: features, celsius: plant.celsius, at: plant.time)
            if second >= 2000 {
                asked.append((plant.time, plant.celsius, forecaster.rise(features: features), slope * ThermalForecaster.horizon))
            }
            while let first = asked.first, plant.time - first.time >= ThermalForecaster.horizon {
                asked.removeFirst()
                let actual = plant.celsius - first.celsius
                learnedError += abs(actual - first.learned)
                carriedError += abs(actual - min(max(first.carried, -15), 25))
                compared += 1
            }
        }
        XCTAssertTrue(forecaster.isWarm)
        XCTAssertGreaterThan(compared, 1500)
        XCTAssertLessThan(learnedError / Double(compared), 1.5, "Within a degree and a half on average")
        XCTAssertLessThan(learnedError, carriedError * 0.9, "Better than continuing the slope")
        XCTAssertTrue(ThermalForecaster.fanEffectRange.contains(forecaster.fanEffect(celsius: 60)))
        XCTAssertGreaterThanOrEqual(forecaster.fanEffect(celsius: 90), forecaster.fanEffect(celsius: 45), "Air takes more heat from a hot Mac")
    }

    func testTheSlopeLeadsUntilTheLearnedForecastIsTheCloserOne() throws {
        var forecaster = ThermalForecaster()
        var plant = Plant()
        var recent = RollingWindow(span: 6)
        var asked: [(time: TimeInterval, celsius: Double, forecast: Double, carried: Double)] = []
        var forecastError = 0.0, carriedError = 0.0
        var shareWhenNew: Double?
        for second in 0..<3000 {
            let watts: Double = (second / 300) % 2 == 0 ? 12 : 60
            plant.fraction = (second / 170) % 3 == 0 ? 0 : ((second / 170) % 3 == 1 ? 0.5 : 1)
            plant.advance(watts: watts)
            recent.add(plant.celsius, at: plant.time)
            let slope = recent.oldest.map { plant.time - $0.time >= 1 ? (plant.celsius - $0.value) / (plant.time - $0.time) : 0 } ?? 0
            let features = ThermalForecaster.features(celsius: plant.celsius, slope: slope, load: watts > 30 ? 1 : 0, fanFraction: plant.fraction)
            forecaster.observe(features: features, celsius: plant.celsius, at: plant.time)
            if second == 50 { shareWhenNew = forecaster.learnedShare }
            // The first ten minutes, when the forecaster has only just met this Mac.
            if (100..<600).contains(second) {
                asked.append((plant.time, plant.celsius, forecaster.rise(features: features), min(max(slope * ThermalForecaster.horizon, -15), 25)))
            }
            while let first = asked.first, plant.time - first.time >= ThermalForecaster.horizon {
                asked.removeFirst()
                forecastError += abs(plant.celsius - first.celsius - first.forecast)
                carriedError += abs(plant.celsius - first.celsius - first.carried)
            }
        }
        XCTAssertEqual(shareWhenNew, 0, "Before it is warm, the forecast is the slope")
        XCTAssertLessThanOrEqual(forecastError, carriedError, "No worse than the slope while it is new")
        XCTAssertGreaterThan(forecaster.learnedShare, 0.5, "The learned forecast leads once it has settled")
    }

    func testAForecasterStoredBeforeItKeptScoresStillReads() throws {
        let weights = Array(repeating: "0.1", count: 6).joined(separator: ",")
        let covariance = Array(repeating: "1", count: 36).joined(separator: ",")
        let old = try JSONDecoder().decode(ThermalForecaster.self, from: Data(#"{"weights":[\#(weights)],"covariance":[\#(covariance)],"updates":500}"#.utf8))
        XCTAssertTrue(old.isValid)
        XCTAssertTrue(old.isWarm)
        XCTAssertEqual(old.learnedShare, 0, "It has no scores yet, so the slope leads")
    }

    func testWhatItLearnedSurvivesBeingStoredAndABrokenFileStartsItAgain() throws {
        var forecaster = ThermalForecaster()
        for second in 0..<200 {
            let features = ThermalForecaster.features(celsius: 50 + Double(second % 9), slope: 0.1, load: 0.5, fanFraction: 0.2)
            forecaster.observe(features: features, celsius: 50 + Double(second % 9), at: Double(second))
        }
        let stored = try JSONEncoder().encode(forecaster)
        let read = try JSONDecoder().decode(ThermalForecaster.self, from: stored)
        XCTAssertEqual(read.weights, forecaster.weights)
        XCTAssertEqual(read.updates, forecaster.updates)
        XCTAssertEqual(read.learnedShare, forecaster.learnedShare)
        XCTAssertTrue(read.isValid)

        let broken = try JSONDecoder().decode(ThermalForecaster.self, from: Data(#"{"weights":[1,2],"covariance":[1],"updates":5}"#.utf8))
        XCTAssertFalse(broken.isValid)
        XCTAssertEqual(AdaptiveController(forecaster: broken).forecaster.updates, 0)
    }

    func testAnAnswerThatCameFarTooLateTeachesNothing() {
        var forecaster = ThermalForecaster()
        let features = ThermalForecaster.features(celsius: 50, slope: 0, load: 0, fanFraction: 0)
        forecaster.observe(features: features, celsius: 50, at: 0)
        forecaster.observe(features: features, celsius: 90, at: 3600)
        XCTAssertEqual(forecaster.updates, 0, "The Mac slept in between")
        forecaster.observe(features: features, celsius: 91, at: 3600 + ThermalForecaster.horizon)
        XCTAssertEqual(forecaster.updates, 1)
    }
}

final class AdaptiveControllerTests: XCTestCase {
    /// Runs the controller against the plant. `watts` gives the power at each second.
    private func run(
        seconds: Int, hint: WorkloadRegime? = nil, controller: inout AdaptiveController, plant: inout Plant,
        watts: (Int) -> Double, each: (Int, AdaptiveState, Plant) -> Void = { _, _, _ in }
    ) {
        for second in 0..<seconds {
            let power = watts(second)
            plant.advance(watts: power)
            guard let state = controller.step(snapshot: plant.snapshot(watts: power), hint: hint) else {
                XCTFail("The controller had temperatures to steer by")
                return
            }
            plant.fraction = state.fraction
            each(second, state, plant)
        }
    }

    func testLightWorkLeavesTheFansAtTheirMinimum() {
        var controller = AdaptiveController()
        var plant = Plant()
        run(seconds: 300, controller: &controller, plant: &plant, watts: { 11 + Double($0 % 3) }) { _, state, _ in
            XCTAssertEqual(state.regime, .light)
            XCTAssertEqual(state.fraction, 0)
        }
    }

    func testAMacThatRestsWarmKeepsItsFansAtTheirMinimumInLightWork() {
        // This Mac draws 38 watts in light work and settles near 78 degrees with its fans at rest.
        var controller = AdaptiveController(scale: PowerScale(idle: 36, peak: 120))
        var plant = Plant()
        plant.celsius = 78
        run(seconds: 300, controller: &controller, plant: &plant, watts: { 37 + Double($0 % 3) }) { _, state, plant in
            XCTAssertEqual(state.regime, .light)
            XCTAssertEqual(state.fraction, 0)
            XCTAssertLessThan(plant.celsius, AdaptiveController.safetyFloor.lowerBound)
        }
    }

    func testTheFansComeAllTheWayBackToTheirMinimum() {
        var controller = AdaptiveController()
        var plant = Plant()
        plant.celsius = 88
        var highest = 0.0, last = 1.0
        run(seconds: 600, controller: &controller, plant: &plant, watts: { 11 + Double($0 % 3) }) { _, state, _ in
            highest = max(highest, state.fraction)
            last = state.fraction
        }
        XCTAssertGreaterThan(highest, 0.5, "The safety line raised the fans while the Mac was hot")
        XCTAssertEqual(last, 0, "Not a few RPM above the minimum")
    }

    func testALongLoadIsMetBeforeTheHeatAndHeldUnderTheCeiling() {
        var controller = AdaptiveController(scale: PowerScale(idle: 10, peak: 60))
        var plant = Plant()
        var sustainedAt: Int?, floorAt: Int?, hottest = 0.0, celsiusAtFloor = 0.0
        run(seconds: 900, controller: &controller, plant: &plant, watts: { $0 < 60 ? 10 : 60 }) { second, state, plant in
            if sustainedAt == nil, state.regime == .sustained { sustainedAt = second }
            if floorAt == nil, state.fraction >= AdaptivePolicy.sustained.floor {
                floorAt = second
                celsiusAtFloor = plant.celsius
            }
            hottest = max(hottest, plant.celsius)
        }
        XCTAssertLessThanOrEqual(try XCTUnwrap(sustainedAt), 60 + 31, "Within the 30 seconds it takes to call a load long")
        XCTAssertLessThan(celsiusAtFloor, 70, "The fans reached their floor while the Mac was still cool")
        XCTAssertLessThan(hottest, AdaptiveController.ceilingCelsius + 3, "With no fan this load settles near 109°")
        XCTAssertLessThan(plant.celsius, AdaptiveController.ceilingCelsius)
    }

    func testTheSpeedHoldsSteadyUnderASteadyLoad() {
        var controller = AdaptiveController(scale: PowerScale(idle: 10, peak: 60))
        var plant = Plant()
        var fractions: [Double] = []
        run(seconds: 900, controller: &controller, plant: &plant, watts: { _ in 60 }) { second, state, _ in
            if second >= 600 { fractions.append(state.fraction) }
        }
        let turns = zip(fractions, fractions.dropFirst()).map { $1 - $0 }.filter { $0 != 0 }
        let reversals = zip(turns, turns.dropFirst()).filter { ($0 > 0) != ($1 > 0) }.count
        XCTAssertLessThanOrEqual(reversals, 2, "The fans do not breathe")
        XCTAssertLessThan((fractions.max() ?? 0) - (fractions.min() ?? 0), 0.15)
    }

    func testTheSpeedNeverChangesFasterThanTheRegimeAllows() {
        var controller = AdaptiveController(scale: PowerScale(idle: 10, peak: 60))
        var plant = Plant()
        var last = 0.0
        run(seconds: 400, controller: &controller, plant: &plant, watts: { $0 < 30 || $0 > 250 ? 10 : 60 }) { _, state, plant in
            let most = AdaptivePolicy.sustained.riseRPM / 4000 + 1e-9
            if AdaptiveController.safetyFraction(celsius: plant.celsius) < state.fraction {
                XCTAssertLessThanOrEqual(state.fraction - last, most)
            }
            XCTAssertLessThanOrEqual(last - state.fraction, AdaptivePolicy.sustained.fallRPM / 4000 + 1e-9)
            last = state.fraction
        }
    }

    func testTheFansDoNotFallUntilALowerSpeedHasBeenWantedForAWhile() {
        var controller = AdaptiveController(scale: PowerScale(idle: 10, peak: 60))
        var plant = Plant()
        var atEnd = 0.0, firstFall: Int?
        run(seconds: 400, controller: &controller, plant: &plant, watts: { $0 < 200 ? 60 : 10 }) { second, state, _ in
            if second == 199 { atEnd = state.fraction }
            if second >= 200, firstFall == nil, state.fraction < atEnd - 1e-9 { firstFall = second }
        }
        XCTAssertGreaterThan(atEnd, 0.25)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(firstFall) - 200, Int(AdaptiveController.fallHold), "No fall between two prompts")
        XCTAssertLessThan(plant.fraction, atEnd, "The fans do come down once the load is over")
    }

    func testShortBurstsAreTakenUpByTheMacsOwnMass() {
        var controller = AdaptiveController(scale: PowerScale(idle: 10, peak: 60))
        var plant = Plant()
        var regimes: Set<WorkloadRegime> = []
        var most = 0.0
        // Six seconds of full load in every forty.
        run(seconds: 600, controller: &controller, plant: &plant, watts: { $0 % 40 < 6 ? 60 : 10 }) { _, state, _ in
            regimes.insert(state.regime)
            most = max(most, state.fraction)
        }
        XCTAssertTrue(regimes.contains(.bursty))
        XCTAssertFalse(regimes.contains(.sustained))
        XCTAssertLessThan(most, 0.1, "The fans stay near their minimum")
        XCTAssertLessThan(plant.celsius, 70)
    }

    func testAnAppKnownForLongLoadsStartsTheRampSooner() {
        func secondsUntilSustained(hint: WorkloadRegime?) -> Int {
            var controller = AdaptiveController(scale: PowerScale(idle: 10, peak: 60))
            var plant = Plant()
            var found = 999
            run(seconds: 120, hint: hint, controller: &controller, plant: &plant, watts: { $0 < 20 ? 10 : 60 }) { second, state, _ in
                if state.regime == .sustained { found = min(found, second - 20) }
            }
            return found
        }
        let hinted = secondsUntilSustained(hint: .sustained)
        let unhinted = secondsUntilSustained(hint: nil)
        XCTAssertLessThan(hinted, 6)
        XCTAssertGreaterThan(unhinted, hinted + 5)
    }

    func testTheSafetyLineHoldsWhateverWasLearnedAndIsNotSlowedDown() {
        XCTAssertEqual(AdaptiveController.safetyFraction(celsius: 79), 0)
        XCTAssertEqual(AdaptiveController.safetyFraction(celsius: 86), 0.5)
        XCTAssertEqual(AdaptiveController.safetyFraction(celsius: 92), 1)
        XCTAssertEqual(AdaptiveController.safetyFraction(celsius: 120), 1)

        var controller = AdaptiveController()
        var plant = Plant()
        plant.celsius = 93
        let state = controller.step(snapshot: plant.snapshot(watts: 10), hint: nil)
        XCTAssertEqual(state?.fraction, 1, "Full speed on the first reading, with no ramp")
        XCTAssertEqual(state?.regime, .light)
    }

    func testAMacThatReportsNoPowerIsSteeredByTemperatureAlone() {
        var controller = AdaptiveController()
        var plant = Plant()
        plant.celsius = 88
        let state = controller.step(snapshot: plant.snapshot(watts: nil), hint: .sustained)
        XCTAssertEqual(state?.regime, .light, "Without power there is no load to judge")
        XCTAssertNil(state?.watts)
        XCTAssertGreaterThanOrEqual(state?.fraction ?? 0, AdaptiveController.safetyFraction(celsius: 88))
        XCTAssertNil(controller.scale)
    }

    func testAMacWithNoCPUOrGPUTemperatureIsLeftToTheSystem() {
        var controller = AdaptiveController()
        let snapshot = ThermalSnapshot(
            date: Date(), fans: [Fixtures.fan(0)],
            sensors: [Sensor(key: "TB1T", name: "Battery Cell 1", group: .battery, celsius: 30)], systemWatts: 20
        )
        XCTAssertNil(controller.step(snapshot: snapshot, hint: nil))
        XCTAssertNil(controller.state)
        XCTAssertEqual(FanPlanner.plan(preset: .adaptive, snapshot: snapshot, adaptiveFraction: nil), [0: .automatic])
    }
}

final class AdaptivePlanTests: XCTestCase {
    func testTheShareOfTheRangeBecomesASpeedWithinEachFansLimits() {
        let snapshot = Fixtures.snapshot()
        XCTAssertEqual(FanPlanner.plan(preset: .adaptive, snapshot: snapshot, adaptiveFraction: 0.5), [0: .speed(3000), 1: .speed(3000)])
        XCTAssertEqual(FanPlanner.plan(preset: .adaptive, snapshot: snapshot, adaptiveFraction: 7), [0: .speed(5000), 1: .speed(5000)])
        XCTAssertEqual(FanPlanner.plan(preset: .adaptive, snapshot: snapshot, adaptiveFraction: -1), [0: .speed(1000), 1: .speed(1000)])
        XCTAssertEqual(FanPlanner.plan(preset: .adaptive, snapshot: snapshot, adaptiveFraction: .nan), [0: .automatic, 1: .automatic])
        XCTAssertEqual(FanPlanner.plan(preset: .adaptive, snapshot: snapshot), [0: .automatic, 1: .automatic])
    }

    func testAFanWithNoRangeAndAnyOtherPresetIgnoreTheShare() {
        var stuck = Fixtures.fan(0)
        stuck.maximumRPM = stuck.minimumRPM
        XCTAssertEqual(FanPlanner.adaptiveCommand(fan: stuck, fraction: 0.5), .automatic)
        XCTAssertEqual(
            FanPlanner.plan(preset: .automatic, snapshot: Fixtures.snapshot(), adaptiveFraction: 1), [0: .automatic, 1: .automatic]
        )
    }

    @MainActor
    func testAdaptiveIsBuiltInAndItsCopyIsAnOrdinaryPreset() throws {
        XCTAssertEqual(Preset.builtIn.map(\.kind), [.automatic, .adaptive, .fullBlast])
        XCTAssertTrue(Preset.adaptive.isBuiltIn)
        XCTAssertFalse(PresetIcon.choices.contains(.sparkles))
        let store = PresetStore(url: nil)
        let copy = try XCTUnwrap(store.duplicate(id: Preset.adaptiveID))
        XCTAssertEqual(copy.kind, .custom)
        XCTAssertEqual(copy.name, "Adaptive Copy")
        guard case .sensorBased = copy.fallback else { return XCTFail("The copy starts as a curve") }
        XCTAssertNoThrow(try PresetCodec.encode([copy]))
    }

    func testTheSentenceSaysWhoHasTheFan() {
        XCTAssertEqual(FanSentence.adaptiveText(command: .speed(2150), isActive: true, mode: .controlling), "Adaptive holds it at 2,150 RPM.")
        XCTAssertEqual(
            FanSentence.adaptiveText(command: .speed(2150), isActive: true, mode: .monitoring),
            "Adaptive would set it to 2,150 RPM. macOS controls the fan now."
        )
        XCTAssertEqual(
            FanSentence.adaptiveText(command: .speed(2150), isActive: true, mode: .safeguard),
            "Adaptive would set it to 2,150 RPM. The safeguard is on, so macOS controls the fan now."
        )
        XCTAssertEqual(FanSentence.adaptiveText(command: .speed(2150), isActive: false, mode: .controlling), "Adaptive would set it to 2,150 RPM.")
        XCTAssertTrue(FanSentence.adaptiveText(command: .automatic, isActive: true, mode: .controlling).hasSuffix("so macOS controls the fan."))
    }
}

@MainActor
final class AdaptiveLoopTests: XCTestCase {
    func testTheControlLoopSendsTheAdaptiveSpeedAndTheSafeguardStillOverridesIt() async {
        let recorder = CommandRecorder()
        let controller = FanController(commander: recorder)
        controller.isControlAllowed = true
        controller.tick(snapshot: Fixtures.snapshot(cpu: 60), preset: .adaptive, safeguardEnabled: true, safeguardLimit: 95, adaptiveFraction: 0.25)
        await Fixtures.settle()
        XCTAssertEqual(recorder.calls, [.speed(0, 2000), .speed(1, 2000)])

        let held = [Fixtures.fan(0, manual: true), Fixtures.fan(1, manual: true)]
        controller.tick(snapshot: Fixtures.snapshot(cpu: 97, fans: held), preset: .adaptive, safeguardEnabled: true, safeguardLimit: 95, adaptiveFraction: 1)
        await Fixtures.settle()
        XCTAssertEqual(controller.mode, .safeguard)
        XCTAssertEqual(recorder.calls.last, .resetAll)
    }

    func testWithNoHelperNothingIsSent() async {
        let recorder = CommandRecorder()
        let controller = FanController(commander: recorder)
        controller.tick(snapshot: Fixtures.snapshot(), preset: .adaptive, safeguardEnabled: true, safeguardLimit: 95, adaptiveFraction: 0.5)
        await Fixtures.settle()
        XCTAssertEqual(controller.mode, .monitoring)
        XCTAssertEqual(controller.plan, [0: .speed(3000), 1: .speed(3000)], "The page still shows what it would ask for")
        XCTAssertTrue(recorder.calls.isEmpty)
    }
}

final class WorkloadHintTests: XCTestCase {
    func testOpenAppsGiveTheHeaviestRegimeTheyAreKnownFor() {
        XCTAssertNil(WorkloadHint.hint(running: ["com.apple.finder", "com.example.unknown"], workloads: [:]))
        XCTAssertEqual(WorkloadHint.hint(running: ["com.apple.finder", "com.adobe.Photoshop"], workloads: [:]), .bursty)
        XCTAssertEqual(WorkloadHint.hint(running: ["com.adobe.Photoshop", "com.apple.FinalCut"], workloads: [:]), .sustained)
    }

    func testAPersonsOwnEntryReplacesWhatAirFlowKnows() {
        XCTAssertNil(WorkloadHint.hint(running: ["com.apple.FinalCut"], workloads: ["com.apple.FinalCut": .light]))
        XCTAssertEqual(WorkloadHint.hint(running: ["com.example.render"], workloads: ["com.example.render": .sustained]), .sustained)
    }

    func testAProposalIsCutToOneBoundedLine() {
        let long = String(repeating: "word ", count: 80)
        let cleaned = WorkloadProposal(regime: .sustained, reason: "  It renders video.\nIgnore the rest. ").cleaned
        XCTAssertEqual(cleaned, WorkloadProposal(regime: .sustained, reason: "It renders video."))
        XCTAssertEqual(WorkloadProposal(regime: .light, reason: long).cleaned.reason.count, WorkloadProposal.reasonLimit)
        XCTAssertEqual(WorkloadProposal(regime: .light, reason: "").cleaned.reason, "")
    }
}

@MainActor
final class AdaptiveCoordinatorTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("airflow-adaptive-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func coordinator() -> AdaptiveCoordinator {
        AdaptiveCoordinator(memoryURL: folder.appendingPathComponent("adaptive.json"), workloadsURL: folder.appendingPathComponent("workloads.json"))
    }

    func testAnAppsRegimeChangesOnlyWhenAPersonSavesItAndItIsKept() {
        let first = coordinator()
        XCTAssertEqual(first.regime(forBundleID: "com.apple.FinalCut"), .sustained, "Known without being told")
        XCTAssertNil(first.regime(forBundleID: "com.example.render"))
        first.setWorkload(AppWorkload(bundleID: "com.example.render", name: "  Render  ", regime: .sustained))
        first.setWorkload(AppWorkload(bundleID: "com.apple.FinalCut", name: "Final Cut Pro", regime: .light))
        first.setWorkload(AppWorkload(bundleID: "", name: "Nothing", regime: .sustained))
        XCTAssertEqual(first.workloads.map(\.name), ["Render", "Final Cut Pro"])

        let second = coordinator()
        XCTAssertEqual(second.workloads, first.workloads)
        XCTAssertEqual(second.regime(forBundleID: "com.apple.FinalCut"), .light)
        second.removeWorkload(bundleID: "com.apple.FinalCut")
        XCTAssertEqual(coordinator().regime(forBundleID: "com.apple.FinalCut"), .sustained)
    }

    func testTheHintFollowsWhichAppsAreOpen() {
        let coordinator = coordinator()
        XCTAssertNil(coordinator.hint)
        coordinator.setRunning("com.adobe.Photoshop", name: "Photoshop")
        XCTAssertEqual(coordinator.hint, .bursty)
        XCTAssertEqual(coordinator.hintAppName, "Photoshop")
        coordinator.setRunning("com.example.render", name: "Render")
        coordinator.setWorkload(AppWorkload(bundleID: "com.example.render", name: "Render", regime: .sustained))
        XCTAssertEqual(coordinator.hint, .sustained)
        XCTAssertEqual(coordinator.hintAppName, "Render")
        coordinator.setRunning("com.example.render", name: nil)
        coordinator.setRunning("com.adobe.Photoshop", name: nil)
        XCTAssertNil(coordinator.hint)
        XCTAssertNil(coordinator.hintAppName)
    }

    func testWhatItLearnedIsKeptBetweenLaunchesAndHoldsNoReading() throws {
        let first = coordinator()
        var plant = Plant()
        for second in 0..<200 {
            plant.advance(watts: second < 100 ? 10 : 60)
            first.ingest(plant.snapshot(watts: second < 100 ? 10 : 60), now: plant.start)
        }
        XCTAssertNotNil(first.state)
        first.save()
        let stored = try String(contentsOf: folder.appendingPathComponent("adaptive.json"), encoding: .utf8)
        XCTAssertFalse(stored.contains("celsius"), "Coefficients only")
        XCTAssertFalse(stored.contains("pending"))
        let memory = try JSONDecoder().decode(AdaptiveMemory.self, from: Data(stored.utf8))
        XCTAssertGreaterThan(memory.forecaster.updates, 100)
        XCTAssertEqual(memory.scale?.peak ?? 0, 60, accuracy: 1)
    }
}

/// Compares the forecaster with Apple's linear regressor on the same made-up Mac. It prints the
/// numbers and asserts nothing. Skipped unless AIRFLOW_COMPARE is set:
///
///     TEST_RUNNER_AIRFLOW_COMPARE=1 scripts/test.sh
final class ForecasterComparisonTests: XCTestCase {
    /// Apple's regressor, fitted again on the pairs of the last few minutes. Its `update` does not
    /// move a model after the first fit, so a window that is fitted again is how it follows a Mac.
    private struct AppleForecaster {
        var window: Int
        var refitEvery: Int
        var configuration = LinearRegressor<Double>.Configuration()
        var pairs: [AnnotatedFeature<MLShapedArray<Double>, Double>] = []
        var coefficients: [Double] = []
        var sinceFit = 0
        var fits = 0
        var fitSeconds = 0.0

        mutating func learn(features: [Double], target: Double) async {
            // The regressor adds its own constant, so the forecaster's leading 1 is left out.
            pairs.append(AnnotatedFeature(feature: MLShapedArray(scalars: Array(features.dropFirst()), shape: [features.count - 1]), annotation: target))
            if pairs.count > window { pairs.removeFirst(pairs.count - window) }
            sinceFit += 1
            guard pairs.count >= ThermalForecaster.warmUp, sinceFit >= refitEvery else { return }
            sinceFit = 0
            let start = Date()
            if let model = try? await LinearRegressor<Double>(configuration: configuration).fitted(to: pairs) {
                coefficients = model.coefficients
            }
            fits += 1
            fitSeconds += Date().timeIntervalSince(start)
        }

        func rise(features: [Double]) -> Double? {
            guard coefficients.count == features.count else { return nil }
            let inputs = features.dropFirst()
            return zip(coefficients, inputs).reduce(coefficients[coefficients.count - 1]) { $0 + $1.0 * $1.1 }
        }
    }

    func testAppleRegressorAgainstTheForecaster() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["AIRFLOW_COMPARE"] == nil)
        struct Asked { let time: TimeInterval, celsius: Double, features: [Double], ours: Double, apple: [Double?], carried: Double }
        let variants: [(String, AppleForecaster)] = [
            ("Apple, 10 min window, fit every 30 s", AppleForecaster(window: 600, refitEvery: 30)),
            ("Apple, 3 min window, fit every 10 s", AppleForecaster(window: 180, refitEvery: 10)),
            ("Apple, 30 min window, fit every 30 s", AppleForecaster(window: 1800, refitEvery: 30)),
        ]
        // The second Mac's fans start to move three times the air halfway through, as after a
        // vent is cleared, so each learner has to follow a change.
        for scenario in ["steady Mac", "Mac that changes at 3000 s"] {
            var ours = ThermalForecaster()
            var apples = variants.map(\.1)
            var plant = Plant()
            var recent = RollingWindow(span: 6)
            var asked: [Asked] = []
            // Errors by span of the run: early (100 to 600 s), settled (2000 to 3000 s), after the change (3000 to 3300 s), late (5000 to 6000 s).
            let spans: [(String, Range<Int>)] = [("early 100-600", 100..<600), ("settled 2000-3000", 2000..<3000), ("after change 3000-3300", 3000..<3300), ("late 5000-6000", 5000..<6000)]
            var oursError = Array(repeating: 0.0, count: spans.count), carriedError = oursError, counts = Array(repeating: 0, count: spans.count)
            var appleError = Array(repeating: oursError, count: variants.count)
            for second in 0..<6000 {
                let watts: Double = (second / 300) % 2 == 0 ? 12 : 60
                plant.fraction = (second / 170) % 3 == 0 ? 0 : ((second / 170) % 3 == 1 ? 0.5 : 1)
                let boost = scenario != "steady Mac" && second >= 3000 ? 3.0 : 1.0
                // The plant's own step, with the fans' share of the cooling scaled.
                let rate = 1.0 / 60
                plant.celsius += 1.4 * rate * watts - (plant.celsius - 25) * rate * (1 + 1.2 * boost * plant.fraction)
                plant.time += 1
                recent.add(plant.celsius, at: plant.time)
                let slope = recent.oldest.map { plant.time - $0.time >= 1 ? (plant.celsius - $0.value) / (plant.time - $0.time) : 0 } ?? 0
                let features = ThermalForecaster.features(celsius: plant.celsius, slope: slope, load: watts > 30 ? 1 : 0, fanFraction: plant.fraction)
                ours.observe(features: features, celsius: plant.celsius, at: plant.time)
                asked.append(Asked(
                    time: plant.time, celsius: plant.celsius, features: features, ours: ours.rise(features: features),
                    apple: apples.map { $0.rise(features: features) }, carried: min(max(slope * ThermalForecaster.horizon, -15), 25)
                ))
                while let first = asked.first, plant.time - first.time >= ThermalForecaster.horizon {
                    asked.removeFirst()
                    let actual = plant.celsius - first.celsius
                    for index in apples.indices { await apples[index].learn(features: first.features, target: actual) }
                    let at = Int(first.time)
                    for (index, span) in spans.enumerated() where span.1.contains(at) {
                        counts[index] += 1
                        oursError[index] += abs(actual - first.ours)
                        carriedError[index] += abs(actual - first.carried)
                        for (variant, forecast) in first.apple.enumerated() {
                            // Before its first fit, Apple's forecaster carries the slope on, as ours does.
                            appleError[variant][index] += abs(actual - (forecast.map { min(max($0, -15), 25) } ?? first.carried))
                        }
                    }
                }
            }
            func row(_ name: String, _ errors: [Double]) -> String {
                name.padding(toLength: 40, withPad: " ", startingAt: 0) + zip(errors, counts).map { String(format: "%6.2f", $0 / Double(max($1, 1))) }.joined(separator: "  ")
            }
            print("COMPARE == \(scenario): mean error in degrees for \(spans.map(\.0).joined(separator: " | "))")
            print("COMPARE " + row("slope carried on", carriedError))
            print("COMPARE " + row("AirFlow's forecast", oursError))
            for (index, variant) in variants.enumerated() {
                print("COMPARE " + row(variant.0, appleError[index]) + String(format: "   %d fits, %.2f ms each", apples[index].fits, apples[index].fitSeconds / Double(max(apples[index].fits, 1)) * 1000))
            }
        }
    }
}
