import Lottie
import XCTest
@testable import AirFlow

final class ProposalTests: XCTestCase {
    private func proposal(
        mode: PresetProposal.Mode = .sensorBased, speed: Int = 50, sensor: SensorGroup = .cpu, start: Int = 70, full: Int = 95,
        name: String = "Video Calls"
    ) -> PresetProposal {
        PresetProposal(
            name: name, mode: mode, speedPercent: speed, sensor: sensor, startCelsius: start,
            fullSpeedCelsius: full, summary: " Stays quiet until the CPU is hot. "
        )
    }

    func testASensorDraftBecomesARuleEveryFanFollows() {
        let preset = proposal().makePreset()
        XCTAssertEqual(preset.name, "Video Calls")
        XCTAssertEqual(preset.kind, .custom)
        XCTAssertTrue(preset.controls.isEmpty)
        XCTAssertEqual(preset.fallback, .sensorBased(SensorRule(source: .cpuAverage, startCelsius: 70, maxCelsius: 95)))
        XCTAssertEqual(preset.summary, "Stays quiet until the CPU is hot.")
    }

    func testNumbersTheModelGetsWrongAreClampedLikeAnyOtherPreset() {
        guard case .sensorBased(let rule) = proposal(start: 400, full: -3).control else { return XCTFail("not sensor based") }
        XCTAssertTrue(SensorRule.temperatureRange.contains(rule.startCelsius))
        XCTAssertTrue(SensorRule.temperatureRange.contains(rule.maxCelsius))
        XCTAssertGreaterThanOrEqual(rule.maxCelsius - rule.startCelsius, SensorRule.minimumSpan)

        XCTAssertEqual(proposal(mode: .constant, speed: 900).control, .constantFraction(1))
        XCTAssertEqual(proposal(mode: .constant, speed: -20).control, .constantFraction(0))
        let plan = FanPlanner.plan(preset: proposal(mode: .constant, speed: 900).makePreset(), snapshot: Fixtures.snapshot())
        XCTAssertEqual(plan[0], .speed(5000), "No draft can ask a fan for more than its maximum")
    }

    func testADraftWithNoUsableNameStillBecomesAPreset() {
        XCTAssertEqual(proposal(name: "  \n").makePreset().name, "New Preset")
        XCTAssertEqual(proposal(name: String(repeating: "x", count: 90)).makePreset().name.count, 40)
        XCTAssertEqual(proposal(mode: .automatic).makePreset().fallback, .automatic)
    }

    private let presets = [Preset.automatic, Preset(name: "Quiet", icon: .coffee), Preset(name: "Heavy Workload", icon: .rocket)]
    private let apps = [AppDirectory.App(bundleID: "com.apple.dt.Xcode", name: "Xcode")]

    private func rule(_ trigger: RuleProposal.Trigger, app: String = "", celsius: Int = 85, start: Int = 22, end: Int = 7, preset: String = "Quiet") -> RuleProposal {
        RuleProposal(trigger: trigger, appName: app, sensor: .cpu, celsius: celsius, startHour: start, endHour: end, presetName: preset)
    }

    func testRuleDraftsBecomeRules() throws {
        XCTAssertEqual(
            try rule(.app, app: "xcode", preset: "heavy workload").makeRule(presets: presets, apps: apps).trigger,
            .appIsFrontmost(bundleID: "com.apple.dt.Xcode", name: "Xcode")
        )
        XCTAssertEqual(try rule(.battery).makeRule(presets: presets, apps: apps).trigger, .powerSource(.battery))
        XCTAssertEqual(try rule(.adapter).makeRule(presets: presets, apps: apps).trigger, .powerSource(.adapter))
        XCTAssertEqual(
            try rule(.temperature, celsius: 900).makeRule(presets: presets, apps: apps).trigger,
            .temperatureAbove(source: .cpuAverage, celsius: SensorRule.temperatureRange.upperBound)
        )
        XCTAssertEqual(try rule(.time).makeRule(presets: presets, apps: apps).trigger, .timeRange(startMinute: 22 * 60, endMinute: 7 * 60))
        XCTAssertEqual(try rule(.battery, preset: "Heavy").makeRule(presets: presets, apps: apps).presetID, presets[2].id)
    }

