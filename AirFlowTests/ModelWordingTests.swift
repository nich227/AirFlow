import XCTest
@testable import AirFlow

/// The words, identifiers, and small conversions of the models: what a person reads for each case
/// of an enumeration, and what a list uses to tell its rows apart.
final class ModelWordingTests: XCTestCase {
    func testEveryCaseAPersonCanChooseHasItsOwnWords() {
        XCTAssertEqual(WorkloadRegime.allCases.map(\.title), ["Light", "Bursty", "Sustained"])
        XCTAssertEqual(Set(WorkloadRegime.allCases.map(\.id)).count, 3)
        XCTAssertTrue(WorkloadRegime.light.explanation.contains("\(Int(AdaptivePolicy.light.engageCelsius))°"))
        XCTAssertTrue(WorkloadRegime.bursty.explanation.hasPrefix("Fans stay quiet through short bursts"))
        XCTAssertTrue(WorkloadRegime.sustained.explanation.hasPrefix("Fans speed up before the heat builds"))

        XCTAssertEqual(MenuBarReadout.allCases.map(\.title), ["Icon Only", "Fastest Fan", "CPU Temperature", "GPU Temperature", "Fan and CPU Temperature"])
        XCTAssertEqual(MenuBarReadout.allCases.map(\.id), MenuBarReadout.allCases.map(\.rawValue))

        XCTAssertEqual(PowerSource.allCases.map(\.title), ["Battery", "Power Adapter"])
        XCTAssertEqual(PowerSource.allCases.map(\.id), ["battery", "adapter"])

        XCTAssertEqual(AutomationTrigger.Kind.allCases.map(\.title), ["App Is Active", "Power Source", "Temperature Rises Above", "Time of Day"])
        XCTAssertEqual(AutomationTrigger.Kind.allCases.map(\.id), ["app", "power", "temperature", "time"])
        XCTAssertEqual(AutomationTrigger.Kind.allCases.map(\.iconName), ["ant-appstore", "ant-thunderbolt", "ant-fire", "ant-clock-circle"])

        XCTAssertEqual(DotColoring.allCases.map(\.title), ["By Temperature", "By Part"])
        XCTAssertEqual(DotColoring.allCases.map(\.id), ["temperature", "part"])

        XCTAssertEqual(FanControl.Kind.allCases.map(\.title), ["Automatic", "Constant", "Sensor-Based"])
        XCTAssertEqual(FanControl.Kind.allCases.map(\.id), ["automatic", "constant", "sensorBased"])

        XCTAssertEqual(TemperatureBand.allCases.map(\.word), ["Cool", "Normal", "Warm", "Hot", "Very Hot"])
        XCTAssertEqual(TemperatureBand.allCases.sorted(), TemperatureBand.allCases, "The bands are in order from cool to very hot")
        XCTAssertLessThan(TemperatureBand.warm, TemperatureBand.hot)

        XCTAssertEqual(TemperatureUnit.allCases.map(\.id), TemperatureUnit.allCases.map(\.rawValue))
        XCTAssertEqual(SensorGroup.allCases.map(\.id), SensorGroup.allCases.map(\.rawValue))
    }

    func testAPresetsIconIsOneOfTheIconsAirFlowHas() throws {
        XCTAssertEqual(PresetIcon.allCases.count, AntIconCatalog.names.count)
        XCTAssertEqual(Set(PresetIcon.allCases.map(\.id)).count, PresetIcon.allCases.count, "Each icon has a name of its own")
        XCTAssertGreaterThan(PresetIcon.allCases.count, 400, "Every outlined icon of Ant Design, and AirFlow's own two")
        XCTAssertEqual(AntIconCatalog.names, AntIconCatalog.names.sorted(), "In the order of their names")

        let camera = try XCTUnwrap(PresetIcon(rawValue: "video-camera"))
        XCTAssertEqual(camera, .videoCamera)
        XCTAssertEqual(camera.id, "video-camera")
        XCTAssertEqual(camera.assetName, "ant-video-camera")
        XCTAssertNil(PresetIcon(rawValue: "no-such-icon"))
        XCTAssertNil(PresetIcon(rawValue: ""))
        XCTAssertNil(PresetIcon(rawValue: "ant-fire"), "The name is the icon's own, without the prefix of its image")
        for icon in [PresetIcon.sync, .thunderbolt, .sparkles, .airplane, .cloud, .coffee, .compass, .dashboard, .fire, .moon, .rocket, .sliders, .sound, .videoCamera] {
            XCTAssertEqual(PresetIcon(rawValue: icon.rawValue), icon, "\(icon.rawValue) is in the catalog")
        }
    }

