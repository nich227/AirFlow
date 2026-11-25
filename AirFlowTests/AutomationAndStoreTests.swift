import XCTest
@testable import AirFlow

final class AutomationEngineTests: XCTestCase {
    private let quiet = UUID()
    private let heavy = UUID()
    private lazy var presets: Set<UUID> = [quiet, heavy]

    private func rule(_ trigger: AutomationTrigger, _ preset: UUID, enabled: Bool = true) -> AutomationRule {
        AutomationRule(trigger: trigger, presetID: preset, isEnabled: enabled)
    }

    func testTheFirstRuleThatMatchesWins() {
        var engine = AutomationEngine()
        let rules = [
            rule(.appIsFrontmost(bundleID: "com.apple.dt.Xcode", name: "Xcode"), heavy),
            rule(.powerSource(.battery), quiet),
        ]
        let both = Fixtures.context(app: "com.apple.dt.Xcode", power: .battery)
        XCTAssertEqual(engine.match(rules: rules, context: both, presets: presets)?.presetID, heavy)
        XCTAssertEqual(engine.match(rules: rules.reversed(), context: both, presets: presets)?.presetID, quiet)
        XCTAssertNil(engine.match(rules: rules, context: Fixtures.context(app: "com.apple.Safari"), presets: presets))
    }

    func testADisabledRuleAndARuleForAMissingPresetNeverMatch() {
        var engine = AutomationEngine()
        let context = Fixtures.context(power: .battery)
        XCTAssertNil(engine.match(rules: [rule(.powerSource(.battery), quiet, enabled: false)], context: context, presets: presets))
        XCTAssertNil(engine.match(rules: [rule(.powerSource(.battery), UUID())], context: context, presets: presets))
    }

    func testATimeRangeCanRunPastMidnight() {
        XCTAssertTrue(AutomationEngine.minute(9 * 60, isBetween: 9 * 60, and: 17 * 60))
        XCTAssertFalse(AutomationEngine.minute(17 * 60, isBetween: 9 * 60, and: 17 * 60))
        XCTAssertTrue(AutomationEngine.minute(23 * 60, isBetween: 22 * 60, and: 7 * 60))
        XCTAssertTrue(AutomationEngine.minute(3 * 60, isBetween: 22 * 60, and: 7 * 60))
        XCTAssertFalse(AutomationEngine.minute(12 * 60, isBetween: 22 * 60, and: 7 * 60))
        XCTAssertFalse(AutomationEngine.minute(12 * 60, isBetween: 8 * 60, and: 8 * 60))
    }

    func testATemperatureRuleHoldsUntilTheSensorFallsWellBelowItsLimit() {
        var engine = AutomationEngine()
        let rules = [rule(.temperatureAbove(source: .cpuAverage, celsius: 85), heavy)]
        func matches(_ cpu: Double) -> Bool {
            engine.match(rules: rules, context: Fixtures.context(snapshot: Fixtures.snapshot(cpu: cpu)), presets: presets) != nil
        }
        XCTAssertFalse(matches(84))
        XCTAssertTrue(matches(85))
        XCTAssertTrue(matches(82), "Three degrees under the limit is inside the margin")
        XCTAssertFalse(matches(79))
        XCTAssertFalse(matches(82), "Once released, the limit itself must be reached again")
    }

    func testATemperatureRuleWhoseSensorIsMissingNeverMatches() {
        var engine = AutomationEngine()
        let rules = [rule(.temperatureAbove(source: .group(.memory, .average), celsius: 30), heavy)]
        XCTAssertNil(engine.match(rules: rules, context: Fixtures.context(), presets: presets))
    }
}

@MainActor
final class AutomationCoordinatorTests: XCTestCase {
    private let quiet = Preset(name: "Quiet", icon: .coffee)
    private let heavy = Preset(name: "Heavy", icon: .rocket)
    private lazy var presets = [Preset.automatic, quiet, heavy]

    private func coordinator() -> (AutomationCoordinator, AutomationRule, AutomationRule) {
        let coordinator = AutomationCoordinator(url: nil)
        let battery = AutomationRule(trigger: .powerSource(.battery), presetID: quiet.id)
        let xcode = AutomationRule(trigger: .appIsFrontmost(bundleID: "xcode", name: "Xcode"), presetID: heavy.id)
        coordinator.add(xcode)
        coordinator.add(battery)
        return (coordinator, xcode, battery)
    }