    func testARuleDraftThatNamesSomethingThatDoesNotExistIsRefused() {
        XCTAssertThrowsError(try rule(.battery, preset: "Turbo").makeRule(presets: presets, apps: apps)) {
            XCTAssertEqual($0 as? RuleProposal.Failure, .unknownPreset("Turbo"))
        }
        XCTAssertThrowsError(try rule(.battery, preset: "").makeRule(presets: presets, apps: apps))
        XCTAssertThrowsError(try rule(.app, app: "Photoshop").makeRule(presets: presets, apps: apps)) {
            XCTAssertEqual($0 as? RuleProposal.Failure, .unknownApp("Photoshop"))
        }
        XCTAssertThrowsError(try rule(.time, start: 9, end: 9).makeRule(presets: presets, apps: apps)) {
            XCTAssertEqual($0 as? RuleProposal.Failure, .emptyTimeRange)
        }
    }

    func testTheDigestSummarizesTheHistoryTheModelIsShown() throws {
        let start = Date(timeIntervalSince1970: 0)
        let history = (0..<60).map { index in
            HistoryPoint(date: start.addingTimeInterval(Double(index) * 10), cpu: 50 + Double(index % 3) * 10, gpu: 40, fanFractions: [0.2, Double(index) / 100])
        }
        let digest = try XCTUnwrap(ThermalDigest(history: history, presetName: "Quiet"))
        XCTAssertEqual(digest.minutes, 10)
        XCTAssertEqual(digest.cpuLow, 50)
        XCTAssertEqual(digest.cpuHigh, 70)
        XCTAssertEqual(digest.cpuAverage, 60)
        XCTAssertEqual(digest.fanHigh, 0.59)
        let prompt = digest.prompt(format: ReadingFormat())
        XCTAssertTrue(prompt.contains("60 °C"))
        XCTAssertTrue(prompt.contains("\"Quiet\""))
        XCTAssertNil(ThermalDigest(history: Array(history.prefix(3)), presetName: "Quiet"), "Too little history says nothing")
    }
}

final class FormatTests: XCTestCase {
    func testTemperatures() {
        let celsius = ReadingFormat()
        XCTAssertEqual(celsius.temperature(61.6), "62°")
        XCTAssertEqual(celsius.temperatureWithUnit(61.6), "62 °C")
        XCTAssertEqual(celsius.temperature(nil), "--")
        XCTAssertEqual(ReadingFormat(unit: .celsius, isPrecise: true).temperature(61.64), "61.6°")
        let fahrenheit = ReadingFormat(unit: .fahrenheit)
        XCTAssertEqual(fahrenheit.temperature(100), "212°")
        XCTAssertEqual(fahrenheit.spokenTemperature(0), "32 degrees Fahrenheit")
        XCTAssertEqual(TemperatureUnit.fahrenheit.celsius(from: 212), 100, accuracy: 0.0001)
    }

    func testTheSameTemperatureIsJudgedByThePartItBelongsTo() {
        XCTAssertEqual(TemperatureBand.band(for: 45, in: .cpu), .cool)
        XCTAssertEqual(TemperatureBand.band(for: 45, in: .battery), .critical)
        XCTAssertEqual(TemperatureBand.band(for: 72, in: .cpu), .warm)
        XCTAssertEqual(TemperatureBand.band(for: 96, in: .gpu), .critical)
        XCTAssertEqual(TemperatureBand.band(for: 20, in: .storage), .cool)
        for group in SensorGroup.allCases {
            XCTAssertEqual(TemperatureBand.thresholds(for: group), TemperatureBand.thresholds(for: group).sorted())
            XCTAssertEqual(TemperatureBand.thresholds(for: group).count, TemperatureBand.allCases.count - 1)
        }
    }

    func testTheMenuBarReadout() {
        let snapshot = Fixtures.snapshot(cpu: 61, gpu: 48, fans: [Fixtures.fan(0, current: 2412), Fixtures.fan(1, current: 1800)])
        let format = ReadingFormat()
        XCTAssertNil(MenuBarLabel.text(readout: .none, snapshot: snapshot, format: format))
        XCTAssertEqual(MenuBarLabel.text(readout: .fastestFan, snapshot: snapshot, format: format), "2,412")
        XCTAssertEqual(MenuBarLabel.text(readout: .cpu, snapshot: snapshot, format: format), "61°")
        XCTAssertEqual(MenuBarLabel.text(readout: .gpu, snapshot: snapshot, format: format), "48°")
        XCTAssertEqual(MenuBarLabel.text(readout: .fanAndCPU, snapshot: snapshot, format: format), "2,412  61°")
        XCTAssertNil(MenuBarLabel.text(readout: .fanAndCPU, snapshot: .empty, format: format))
    }

