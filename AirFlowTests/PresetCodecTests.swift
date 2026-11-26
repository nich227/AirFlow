import XCTest
@testable import AirFlow

final class PresetCodecTests: XCTestCase {
    private let everyKind = Preset(
        name: "Render", icon: .videoCamera,
        controls: [
            0: .constant(rpm: 3200),
            1: .automatic,
            2: .constantFraction(0.5),
            3: .sensorBased(SensorRule(source: .key("TaLP"), startCelsius: 35.5, maxCelsius: 50)),
        ],
        fallback: .sensorBased(SensorRule(source: .group(.gpu, .hottest), startCelsius: 60, maxCelsius: 90)),
        summary: "Keeps the GPU cool while a render runs."
    )

    func testEveryKindOfControlSurvivesARoundTrip() throws {
        let text = try PresetCodec.encode([everyKind])
        XCTAssertEqual(try PresetCodec.decode(text), [everyKind])
    }

    func testTheFileReadsLikeAPersonWroteIt() throws {
        let text = try PresetCodec.encode([everyKind])
        for line in [
            "airflow: 2", "name: Render", "icon: video-camera", "summary: Keeps the GPU cool while a render runs.",
            "mode: sensor", "sensor: gpu hottest", "start: 60", "full: 90",
            "fan: 1", "mode: constant", "rpm: 3200", "fan: 2", "mode: automatic", "fan: 3", "percent: 50",
            "fan: 4", "sensor: key TaLP", "start: 35.5",
        ] {
            XCTAssertTrue(text.contains(line), "The file has no line “\(line)”:\n\(text)")
        }
    }

    func testNamesThatYAMLCouldMisreadAreQuotedAndComeBackUnchanged() throws {
        let names = [
            "Yes", "null", "off", "Quiet: Night", "#1 Preset", "\"Quoted\"", "It's Fine", "Tabs\tand\\slashes",
            "Café 80°", "- Dash", "[Bracket]", "{Brace}", "42", "Trailing dot.", "A, B (50%)", "日本語", "@home", "a\u{2028}b",
        ]
        let presets = names.map { Preset(name: $0, icon: .moon, fallback: .automatic, summary: $0) }
        let decoded = try PresetCodec.decode(try PresetCodec.encode(presets))
        XCTAssertEqual(decoded.map(\.name), names)
        XCTAssertEqual(decoded.map(\.summary), names)
        XCTAssertEqual(PresetCodec.scalar("Heavy Workload"), "Heavy Workload", "An ordinary name needs no quotes")
        XCTAssertEqual(PresetCodec.scalar("Yes"), "\"Yes\"")
        XCTAssertEqual(PresetCodec.scalar("a: b"), "\"a: b\"")
    }

    func testNumbersAreWrittenPlainly() {
        XCTAssertEqual(PresetCodec.number(70), "70")
        XCTAssertEqual(PresetCodec.number(35.5), "35.5")
        XCTAssertEqual(PresetCodec.number(33.333333), "33.33")
        XCTAssertEqual(PresetCodec.number(49.999), "50")
        XCTAssertEqual(PresetCodec.number(.nan), "0")
    }

    func testAFileWrittenByHandIsRead() throws {
        let text = """
            airflow: 1
            presets:
              - name: Night
                fans:
                  mode: sensor
                  start: 75
                  full: 100
              - name: "  Half  "
                icon: not-an-icon
                fans: {mode: Constant, percent: 50}
                overrides:
                  - {fan: 2, mode: auto}
            """
        let presets = try PresetCodec.decode(text)
        XCTAssertEqual(presets.map(\.name), ["Night", "Half"])
        XCTAssertEqual(presets[0].fallback, .sensorBased(SensorRule(source: .cpuAverage, startCelsius: 75, maxCelsius: 100)), "The CPU average is the sensor when none is named")
        XCTAssertEqual(presets[0].icon, .sliders)
        XCTAssertEqual(presets[1].icon, .sliders, "An icon this version does not have falls back")
        XCTAssertEqual(presets[1].fallback, .constantFraction(0.5))
        XCTAssertEqual(presets[1].controls, [1: .automatic], "Fans are counted from 1 in a file")
        XCTAssertTrue(presets.allSatisfy { $0.kind == .custom })
    }