    func testAutopilotAppliesARuleOnceAndRevertsWhenItStops() {
        let (coordinator, xcode, _) = coordinator()
        let inXcode = Fixtures.context(app: "xcode")
        XCTAssertEqual(coordinator.evaluate(context: inXcode, presets: presets, isEnabled: true), .apply(presetID: heavy.id, ruleID: xcode.id))
        XCTAssertEqual(coordinator.evaluate(context: inXcode, presets: presets, isEnabled: true), .keep)
        XCTAssertEqual(coordinator.evaluate(context: Fixtures.context(app: "safari"), presets: presets, isEnabled: true), .revert)
        XCTAssertEqual(coordinator.evaluate(context: Fixtures.context(app: "safari"), presets: presets, isEnabled: true), .keep)
    }

    func testWithAutopilotOffARuleIsShownAsMatchingButNothingChanges() {
        let (coordinator, xcode, _) = coordinator()
        XCTAssertEqual(coordinator.evaluate(context: Fixtures.context(app: "xcode"), presets: presets, isEnabled: false), .keep)
        XCTAssertEqual(coordinator.matchedRuleID, xcode.id)
    }

    func testAPersonsChoiceHoldsUntilADifferentRuleMatches() {
        let (coordinator, _, battery) = coordinator()
        let inXcode = Fixtures.context(app: "xcode")
        _ = coordinator.evaluate(context: inXcode, presets: presets, isEnabled: true)
        coordinator.userChosePreset()
        XCTAssertTrue(coordinator.isHeldByUser)
        XCTAssertEqual(coordinator.evaluate(context: inXcode, presets: presets, isEnabled: true), .keep)
        let onBattery = Fixtures.context(app: "safari", power: .battery)
        XCTAssertEqual(coordinator.evaluate(context: onBattery, presets: presets, isEnabled: true), .apply(presetID: quiet.id, ruleID: battery.id))
        XCTAssertFalse(coordinator.isHeldByUser)
    }

    func testAChoiceMadeWhileNoRuleMatchesHoldsUntilOneDoes() {
        let (coordinator, xcode, _) = coordinator()
        let idle = Fixtures.context(app: "safari")
        _ = coordinator.evaluate(context: idle, presets: presets, isEnabled: true)
        coordinator.userChosePreset()
        XCTAssertEqual(coordinator.evaluate(context: idle, presets: presets, isEnabled: true), .keep)
        XCTAssertEqual(
            coordinator.evaluate(context: Fixtures.context(app: "xcode"), presets: presets, isEnabled: true),
            .apply(presetID: heavy.id, ruleID: xcode.id)
        )
    }

    func testRulesPersistAndFollowTheirPreset() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("airflow-rules-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = AutomationCoordinator(url: url)
        first.add(AutomationRule(trigger: .timeRange(startMinute: 60, endMinute: 120), presetID: quiet.id))
        first.add(AutomationRule(trigger: .powerSource(.adapter), presetID: heavy.id))
        first.move(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        let second = AutomationCoordinator(url: url)
        XCTAssertEqual(second.rules, first.rules)
        XCTAssertEqual(second.rules.first?.presetID, heavy.id)
        second.removeRules(forPreset: heavy.id)
        XCTAssertEqual(AutomationCoordinator(url: url).rules.map(\.presetID), [quiet.id])
    }

    func testFindingAnAppByTheNameAPersonSays() {
        let apps = [
            AppDirectory.App(bundleID: "com.apple.dt.Xcode", name: "Xcode"),
            AppDirectory.App(bundleID: "com.apple.FinalCut", name: "Final Cut Pro"),
            AppDirectory.App(bundleID: "com.apple.finder", name: "Finder"),
        ]
        XCTAssertEqual(AppDirectory.find(named: "xcode", among: apps)?.bundleID, "com.apple.dt.Xcode")
        XCTAssertEqual(AppDirectory.find(named: "Final Cut", among: apps)?.bundleID, "com.apple.FinalCut")
        XCTAssertEqual(AppDirectory.find(named: " finder ", among: apps)?.bundleID, "com.apple.finder")
        XCTAssertNil(AppDirectory.find(named: "Photoshop", among: apps))
        XCTAssertNil(AppDirectory.find(named: "", among: apps))
    }
}

@MainActor
final class PresetStoreTests: XCTestCase {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("airflow-presets-\(UUID().uuidString).yaml")
    }

    func testANewInstallationStartsWithTheBuiltInAndStarterPresets() {
        let store = PresetStore(url: nil)
        XCTAssertEqual(store.presets.map(\.name), ["Automatic", "Adaptive", "Full Blast", "Quiet", "Heavy Workload", "Travel"])
        XCTAssertEqual(store.preset(id: Preset.automaticID)?.kind, .automatic)
        XCTAssertEqual(store.preset(named: " full blast")?.id, Preset.fullBlastID)
    }