    func testAnIconsNameIsWrittenForAPerson() throws {
        XCTAssertEqual(PresetIcon.videoCamera.title, "Video Camera")
        XCTAssertEqual(PresetIcon.fire.title, "Fire")
        XCTAssertEqual(try XCTUnwrap(PresetIcon(rawValue: "loading-3-quarters")).title, "Loading 3 Quarters")
        // A name that is not a word is written as its owner writes it.
        XCTAssertEqual(try XCTUnwrap(PresetIcon(rawValue: "open-a-i")).title, "OpenAI")
        XCTAssertEqual(try XCTUnwrap(PresetIcon(rawValue: "wifi")).title, "Wi-Fi")
        XCTAssertEqual(try XCTUnwrap(PresetIcon(rawValue: "dot-net")).title, ".NET")
        XCTAssertTrue(PresetIcon.allCases.allSatisfy { !$0.title.isEmpty && !$0.title.contains("-") || $0.rawValue == "wifi" })
    }

    func testEveryIconIsOfferedForEveryPreset() {
        XCTAssertEqual(Preset.automatic.icon, .sync)
        XCTAssertEqual(Preset.fullBlast.icon, .thunderbolt)
        XCTAssertEqual(Preset.adaptive.icon, .sparkles)
        // Two presets can have the same icon, a built-in preset's included.
        XCTAssertEqual(PresetIcon.matching(""), PresetIcon.allCases)
        XCTAssertEqual(PresetIcon.matching("   "), PresetIcon.allCases)
        for icon in [PresetIcon.sync, .thunderbolt, .sparkles, .airplane] {
            XCTAssertTrue(PresetIcon.matching(icon.title).contains(icon), icon.rawValue)
        }
    }

    func testIconsAreFoundByTheWordsOfTheirNames() {
        XCTAssertEqual(PresetIcon.matching("Video").map(\.rawValue), ["video-camera", "video-camera-add"])
        XCTAssertEqual(PresetIcon.matching("camera video add").map(\.rawValue), ["video-camera-add"], "Every word, in any order")
        XCTAssertEqual(PresetIcon.matching("video-camera").map(\.rawValue), ["video-camera", "video-camera-add"])
        XCTAssertEqual(PresetIcon.matching("openai").map(\.rawValue), ["open-a-i"], "By the name as a person writes it")
        XCTAssertEqual(PresetIcon.matching("WI-FI").map(\.rawValue), ["wifi"])
        XCTAssertEqual(PresetIcon.matching("sync").map(\.rawValue), ["cloud-sync", "file-sync", "sync"])
        XCTAssertEqual(PresetIcon.matching("sparkles"), [.sparkles])
        XCTAssertTrue(PresetIcon.matching("no such icon").isEmpty)
    }