    func testTheSentenceSiriSpeaks() {
        let snapshot = Fixtures.snapshot(cpu: 61, fans: [Fixtures.fan(0, current: 2412), Fixtures.fan(1, current: 1800)])
        XCTAssertEqual(
            FanStatus.sentence(snapshot: snapshot, presetName: "Quiet", format: ReadingFormat()),
            "Left Fan is at 2,412 RPM and Right Fan is at 1,800 RPM. The CPU is at 61 degrees Celsius. The preset is Quiet."
        )
        XCTAssertEqual(
            FanStatus.sentence(snapshot: .empty, presetName: "Quiet", format: ReadingFormat()),
            "This Mac has no fans that AirFlow can read."
        )
    }

    @MainActor
    func testSettingsRememberWhatWasChosenAndRefuseALimitOutOfRange() {
        let suite = "airflow-settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        let first = AppSettings(defaults: defaults)
        XCTAssertTrue(first.safeguardEnabled)
        XCTAssertEqual(first.safeguardLimit, Safeguard.defaultLimit)
        XCTAssertFalse(first.autopilotEnabled, "Autopilot is off until a person turns it on")
        XCTAssertFalse(first.setupShown, "A new copy asks for its permissions first")
        first.setupShown = true
        first.temperatureUnit = .fahrenheit
        first.menuBarReadout = .cpu
        first.safeguardEnabled = false
        defaults.set(500.0, forKey: AppSettings.Key.safeguardLimit)
        let second = AppSettings(defaults: defaults)
        XCTAssertEqual(second.temperatureUnit, .fahrenheit)
        XCTAssertTrue(second.setupShown)
        XCTAssertEqual(second.menuBarReadout, .cpu)
        XCTAssertFalse(second.safeguardEnabled)
        XCTAssertEqual(second.safeguardLimit, Safeguard.limitRange.upperBound)
    }
}

final class AnimationTests: XCTestCase {
    func testEveryAnimationLoadsWithItsStillFrame() throws {
        for name in Animations.all {
            let animation = try XCTUnwrap(AnimationLibrary.animation(named: name), "\(name).json is not in the app")
            XCTAssertEqual(animation.framerate, 60, name)
            XCTAssertNotNil(animation.frameTime(forMarker: Animations.stillMarker), "\(name) has no still frame")
            XCTAssertGreaterThan(animation.endFrame, animation.startFrame, name)
        }
    }

    func testTheRotorTurnsOnceASecond() throws {
        let rotor = try XCTUnwrap(AnimationLibrary.animation(named: Animations.rotor))
        XCTAssertEqual(rotor.duration, 1, accuracy: 0.001)
        XCTAssertEqual(rotor.size, CGSize(width: 120, height: 120))
    }

    func testNothingMovesWithReduceMotionOrOffScreen() {
        XCTAssertEqual(AirAnimation.playback(loops: true, isActive: true, speed: 1, reduceMotion: true), .still)
        XCTAssertEqual(AirAnimation.playback(loops: false, isActive: true, speed: 1, reduceMotion: true), .still)
        XCTAssertEqual(AirAnimation.playback(loops: true, isActive: false, speed: 1, reduceMotion: false), .idle)
        XCTAssertEqual(AirAnimation.playback(loops: false, isActive: true, speed: 1, reduceMotion: false), .once)
        XCTAssertEqual(AirAnimation.playback(loops: true, isActive: true, speed: 1.234, reduceMotion: false), .loop(speed: 1.25))
        XCTAssertEqual(AirAnimation.playback(loops: true, isActive: true, speed: -3, reduceMotion: false), .loop(speed: 0))
    }

    func testTheRotorFollowsTheFan() {
        XCTAssertEqual(Rotor.turnsPerSecond(for: nil), 0)
        XCTAssertEqual(Rotor.turnsPerSecond(for: Fixtures.fan(current: 0)), 0, "A stopped fan does not turn")
        XCTAssertEqual(Rotor.turnsPerSecond(for: Fixtures.fan(current: 1000)), Rotor.slowest)
        XCTAssertEqual(Rotor.turnsPerSecond(for: Fixtures.fan(current: 5000)), Rotor.fastest)
        XCTAssertLessThan(Rotor.turnsPerSecond(for: Fixtures.fan(current: 2000)), Rotor.turnsPerSecond(for: Fixtures.fan(current: 4000)))
    }