    func testARuleThatLeavesTheFanToTheSystemBelowItsStartSurvivesARoundTrip() throws {
        let rule = SensorRule(source: .group(.battery, .average), startCelsius: 33, maxCelsius: 43, belowStart: .automatic)
        let travel = Preset(name: "Lap", icon: .airplane, fallback: .sensorBased(rule))
        let text = try PresetCodec.encode([travel])
        XCTAssertTrue(text.contains("        below: automatic\n") || text.contains("      below: automatic\n"), text)
        XCTAssertEqual(try PresetCodec.decode(text), [travel])
        let plain = try PresetCodec.encode([Preset(name: "Plain", icon: .moon, fallback: .sensorBased(SensorRule(source: .cpuAverage, startCelsius: 70, maxCelsius: 95)))])
        XCTAssertTrue(plain.hasPrefix(PresetCodec.header))
        XCTAssertFalse(plain.dropFirst(PresetCodec.header.count).contains("below"), "A rule that holds the minimum is written as before")
    }

    func testAFileOfTheOlderFormatIsRead() throws {
        let older = "airflow: 1\npresets:\n  - name: Old\n    fans: {mode: sensor, sensor: battery average, start: 33, full: 43}\n"
        let rule = SensorRule(source: .group(.battery, .average), startCelsius: 33, maxCelsius: 43)
        XCTAssertEqual(try PresetCodec.decode(older).first?.fallback, .sensorBased(rule), "Format 1 had no below, so the fan holds its minimum")
        XCTAssertEqual(rule.belowStart, .minimum)
        let written = "airflow: 2\npresets:\n  - name: New\n    fans: {mode: sensor, sensor: battery average, start: 33, full: 43, below: Auto}\n"
        guard case .sensorBased(let read)? = try PresetCodec.decode(written).first?.fallback else { return XCTFail("not a sensor rule") }
        XCTAssertEqual(read.belowStart, .automatic)
        XCTAssertEqual(PresetCodec.version, 2)
    }

    func testNumbersInAFileGoThroughTheSameLimitsAsAnyPreset() throws {
        let text = """
            airflow: 1
            presets:
              - name: Wild
                fans: {mode: sensor, sensor: cpu average, start: -400, full: 9000}
                overrides:
                  - {fan: 1, mode: constant, rpm: 99999999}
                  - {fan: 2, mode: constant, percent: 400}
            """
        let preset = try XCTUnwrap(PresetCodec.decode(text).first)
        guard case .sensorBased(let rule) = preset.fallback else { return XCTFail("not a sensor rule") }
        XCTAssertEqual(rule.startCelsius, SensorRule.temperatureRange.lowerBound)
        XCTAssertEqual(rule.maxCelsius, SensorRule.temperatureRange.upperBound)
        XCTAssertEqual(preset.controls[1], .constantFraction(1))
        let plan = FanPlanner.plan(preset: preset, snapshot: Fixtures.snapshot())
        XCTAssertEqual(plan[0], .speed(5000), "No file can ask a fan for more than its maximum")
        XCTAssertEqual(plan[1], .speed(5000))
    }

    private func failure(_ text: String) -> PresetCodec.Failure? {
        do {
            _ = try PresetCodec.decode(text)
            return nil
        } catch {
            return error as? PresetCodec.Failure
        }
    }

    private func document(_ fans: String, overrides: String = "") -> String {
        "airflow: 1\npresets:\n  - name: Odd\n    fans: \(fans)\n\(overrides)"
    }

    func testAFileThatIsNotPresetsIsRefusedWithAReason() {
        XCTAssertEqual(failure("airflow: 3\npresets:\n  - name: A\n    fans: {mode: automatic}\n"), .newerVersion(3))
        XCTAssertEqual(failure("airflow: 1\npresets: []\n"), .noPresets)
        XCTAssertEqual(failure(String(repeating: "#", count: PresetCodec.maximumBytes + 1)), .tooLarge)
        guard case .notYAML = failure("just some text") else { return XCTFail("plain text was read as presets") }
        guard case .notYAML = failure("presets:\n  - name: A\n    fans: {mode: automatic}\n") else { return XCTFail("a file with no version was read") }
        guard case .notYAML = failure("airflow: 1\npresets:\n  - fans: {mode: automatic}\n") else { return XCTFail("a preset with no name was read") }
        guard case .notYAML = failure(": : :\n\t- [") else { return XCTFail("broken YAML was read") }
        let many = "airflow: 1\npresets:\n" + String(repeating: "  - name: A\n    fans: {mode: automatic}\n", count: PresetCodec.maximumPresets + 1)
        XCTAssertEqual(failure(many), .tooManyPresets)
    }