    func testAnIconIsStoredByItsName() throws {
        let data = try JSONEncoder().encode([PresetIcon.videoCamera, .sync])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"["video-camera","sync"]"#)
        XCTAssertEqual(try JSONDecoder().decode([PresetIcon].self, from: data), [.videoCamera, .sync])
        XCTAssertThrowsError(try JSONDecoder().decode([PresetIcon].self, from: Data(#"["not-an-icon"]"#.utf8))) { error in
            guard case DecodingError.dataCorrupted(let context) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(context.debugDescription, "“not-an-icon” is not an icon AirFlow has.")
        }
        XCTAssertThrowsError(try JSONDecoder().decode([PresetIcon].self, from: Data("[3]".utf8)))

        // A presets file names any icon AirFlow has, and one it does not have reads as the sliders.
        let file = { (icon: String) in "airflow: 2\npresets:\n  - name: A\n    icon: \(icon)\n    fans: {mode: automatic}\n" }
        XCTAssertEqual(try PresetCodec.decode(file("bug")).first?.icon.rawValue, "bug")
        XCTAssertEqual(try PresetCodec.decode(file("sync")).first?.icon.rawValue, "sync", "An icon from an older file is still an icon")
        XCTAssertEqual(try PresetCodec.decode(file("not-an-icon")).first?.icon, .sliders)
        let written = PresetCodec.encode([Preset(name: "A", icon: try XCTUnwrap(PresetIcon(rawValue: "bug")), fallback: .automatic)])
        XCTAssertTrue(written.contains("    icon: bug\n"))
    }

    func testATriggerAndAControlKnowTheirKind() {
        XCTAssertEqual(AutomationTrigger.appIsFrontmost(bundleID: "a", name: "A").kind, .app)
        XCTAssertEqual(AutomationTrigger.powerSource(.battery).kind, .power)
        XCTAssertEqual(AutomationTrigger.temperatureAbove(source: .cpuAverage, celsius: 80).kind, .temperature)
        XCTAssertEqual(AutomationTrigger.timeRange(startMinute: 0, endMinute: 60).kind, .time)

        XCTAssertEqual(FanControl.automatic.kind, .automatic)
        XCTAssertEqual(FanControl.constant(rpm: 2000).kind, .constant)
        XCTAssertEqual(FanControl.constantFraction(0.5).kind, .constant)
        XCTAssertEqual(FanControl.sensorBased(SensorRule(source: .cpuAverage, startCelsius: 50, maxCelsius: 80)).kind, .sensorBased)
    }

    func testRowsAreToldApartByWhatNamesThem() {
        XCTAssertEqual(Fixtures.fan(1).id, 1)
        XCTAssertEqual(Sensor(key: "Tp01", name: "x", group: .cpu, celsius: 50).id, "Tp01")
        let date = Date(timeIntervalSinceReferenceDate: 5)
        XCTAssertEqual(HistoryPoint(date: date, cpu: nil, gpu: nil, fanFractions: []).id, date)
        XCTAssertEqual(AppWorkload(bundleID: "com.apple.dt.Xcode", name: "Xcode", regime: .bursty).id, "com.apple.dt.Xcode")
        XCTAssertEqual(Set([Preset.automaticID, Preset.fullBlastID, Preset.adaptiveID]).count, 3, "Each built-in preset has an identifier of its own")
        XCTAssertEqual(Preset.automatic.id, Preset.automaticID)
        XCTAssertEqual(Preset.fullBlast.id, Preset.fullBlastID)
        XCTAssertEqual(Preset.adaptive.id, Preset.adaptiveID)
    }

    func testPowerAndTheTimeOfDayAreWrittenForAPerson() {
        XCTAssertEqual(ReadingFormat.watts(28.5), "29", "Half a watt rounds up")
        XCTAssertEqual(ReadingFormat.watts(34.6), "35")
        XCTAssertEqual(ReadingFormat.watts(0), "0")
        var components = DateComponents()
        components.hour = 22
        components.minute = 30
        let expected = Calendar.current.date(from: components)?.formatted(date: .omitted, time: .shortened)
        XCTAssertEqual(ReadingFormat.time(minuteOfDay: 22 * 60 + 30), expected)
        XCTAssertFalse(ReadingFormat.time(minuteOfDay: 0).isEmpty)
    }

    func testASnapshotListsThePartsItHasReadingsFor() {
        let snapshot = Fixtures.snapshot(cpu: 60, gpu: 50, battery: 30)
        XCTAssertEqual(snapshot.sensors(in: .cpu).map(\.key), ["Tp01", "Tp02"])
        XCTAssertEqual(snapshot.sensors(in: .memory), [])
        XCTAssertEqual(snapshot.summaries.map(\.group), [.cpu, .gpu, .battery], "Only the parts the Mac reports, in the order the app lists them")
        XCTAssertEqual(Fixtures.snapshot(gpu: nil, battery: nil).summaries.map(\.group), [.cpu])
    }

    func testARuleForATimeOfDayMatchesInsideItsHours() {
        var engine = AutomationEngine()
        let preset = UUID()
        let night = AutomationRule(trigger: .timeRange(startMinute: 22 * 60, endMinute: 7 * 60), presetID: preset)
        XCTAssertEqual(engine.match(rules: [night], context: Fixtures.context(minute: 23 * 60), presets: [preset]), night)
        XCTAssertEqual(engine.match(rules: [night], context: Fixtures.context(minute: 3 * 60), presets: [preset]), night, "The hours run past midnight")
        XCTAssertNil(engine.match(rules: [night], context: Fixtures.context(minute: 12 * 60), presets: [preset]))
    }

    func testAFileWithAValueOfTheWrongKindSaysWhichOne() {
        XCTAssertThrowsError(try PresetCodec.decode("airflow: 1\npresets:\n  - name: A\n    fans: 5\n")) { error in
            XCTAssertEqual(error as? PresetCodec.Failure, .notYAML("The value of “fans” is the wrong kind."))
        }
    }

    func testTheForecasterStartsAgainWhenTheClockRunsBackwardOrItsNumbersBreak() {
        var forecaster = ThermalForecaster()
        let features = ThermalForecaster.features(celsius: 60, slope: 0.1, load: 0.5, fanFraction: 0.2)
        forecaster.observe(features: features, celsius: 60, at: 100)
        forecaster.observe(features: features, celsius: 61, at: 120)
        XCTAssertEqual(forecaster.updates, 1, "The reading from a horizon ago has its answer")
        // The clock ran backward, as after the Mac's clock is set: the readings that wait for
        // an answer are dropped, so none is scored against a time before it.
        forecaster.observe(features: features, celsius: 61, at: 50)
        forecaster.observe(features: features, celsius: 62, at: 60)
        XCTAssertEqual(forecaster.updates, 1, "Ten seconds is less than a horizon, and the older readings are gone")
        XCTAssertTrue(forecaster.isValid)

        // Readings too large to multiply teach nothing.
        var unmoved = ThermalForecaster()
        let huge = [Double](repeating: 1e200, count: features.count)
        unmoved.observe(features: huge, celsius: 60, at: 0)
        unmoved.observe(features: huge, celsius: 61, at: 20)
        XCTAssertEqual(unmoved.updates, 0)
        XCTAssertTrue(unmoved.isValid)
    }

    func testAForecasterWhoseStoredNumbersOverflowStartsOver() throws {
        // A stored file can hold numbers that are finite, and too large to learn from.
        let stored = try JSONEncoder().encode(ThermalForecaster())
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: stored) as? [String: Any])
        let weights = try XCTUnwrap(fields["weights"] as? [Double])
        fields["weights"] = weights.map { _ in 1e300 }
        var forecaster = try JSONDecoder().decode(ThermalForecaster.self, from: JSONSerialization.data(withJSONObject: fields))
        XCTAssertTrue(forecaster.isValid, "Every number is finite, so the file is accepted")
        let large = [Double](repeating: 1e10, count: weights.count)
        forecaster.observe(features: large, celsius: 60, at: 0)
        forecaster.observe(features: large, celsius: 61, at: 20)
        XCTAssertEqual(forecaster.updates, 0, "What it learned was not a number, so it starts over")
        XCTAssertTrue(forecaster.isValid)
        XCTAssertEqual(forecaster.weights, [Double](repeating: 0, count: weights.count))
    }