    @MainActor
    func testASurfaceHoldsItsStillFrameUntilItPlays() throws {
        let surface = AnimationSurface(name: Animations.done)
        XCTAssertEqual(surface.playback, .idle)
        surface.setPlayback(.still)
        XCTAssertEqual(surface.playback, .still)
        surface.setPlayback(.loop(speed: 2))
        XCTAssertEqual(surface.layer?.speed, 2)
        surface.setPlayback(.idle)
        XCTAssertEqual(surface.layer?.speed, 0, "An animation that is off screen does not run")
    }

    func testEveryIconAPresetCanCarryIsInTheCatalog() {
        for icon in PresetIcon.allCases {
            XCTAssertNotNil(NSImage(named: icon.assetName), "\(icon.assetName) is missing from the asset catalog")
        }
        for kind in AutomationTrigger.Kind.allCases {
            XCTAssertNotNil(NSImage(named: kind.iconName), "\(kind.iconName) is missing from the asset catalog")
        }
        XCTAssertNotNil(NSImage(named: "MenuBarIcon"))
    }
}

final class ReadingFontTests: XCTestCase {
    func testTheAppCarriesBothWeightsOfTheReadingFace() throws {
        for name in ["IBMPlexMono-Regular", "IBMPlexMono-Medium"] {
            let font = try XCTUnwrap(NSFont(name: name, size: 13), "\(name) is not registered")
            XCTAssertEqual(font.familyName, AirType.readingFamily)
            XCTAssertTrue(font.isFixedPitch)
        }
    }

    func testTheAppCarriesTheTextFace() throws {
        let font = try XCTUnwrap(NSFont(name: "HedvigLettersSans-Regular", size: 13), "Hedvig Letters Sans is not registered")
        XCTAssertEqual(font.familyName, AirType.textFamily)
        XCTAssertFalse(font.isFixedPitch)
        XCTAssertEqual(AirType.body.font, .custom(AirType.textFamily, fixedSize: 13))
        XCTAssertEqual(AirType.display.font, .custom(AirType.textFamily, fixedSize: 24))
    }

    func testAReadingRoleKeepsItsSizeAndUsesAWeightTheAppCarries() {
        XCTAssertEqual(AirType.statistic.size, 24)
        XCTAssertEqual(AirType.statistic.font, AirType.statistic.readingFont)
        XCTAssertEqual(AirType.label.readingFont, .custom(AirType.readingFamily, fixedSize: 12).weight(.medium))
        XCTAssertEqual(AirType.caption.readingFont, .custom(AirType.readingFamily, fixedSize: 11).weight(.regular))
    }
}

final class ReadingTextTests: XCTestCase {
    private func readings(_ sentence: String) -> [String] {
        ReadingText.ranges(in: sentence).map { String(sentence[$0]) }
    }

    func testANumberTakesItsUnitWithIt() {
        XCTAssertEqual(readings("Held at 5,349 RPM."), ["5,349 RPM"])
        XCTAssertEqual(readings("Follows CPU Average, from 70° to full speed at 95°."), ["70°", "95°"])
        XCTAssertEqual(readings("The CPU reached 97.5 °C, so macOS controls the fans until it cools to 189°F."), ["97.5 °C", "189°F"])
        XCTAssertEqual(readings("Every fan is held at 45% of its range."), ["45%"])
        XCTAssertEqual(readings("between 22:00 and 07:00"), ["22:00", "07:00"])
    }

    func testASentenceEndIsNotPartOfTheReading() {
        XCTAssertEqual(readings("It reached 95."), ["95"])
        XCTAssertEqual(readings("macOS controls this fan."), [])
    }

    func testOnlyTheReadingsAreInTheMonospacedFace() {
        let text = ReadingText.attributed("Held at 3,200 RPM.", role: .body)
        let fonts = text.runs.map { (String(text[$0.range].characters), $0.font) }
        XCTAssertEqual(fonts.map(\.0), ["Held at ", "3,200", " ", "RPM", "."])
        XCTAssertEqual(fonts.map(\.1), [nil, AirType.body.readingFont, nil, AirType.body.readingFont, nil])
    }
}

final class FanSentenceTests: XCTestCase {
    private let format = ReadingFormat(unit: .celsius, isPrecise: false)
    private let rule = SensorRule(source: .cpuAverage, startCelsius: 70, maxCelsius: 95)

    private func sentence(_ control: FanControl, _ command: FanCommand, isActive: Bool, mode: FanController.Mode) -> String {
        FanSentence.text(control: control, command: command, sourceName: { _ in "CPU Average" }, format: format, isActive: isActive, mode: mode)
    }