    func testAPresetThatMakesNoSenseIsRefusedByName() {
        func reason(_ text: String) -> String? {
            guard case .invalid(let preset, let reason)? = failure(text) else { return nil }
            XCTAssertEqual(preset, "Odd")
            return reason
        }
        XCTAssertEqual(reason(document("{mode: turbo}")), "“turbo” isn't a mode. Use automatic, constant, or sensor.")
        XCTAssertEqual(reason(document("{mode: constant}")), "a constant speed needs rpm or percent.")
        XCTAssertEqual(reason(document("{mode: sensor, start: 50}")), "a sensor mode needs start and full temperatures.")
        XCTAssertEqual(reason(document("{mode: sensor, sensor: toaster, start: 50, full: 80}")), "“toaster” isn't a sensor AirFlow knows.")
        XCTAssertEqual(reason(document("{mode: sensor, start: 50, full: 80, below: off}")), "“off” isn't a choice for below. Use minimum or automatic.")
        XCTAssertEqual(
            reason(document("{mode: automatic}", overrides: "    overrides:\n      - {mode: automatic}\n")),
            "an override needs a fan number from 1 to 16."
        )
        XCTAssertEqual(
            reason(document("{mode: automatic}", overrides: "    overrides:\n      - {fan: 0, mode: automatic}\n")),
            "an override needs a fan number from 1 to 16."
        )
        XCTAssertNotNil(PresetCodec.Failure.invalid(preset: "Odd", reason: "x").errorDescription)
    }

    func testSensorNames() {
        XCTAssertEqual(PresetCodec.source(named: "cpu average"), .cpuAverage)
        XCTAssertEqual(PresetCodec.source(named: "GPU Hottest"), .group(.gpu, .hottest))
        XCTAssertEqual(PresetCodec.source(named: "battery"), .group(.battery, .average))
        XCTAssertEqual(PresetCodec.source(named: "key TaLP"), .key("TaLP"), "A key keeps its capitals")
        XCTAssertNil(PresetCodec.source(named: "key toolong"))
        XCTAssertNil(PresetCodec.source(named: "cpu loudest"))
        XCTAssertNil(PresetCodec.source(named: ""))
        for group in SensorGroup.allCases {
            for reduction in SensorReduction.allCases {
                let source = SensorSource.group(group, reduction)
                XCTAssertEqual(PresetCodec.source(named: PresetCodec.name(of: source)), source)
            }
        }
    }

    @MainActor
    func testAFileAPersonChoosesIsImportedOrTheReasonIsKept() throws {
        let suite = "airflow-import-\(UUID().uuidString)"
        let model = AppModel(
            defaults: UserDefaults(suiteName: suite) ?? .standard, presetsURL: nil, rulesURL: nil,
            sampler: HardwareSampler(makeSource: { throw HardwareError.cannotOpenSMC }),
            commander: CommandRecorder(), helper: HelperManager(isSigned: false)
        )
        let folder = FileManager.default.temporaryDirectory
        let good = folder.appendingPathComponent("airflow-good-\(UUID().uuidString).yaml")
        let bad = folder.appendingPathComponent("airflow-bad-\(UUID().uuidString).yaml")
        defer {
            try? FileManager.default.removeItem(at: good)
            try? FileManager.default.removeItem(at: bad)
        }
        try Data(try PresetCodec.encode([everyKind]).utf8).write(to: good)
        try Data("airflow: 1\npresets:\n  - name: Odd\n    fans: {mode: turbo}\n".utf8).write(to: bad)

        XCTAssertEqual(model.importPresets(from: good).map(\.name), ["Render"])
        XCTAssertNil(model.transfer.message)
        let count = model.presets.custom.count
        XCTAssertTrue(model.importPresets(from: bad).isEmpty)
        XCTAssertEqual(model.transfer.message, "The preset “Odd” can't be read: “turbo” isn't a mode. Use automatic, constant, or sensor.")
        XCTAssertEqual(model.presets.custom.count, count, "A file that is refused adds nothing")

        model.beginExport(ids: [try XCTUnwrap(model.presets.preset(named: "Render")).id])
        XCTAssertTrue(model.transfer.isExporting)
        XCTAssertEqual(model.transfer.exportName, "Render")
        XCTAssertEqual(try PresetCodec.decode(try XCTUnwrap(model.transfer.export).text).map(\.name), ["Render"])
    }
}