    func testAWindowWithNothingInItGivesTheValueItIsHanded() {
        var window = RollingWindow(span: 10)
        XCTAssertNil(window.mean)
        XCTAssertEqual(window.mean(or: 7), 7)
        window.add(3, at: 0)
        window.add(5, at: 1)
        XCTAssertEqual(window.mean(or: 7), 4)
        window.add(.nan, at: 2)
        XCTAssertEqual(window.count, 2, "A reading that is not a number is left out")
    }

    func testPowerThatIsNotANumberCountsAsNoPower() {
        var controller = AdaptiveController()
        let fans = [Fixtures.fan(0), Fixtures.fan(1)]
        for watts in [Double.nan, .infinity] {
            let snapshot = ThermalSnapshot(
                date: Date(timeIntervalSinceReferenceDate: 100), fans: fans,
                sensors: [Sensor(key: "Tp01", name: "x", group: .cpu, celsius: 70)], systemWatts: watts
            )
            let state = controller.step(snapshot: snapshot, hint: .sustained)
            XCTAssertEqual(state?.regime, .light, "Without power there is no load to judge")
            XCTAssertNil(controller.scale)
        }
    }

    func testTheBuiltInPresetsKeepTheIdentifiersStoredSettingsNameThemBy() {
        XCTAssertEqual(Preset.automaticID.uuidString, "A1F10000-0000-4000-8000-000000000001")
        XCTAssertEqual(Preset.fullBlastID.uuidString, "A1F10000-0000-4000-8000-000000000002")
        XCTAssertEqual(Preset.adaptiveID.uuidString, "A1F10000-0000-4000-8000-000000000003")
    }