    func testPresetsSurviveARelaunchAndDeletedStartersStayDeleted() {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let first = PresetStore(url: url)
        let added = first.add(Preset(name: "Render", icon: .videoCamera, controls: [1: .constant(rpm: 4000)], fallback: .constantFraction(0.5)))
        first.custom.filter { $0.name != "Render" }.forEach { first.delete(id: $0.id) }
        let second = PresetStore(url: url)
        XCTAssertEqual(second.custom, [added])
        XCTAssertEqual(second.custom.first?.controls[1], .constant(rpm: 4000))
    }

    func testEveryPresetGetsANameOfItsOwn() {
        let store = PresetStore(url: nil)
        XCTAssertEqual(store.add(Preset(name: "Quiet", icon: .moon)).name, "Quiet 2")
        XCTAssertEqual(store.add(Preset(name: "quiet", icon: .moon)).name, "quiet 3")
        XCTAssertEqual(store.add(Preset(name: "Automatic", icon: .moon)).name, "Automatic 2")
        XCTAssertEqual(store.add(Preset(name: "   ", icon: .moon)).name, "Untitled Preset")
        XCTAssertEqual(store.add(Preset(name: String(repeating: "x", count: 90), icon: .moon)).name.count, 40)
    }

    func testRenamingKeepsNamesApartButAllowsThePresetsOwnName() throws {
        let store = PresetStore(url: nil)
        var quiet = try XCTUnwrap(store.preset(named: "Quiet"))
        quiet.name = "Travel"
        store.update(quiet)
        XCTAssertEqual(store.preset(id: quiet.id)?.name, "Travel 2")
        quiet.name = "Travel 2"
        quiet.icon = .moon
        store.update(quiet)
        XCTAssertEqual(store.preset(id: quiet.id)?.name, "Travel 2")
        XCTAssertEqual(store.preset(id: quiet.id)?.icon, .moon)
    }

    func testBuiltInPresetsCannotBeChangedOrDeleted() {
        let store = PresetStore(url: nil)
        var automatic = Preset.automatic
        automatic.name = "Mine"
        store.update(automatic)
        store.delete(id: Preset.fullBlastID)
        store.delete(id: Preset.adaptiveID)
        XCTAssertEqual(store.presets.prefix(3).map(\.name), ["Automatic", "Adaptive", "Full Blast"])
    }

    func testDuplicatingFullBlastMakesAPresetThatCanBeChanged() throws {
        let store = PresetStore(url: nil)
        let copy = try XCTUnwrap(store.duplicate(id: Preset.fullBlastID))
        XCTAssertEqual(copy.kind, .custom)
        XCTAssertEqual(copy.name, "Full Blast Copy")
        XCTAssertEqual(FanPlanner.plan(preset: copy, snapshot: Fixtures.snapshot()), [0: .speed(5000), 1: .speed(5000)])
    }

    func testDeletingEveryPresetIsAChoiceAndNotAFirstLaunch() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let first = PresetStore(url: url)
        first.custom.forEach { first.delete(id: $0.id) }
        XCTAssertTrue(PresetStore(url: url).custom.isEmpty)
    }

    func testThePresetsAreKeptAsYAMLAPersonCanRead() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        _ = PresetStore(url: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("# AirFlow fan presets."))
        XCTAssertTrue(text.contains("airflow: 1"))
        XCTAssertTrue(text.contains("- name: Quiet") || text.contains("name: Quiet"))
        XCTAssertTrue(text.contains("mode: sensor"))
        XCTAssertTrue(text.contains("sensor: cpu average"))
        XCTAssertTrue(text.contains("start: 70"))
        XCTAssertTrue(text.contains("full: 95"))
        XCTAssertFalse(text.contains("e+"), "Whole numbers are written as whole numbers")
    }

    func testImportingAddsPresetsAndNeverReplacesOne() throws {
        let source = PresetStore(url: nil)
        let exported = try source.exportText()
        let store = PresetStore(url: nil)
        let before = store.custom
        let added = try store.importText(exported)
        XCTAssertEqual(added.map(\.name), ["Quiet 2", "Heavy Workload 2", "Travel 2"])
        XCTAssertEqual(Array(store.custom.prefix(3)), before, "The presets already there are untouched")
        XCTAssertTrue(Set(added.map(\.id)).isDisjoint(with: Set(source.custom.map(\.id))), "An imported preset gets its own identifier")
        XCTAssertEqual(added.map(\.fallback), source.custom.map(\.fallback))
    }

    func testExportingOnePresetWritesOnlyThatPreset() throws {
        let store = PresetStore(url: nil)
        let travel = try XCTUnwrap(store.preset(named: "Travel"))
        let text = try store.exportText(ids: [travel.id])
        XCTAssertEqual(try PresetCodec.decode(text).map(\.name), ["Travel"])
        XCTAssertThrowsError(try PresetCodec.decode(try store.exportText(ids: [Preset.fullBlastID]))) {
            XCTAssertEqual($0 as? PresetCodec.Failure, .noPresets, "A built-in preset is not exported")
        }
    }

    func testAFileThatCannotBeReadIsSetAsideAndNotWrittenOver() throws {
        let url = temporaryURL()
        let aside = url.appendingPathExtension("unreadable")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: aside)
        }
        let damaged = Data("{ not presets".utf8)
        try damaged.write(to: url)
        let store = PresetStore(url: url)
        XCTAssertEqual(store.custom.map(\.name), ["Quiet", "Heavy Workload", "Travel"])
        XCTAssertEqual(try Data(contentsOf: aside), damaged, "The file a person may want back is kept")
    }
}