    func testOnlyAnActivePresetUnderControlStatesAFact() {
        XCTAssertEqual(sentence(.constant(rpm: 3200), .speed(3200), isActive: true, mode: .controlling), "Held at 3,200 RPM.")
        XCTAssertEqual(
            sentence(.sensorBased(rule), .speed(2010), isActive: true, mode: .controlling),
            "Follows CPU Average, from 70° to full speed at 95°. It's set to 2,010 RPM now."
        )
    }

    func testAnActivePresetThatAirFlowCannotApplySaysWhoHasTheFan() {
        XCTAssertEqual(
            sentence(.constant(rpm: 5349), .speed(5349), isActive: true, mode: .monitoring),
            "This preset holds it at 5,349 RPM. macOS controls the fan now.",
            "A constant speed is said once"
        )
        XCTAssertEqual(
            sentence(.sensorBased(rule), .speed(4100), isActive: true, mode: .safeguard),
            "This preset follows CPU Average, from 70° to full speed at 95°. The safeguard is on, so macOS controls the fan now. It would be set to 4,100 RPM."
        )
    }

    func testAPresetThatIsNotActiveSaysWhatItWouldAskFor() {
        XCTAssertEqual(
            sentence(.sensorBased(rule), .speed(2010), isActive: false, mode: .controlling),
            "This preset follows CPU Average, from 70° to full speed at 95°. It would be set to 2,010 RPM."
        )
    }

    func testAnAutomaticFanAndAMissingSensorBelongToMacOS() {
        XCTAssertEqual(sentence(.automatic, .automatic, isActive: true, mode: .controlling), "macOS controls this fan.")
        XCTAssertEqual(
            sentence(.sensorBased(rule), .automatic, isActive: true, mode: .controlling),
            "Follows CPU Average, from 70° to full speed at 95°. This Mac doesn't report that sensor, so macOS controls the fan."
        )
    }
}

final class NameRegistryTests: XCTestCase {
    func testAFreeNameIsKeptAndATakenNameGetsTheNextNumber() {
        var names = NameRegistry(taken: ["Quiet", "Travel"])
        XCTAssertEqual(names.claim("Office"), "Office")
        XCTAssertEqual(names.claim("quiet"), "quiet 2")
        XCTAssertEqual(names.claim("Quiet"), "Quiet 3")
        XCTAssertEqual(names.claim("Office"), "Office 2")
        XCTAssertEqual(names.claim(""), "Untitled Preset")
        XCTAssertEqual(names.claim(""), "Untitled Preset 2")
    }

    func testANameThatWasHandedOutIsTaken() {
        var names = NameRegistry(taken: ["Quiet"])
        XCTAssertEqual(names.claim("Quiet"), "Quiet 2")
        XCTAssertEqual(names.claim("Quiet 2"), "Quiet 2 2", "The second preset already has this name")
    }

    func testANumberedNameThatIsTakenIsSkipped() {
        var names = NameRegistry(taken: ["Quiet", "Quiet 2", "Quiet 4"])
        XCTAssertEqual(names.claim("Quiet"), "Quiet 3")
        XCTAssertEqual(names.claim("Quiet"), "Quiet 5")
        XCTAssertEqual(names.claim("Quiet 2"), "Quiet 2 2")
    }
}

final class FlowLayoutTests: XCTestCase {
    private let sizes = [CGSize(width: 60, height: 20), CGSize(width: 100, height: 24), CGSize(width: 40, height: 18)]

    func testPiecesStayOnOneLineWhenTheyFit() {
        let lines = FlowLayout.lines(of: sizes, within: 216, spacing: 8)
        XCTAssertEqual(lines, [FlowLayout.Line(indices: [0, 1, 2], width: 216, height: 24)])
    }

    func testAPieceThatDoesNotFitStartsTheNextLine() {
        let lines = FlowLayout.lines(of: sizes, within: 215, spacing: 8)
        XCTAssertEqual(lines.map(\.indices), [[0, 1], [2]])
        XCTAssertEqual(lines.map(\.width), [168, 40])
        XCTAssertEqual(lines.map(\.height), [24, 18])
    }

    func testAPieceWiderThanTheLineGetsALineOfItsOwn() {
        let lines = FlowLayout.lines(of: sizes, within: 50, spacing: 8)
        XCTAssertEqual(lines.map(\.indices), [[0], [1], [2]])
        XCTAssertTrue(FlowLayout.lines(of: [], within: 50, spacing: 8).isEmpty)
    }
}