    @MainActor
    func testSettingsReadThePresetThatWasStored() {
        let defaults = UserDefaults(suiteName: "airflow-settings-\(UUID().uuidString)") ?? .standard
        XCTAssertEqual(AppSettings(defaults: defaults).activePresetID, Preset.automaticID, "A new copy leaves the fans to macOS")
        defaults.set(Preset.adaptiveID.uuidString, forKey: AppSettings.Key.activePresetID)
        XCTAssertEqual(AppSettings(defaults: defaults).activePresetID, Preset.adaptiveID)
        defaults.set("not an identifier", forKey: AppSettings.Key.activePresetID)
        XCTAssertEqual(AppSettings(defaults: defaults).activePresetID, Preset.automaticID)
    }

    func testASensorThatIsGoneIsNamedByItsKey() {
        let snapshot = Fixtures.snapshot()
        XCTAssertEqual(snapshot.name(of: .key("Tp01")), "Performance Core Sensor 1")
        XCTAssertEqual(snapshot.name(of: .key("Tx99")), "Tx99")
        XCTAssertEqual(snapshot.name(of: .cpuAverage), "\(SensorGroup.cpu.title) \(SensorReduction.average.title)")
    }

    func testATemperatureAboveEveryThresholdIsVeryHot() {
        XCTAssertEqual(TemperatureBand.band(for: 20, in: .cpu), .cool)
        XCTAssertEqual(TemperatureBand.band(for: 95, in: .cpu), .critical)
        XCTAssertEqual(TemperatureBand.band(for: 500, in: .battery), .critical)
        for group in SensorGroup.allCases {
            XCTAssertEqual(TemperatureBand.thresholds(for: group).count, TemperatureBand.allCases.count - 1, "One threshold between each two bands")
        }
    }

    func testAFileSaysWhichSensorOrChoiceItDoesNotKnow() {
        func failure(_ control: String) -> PresetCodec.Failure? {
            do {
                _ = try PresetCodec.decode("airflow: 2\npresets:\n  - name: A\n    fans: {mode: sensor, start: 40, full: 80\(control)}\n")
                return nil
            } catch {
                return error as? PresetCodec.Failure
            }
        }
        XCTAssertEqual(failure(", sensor: toaster"), .invalid(preset: "A", reason: "“toaster” isn't a sensor AirFlow knows."))
        XCTAssertEqual(failure(", below: Sideways"), .invalid(preset: "A", reason: "“Sideways” isn't a choice for below. Use minimum or automatic."))
        XCTAssertNil(failure(""), "With no sensor named, a rule follows the CPU average, and holds minimum speed below its start")
    }
}