@MainActor
final class AppModelTests: XCTestCase {
    private func model(recorder: CommandRecorder = CommandRecorder()) -> AppModel {
        let suite = "airflow-tests-\(UUID().uuidString)"
        return AppModel(
            defaults: UserDefaults(suiteName: suite) ?? .standard, presetsURL: nil, rulesURL: nil,
            sampler: HardwareSampler(makeSource: { throw HardwareError.cannotOpenSMC }),
            commander: recorder, helper: HelperManager(isSigned: false)
        )
    }

    func testAPersonsChoiceBecomesTheActivePreset() throws {
        let model = model()
        XCTAssertEqual(model.activePreset.id, Preset.automaticID)
        let quiet = try XCTUnwrap(model.presets.preset(named: "Quiet"))
        model.apply(quiet.id)
        XCTAssertEqual(model.activePreset.id, quiet.id)
        XCTAssertEqual(model.chosenBy, .user)
        model.apply(UUID())
        XCTAssertEqual(model.activePreset.id, quiet.id, "A preset that does not exist changes nothing")
    }

    func testAutopilotReturnsToThePersonsChoiceWhenItsRuleStops() throws {
        let model = model()
        let quiet = try XCTUnwrap(model.presets.preset(named: "Quiet"))
        let heavy = try XCTUnwrap(model.presets.preset(named: "Heavy Workload"))
        model.apply(quiet.id)
        model.settings.autopilotEnabled = true
        model.automation.add(AutomationRule(trigger: .temperatureAbove(source: .cpuAverage, celsius: 85), presetID: heavy.id))

        model.monitor.ingest(Fixtures.snapshot(cpu: 60))
        XCTAssertEqual(model.activePreset.id, quiet.id)
        // The choice a moment ago holds until a different rule matches, and now one does.
        model.monitor.ingest(Fixtures.snapshot(cpu: 90))
        XCTAssertEqual(model.activePreset.id, heavy.id)
        XCTAssertNotNil(model.activeRule)
        model.monitor.ingest(Fixtures.snapshot(cpu: 60))
        XCTAssertEqual(model.activePreset.id, quiet.id)
        XCTAssertEqual(model.chosenBy, .user)
    }

    func testDeletingTheActivePresetFallsBackToAutomaticAndDropsItsRules() throws {
        let model = model()
        let quiet = try XCTUnwrap(model.presets.preset(named: "Quiet"))
        model.apply(quiet.id)
        model.automation.add(AutomationRule(trigger: .powerSource(.battery), presetID: quiet.id))
        model.deletePreset(id: quiet.id)
        XCTAssertEqual(model.activePreset.id, Preset.automaticID)
        XCTAssertNil(model.presets.preset(id: quiet.id))
        XCTAssertTrue(model.automation.rules.isEmpty)
    }

    func testAnUnsignedCopyPlansButNeverCommands() async throws {
        let recorder = CommandRecorder()
        let model = model(recorder: recorder)
        model.apply(Preset.fullBlastID)
        model.monitor.ingest(Fixtures.snapshot())
        await Fixtures.settle()
        XCTAssertEqual(model.controller.mode, .monitoring)
        XCTAssertEqual(model.controller.plan[0], .speed(5000))
        XCTAssertTrue(recorder.calls.isEmpty)
    }
}
