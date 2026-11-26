import AirFlowBackend
import AppIntents
import ServiceManagement
import XCTest
@testable import AirFlow

/// The model from its start to its end, with a made-up Mac, a made-up helper, and a made-up
/// record of the helper in the system.
@MainActor
final class AppModelFlowTests: XCTestCase {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "airflow-tests-\(UUID().uuidString)") ?? .standard
    }

    private func model(
        defaults: UserDefaults? = nil, source: SnapshotSource? = nil, recorder: CommandRecorder = CommandRecorder(),
        service: FakeRegistration = FakeRegistration(status: .enabled), client: HelperClient? = nil
    ) -> AppModel {
        AppModel(
            defaults: defaults ?? self.defaults(), presetsURL: nil, rulesURL: nil,
            sampler: HardwareSampler(makeSource: {
                guard let source else { throw HardwareError.cannotOpenSMC }
                return source
            }),
            commander: recorder, helper: HelperManager(isSigned: true, service: service), client: client
        )
    }

    private func wait(for condition: @MainActor () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func testAStoredPresetThatIsGoneLeavesTheFansToMacOS() {
        let stored = defaults()
        stored.set(UUID().uuidString, forKey: AppSettings.Key.activePresetID)
        let model = model(defaults: stored)
        XCTAssertEqual(model.settings.activePresetID, Preset.automaticID)
        XCTAssertEqual(model.activePreset, .automatic)

        // A preset that goes away while it is the current one reads as Automatic too.
        model.settings.activePresetID = UUID()
        XCTAssertEqual(model.activePreset, .automatic)
    }

    func testAutopilotGoesBackToThePresetThePersonChose() {
        func run(userPreset: UUID, expected: UUID) {
            let stored = defaults()
            stored.set(Preset.fullBlastID.uuidString, forKey: AppSettings.Key.activePresetID)
            stored.set(userPreset.uuidString, forKey: AppModel.userPresetKey)
            let model = model(defaults: stored)
            model.settings.autopilotEnabled = true
            let rule = AutomationRule(trigger: .temperatureAbove(source: .cpuAverage, celsius: 80), presetID: Preset.adaptiveID)
            model.automation.add(rule)
            model.monitor.ingest(Fixtures.snapshot(cpu: 92))
            XCTAssertEqual(model.activePreset.id, Preset.adaptiveID)
            XCTAssertEqual(model.chosenBy, .autopilot(ruleID: rule.id))
            XCTAssertEqual(model.activeRule, rule)
            model.monitor.ingest(Fixtures.snapshot(cpu: 50))
            XCTAssertEqual(model.activePreset.id, expected)
            XCTAssertEqual(model.chosenBy, .user)
            XCTAssertNil(model.activeRule)
        }
        run(userPreset: Preset.fullBlastID, expected: Preset.fullBlastID)
        // The preset the person chose was deleted since: the fans go back to macOS.
        run(userPreset: UUID(), expected: Preset.automaticID)
    }

    func testExportingNamesTheFileAfterOnePresetOrAfterAirFlow() throws {
        let model = model()
        let quiet = try XCTUnwrap(model.presets.preset(named: "Quiet"))
        model.beginExport(ids: [quiet.id])
        XCTAssertTrue(model.transfer.isExporting)
        XCTAssertEqual(model.transfer.exportName, "Quiet")
        XCTAssertEqual(try PresetCodec.decode(try XCTUnwrap(model.transfer.export).text).map(\.name), ["Quiet"])
        model.beginExport()
        XCTAssertEqual(model.transfer.exportName, "AirFlow Presets")
        XCTAssertEqual(try PresetCodec.decode(try XCTUnwrap(model.transfer.export).text).count, model.presets.custom.count)
        model.beginExport(ids: [quiet.id, Preset.fullBlastID, UUID()])
        XCTAssertEqual(model.transfer.exportName, "AirFlow Presets", "Two names are not one")
    }

    func testAFileIsReadNoFurtherThanAPresetsFileCanBeLong() throws {
        let folder = try Fixtures.scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = model()
        let before = model.presets.custom.count

        let large = folder.appendingPathComponent("large.yaml")
        try Data(repeating: UInt8(ascii: "a"), count: PresetCodec.maximumBytes + 1).write(to: large)
        XCTAssertThrowsError(try AppModel.text(of: large)) { XCTAssertEqual($0 as? PresetCodec.Failure, .tooLarge) }
        XCTAssertTrue(model.importPresets(from: large).isEmpty)
        XCTAssertEqual(model.transfer.message, "The file is too large to be a list of presets.")

        let full = folder.appendingPathComponent("full.yaml")
        try Data(repeating: UInt8(ascii: "a"), count: PresetCodec.maximumBytes).write(to: full)
        XCTAssertEqual(try AppModel.text(of: full).utf8.count, PresetCodec.maximumBytes, "A file of exactly the limit is read whole")

        let empty = folder.appendingPathComponent("empty.yaml")
        try Data().write(to: empty)
        XCTAssertEqual(try AppModel.text(of: empty), "")
        XCTAssertTrue(model.importPresets(from: empty).isEmpty)
        XCTAssertNotNil(model.transfer.message)

        model.transfer.message = nil
        XCTAssertTrue(model.importPresets(from: folder.appendingPathComponent("missing.yaml")).isEmpty)
        XCTAssertNotNil(model.transfer.message, "A file that is not there is reported")
        XCTAssertEqual(model.presets.custom.count, before, "Nothing was added")
    }

    func testTheModelReadsFromItsStartUntilTheAppQuits() async throws {
        let source = CountingSource()
        let helper = FakeHelper()
        let recorder = CommandRecorder()
        let model = model(source: source, recorder: recorder, client: HelperClient(connect: helper.connect))
        model.monitor.visibleSurfaces = 1
        model.start()
        await wait { model.monitor.hasLoaded }
        XCTAssertEqual(model.monitor.snapshot.summary(of: .cpu)?.average, 64)
        XCTAssertNotNil(model.adaptive.state, "The adaptive controller learns from every reading")

        model.apply(Preset.fullBlastID)
        await Fixtures.settle()
        XCTAssertTrue(model.controller.holdsAnyFan)
        XCTAssertTrue(recorder.calls.contains(.speed(0, 5000)))

        model.prepareToQuit()
        XCTAssertEqual(helper.requests, [.init(operation: AIRFLOW_OP_RESET_ALL, fan: nil, rpm: nil)], "The fans are given back before the app ends")
        let stopped = source.samples
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertEqual(source.samples, stopped, "Nothing is read after that")
    }

    func testAModelThatHoldsNoFanAsksTheHelperForNothingWhenTheAppQuits() async {
        let helper = FakeHelper()
        let model = model(client: HelperClient(connect: helper.connect))
        model.prepareToQuit()
        XCTAssertTrue(helper.requests.isEmpty)
        XCTAssertEqual(helper.connections, 0)
        // A model with no connection of its own, as in a test, ends the same way.
        let plain = self.model()
        plain.prepareToQuit()
        await plain.removeHelper()
        XCTAssertFalse(plain.controller.isControlAllowed)
    }

    func testTurningOnFanControlOpensSystemSettingsWhenMacOSWantsApproval() async {
        let service = FakeRegistration()
        let recorder = CommandRecorder()
        let model = model(recorder: recorder, service: service)
        model.monitor.ingest(Fixtures.snapshot())
        model.apply(Preset.fullBlastID)
        await Fixtures.settle()
        XCTAssertTrue(recorder.calls.isEmpty, "Without the helper nothing is sent")

        model.enableFanControl()
        XCTAssertEqual(model.helper.status, .needsApproval)
        XCTAssertEqual(service.timesSettingsOpened, 1)
        XCTAssertFalse(model.controller.isControlAllowed)

        // The person allows the helper. The next reading notices, and the fans are taken.
        service.status = .enabled
        model.monitor.ingest(Fixtures.snapshot())
        await Fixtures.settle()
        XCTAssertEqual(model.helper.status, .enabled)
        XCTAssertTrue(recorder.calls.contains(.speed(0, 5000)))
    }

    func testTurningOnFanControlThatNeedsNoApprovalStartsAtOnce() async {
        let service = FakeRegistration()
        service.statusWhenRegistered = .enabled
        let recorder = CommandRecorder()
        let model = model(recorder: recorder, service: service)
        model.monitor.ingest(Fixtures.snapshot())
        model.apply(Preset.fullBlastID)
        model.enableFanControl()
        await Fixtures.settle()
        XCTAssertEqual(service.timesSettingsOpened, 0)
        XCTAssertTrue(model.controller.isControlAllowed)
        XCTAssertTrue(recorder.calls.contains(.speed(1, 5000)))
    }

    func testRemovingTheHelperGivesTheFansBackFirst() async {
        let service = FakeRegistration(status: .enabled)
        let recorder = CommandRecorder()
        let helper = FakeHelper()
        let client = HelperClient(connect: helper.connect)
        let model = model(recorder: recorder, service: service, client: client)
        model.monitor.ingest(Fixtures.snapshot())
        model.apply(Preset.fullBlastID)
        await Fixtures.settle()
        try? await client.resetAllFans()
        XCTAssertEqual(helper.connections, 1)

        await model.removeHelper()
        XCTAssertEqual(recorder.calls.last, .resetAll)
        XCTAssertFalse(model.controller.isControlAllowed)
        XCTAssertEqual(service.removals, 1)
        XCTAssertEqual(model.helper.status, .notInstalled)
        try? await client.resetAllFans()
        XCTAssertEqual(helper.connections, 2, "The connection to the helper was closed")
    }

    func testAfterAWakeTheSpeedsAreSentAgainAndTheHelperIsLookedAtAgain() async {
        let service = FakeRegistration(status: .enabled)
        let recorder = CommandRecorder()
        let model = model(recorder: recorder, service: service)
        model.monitor.ingest(Fixtures.snapshot())
        model.apply(Preset.fullBlastID)
        await Fixtures.settle()
        let sent = recorder.calls.filter { $0 == .speed(0, 5000) }.count
        XCTAssertEqual(sent, 1)

        service.status = .requiresApproval
        model.systemDidWake()
        XCTAssertEqual(model.helper.status, .needsApproval)
        service.status = .enabled
        model.monitor.ingest(Fixtures.snapshot())
        await Fixtures.settle()
        XCTAssertEqual(recorder.calls.filter { $0 == .speed(0, 5000) }.count, 2, "The Mac may have taken the fans back in its sleep")
    }

    func testTheRunningAppsAreMeasuredWithoutAirFlowItself() async {
        let model = model()
        model.appLoadInterval = .milliseconds(30)
        let installed = AppDirectory.installed()
        let loads = await model.measureAppLoads(installed: installed)
        let names = Set(installed.map(\.name))
        XCTAssertTrue(loads.allSatisfy { names.contains($0.name) }, "Only installed apps are measured")
        XCTAssertFalse(loads.contains { $0.bundleID.hasPrefix("com.kevster.airflow") })
        XCTAssertTrue(loads.allSatisfy { $0.coresNow >= 0 && $0.cpuSeconds >= 0 })
        let none = await model.measureAppLoads(installed: [])
        XCTAssertTrue(none.isEmpty)
    }
}

@MainActor
final class FanIntentTests: XCTestCase {
    private func model(service: FakeRegistration, source: SnapshotSource? = nil) -> AppModel {
        AppModel(
            defaults: UserDefaults(suiteName: "airflow-tests-\(UUID().uuidString)") ?? .standard, presetsURL: nil, rulesURL: nil,
            sampler: HardwareSampler(makeSource: {
                guard let source else { throw HardwareError.cannotOpenSMC }
                return source
            }),
            commander: CommandRecorder(), helper: HelperManager(isSigned: true, service: service)
        )
    }

    func testAPresetIsShownToSiriByItsName() {
        let entity = PresetEntity(.fullBlast)
        XCTAssertEqual(entity.id, Preset.fullBlastID)
        XCTAssertEqual(entity.name, "Full Blast")
        XCTAssertEqual(String(localized: entity.displayRepresentation.title), "Full Blast")
    }

    func testPresetsAreFoundByIdentifierAndByPartOfTheirName() throws {
        let store = PresetStore(url: nil)
        let quiet = try XCTUnwrap(store.preset(named: "Quiet"))
        XCTAssertEqual(PresetQuery.entities(for: [quiet.id, UUID(), Preset.adaptiveID], in: store).map(\.name), ["Quiet", "Adaptive"])
        XCTAssertEqual(PresetQuery.entities(matching: "QUI", in: store).map(\.name), ["Quiet"])
        XCTAssertTrue(PresetQuery.entities(matching: "no such preset", in: store).isEmpty)
        XCTAssertEqual(PresetQuery.entities(matching: "", in: store).map(\.id), store.presets.map(\.id))
    }

    func testApplyingAPresetSaysWhatHappened() throws {
        let off = model(service: FakeRegistration())
        let quiet = try XCTUnwrap(off.presets.preset(named: "Quiet"))
        XCTAssertEqual(ApplyPresetIntent.apply(PresetEntity(quiet), to: off), "AirFlow is set to Quiet, but fan control isn't turned on.")
        XCTAssertEqual(off.activePreset.id, quiet.id)
        XCTAssertEqual(off.chosenBy, .siri)

        let on = model(service: FakeRegistration(status: .enabled))
        XCTAssertEqual(ApplyPresetIntent.apply(PresetEntity(.fullBlast), to: on), "AirFlow is using Full Blast.")
        XCTAssertEqual(on.activePreset.id, Preset.fullBlastID)

        let gone = PresetEntity(Preset(name: "Deleted", icon: .moon, fallback: .automatic))
        XCTAssertEqual(ApplyPresetIntent.apply(gone, to: on), "AirFlow no longer has a preset named Deleted.")
        XCTAssertEqual(on.activePreset.id, Preset.fullBlastID, "Nothing changed")
    }

    func testTheFanStatusReadsTheMacFirstWhenNothingHasBeenReadYet() async {
        let source = CountingSource()
        let model = model(service: FakeRegistration(), source: source)
        let first = await FanStatusIntent.status(of: model)
        XCTAssertEqual(first, FanStatus.sentence(snapshot: model.monitor.snapshot, presetName: "Automatic", format: model.settings.format))
        XCTAssertTrue(first.hasSuffix("The preset is Automatic."))
        XCTAssertEqual(source.samples, 1)
        _ = await FanStatusIntent.status(of: model)
        XCTAssertEqual(source.samples, 1, "A model that has readings does not read again")
    }

    func testTheIntentsWorkOnTheAppsOwnModel() async throws {
        let shared = AppModel.shared
        defer { shared.apply(Preset.automaticID) }
        let query = PresetQuery()
        let found = try await query.entities(for: [Preset.adaptiveID])
        XCTAssertEqual(found.map(\.name), ["Adaptive"])
        let matching = try await query.entities(matching: "blast")
        XCTAssertEqual(matching.map(\.id), [Preset.fullBlastID])
        let suggested = try await query.suggestedEntities()
        XCTAssertEqual(suggested.map(\.id), shared.presets.presets.map(\.id))

        let apply = ApplyPresetIntent()
        apply.preset = PresetEntity(.fullBlast)
        _ = try await apply.perform()
        XCTAssertEqual(shared.activePreset.id, Preset.fullBlastID)
        XCTAssertEqual(shared.chosenBy, .siri)
        _ = try await FanStatusIntent().perform()
        XCTAssertTrue(shared.monitor.hasLoaded, "Asking for the status reads the Mac")

        _ = ApplyPresetIntent.parameterSummary
        XCTAssertEqual(AirFlowShortcuts.appShortcuts.count, 2)
    }
}

final class ProposalEdgeTests: XCTestCase {
    func testARuleThatCannotBeMadeSaysWhy() {
        XCTAssertEqual(RuleProposal.Failure.unknownPreset("Loud").errorDescription, "There's no preset named “Loud”.")
        XCTAssertEqual(RuleProposal.Failure.unknownApp("Photoshop").errorDescription, "AirFlow can't find an app named “Photoshop”.")
        XCTAssertEqual(RuleProposal.Failure.unknownApp("").errorDescription, "The rule doesn't name an app.")
        XCTAssertEqual(RuleProposal.Failure.emptyTimeRange.errorDescription, "The rule's start and end times are the same.")
    }

    func testAnAppListedTwiceCountsOnce() {
        let installed = [AppDirectory.App(bundleID: "a", name: "First"), AppDirectory.App(bundleID: "a", name: "Second")]
        let before = [
            AppUsage(bundlePath: "/Applications/A.app", cpuSeconds: 10, runningSeconds: 100),
            AppUsage(bundlePath: "/Applications/A.app", cpuSeconds: 90, runningSeconds: 100),
        ]
        let after = [AppUsage(bundlePath: "/Applications/A.app", cpuSeconds: 12, runningSeconds: 102)]
        let loads = AppLoad.loads(before: before, after: after, seconds: 2, installed: installed, own: "x") { _ in "a" }
        XCTAssertEqual(loads.map(\.name), ["First"], "The first name is the one that counts")
        XCTAssertEqual(loads[0].coresNow, 1, accuracy: 1e-9, "And the first earlier reading: 2 seconds over 2")
    }

    func testAReadingWithNoFanCountsAsAFanAtRest() throws {
        let start = Date(timeIntervalSince1970: 0)
        let history = (0..<6).map { index in
            HistoryPoint(date: start.addingTimeInterval(Double(index) * 60), cpu: 60, gpu: nil, fanFractions: index < 3 ? [] : [0.2, 0.6])
        }
        let digest = try XCTUnwrap(ThermalDigest(history: history, presetName: "Quiet"))
        XCTAssertEqual(digest.fanAverage, 0.3, accuracy: 1e-9)
        XCTAssertEqual(digest.fanHigh, 0.6)
        XCTAssertEqual(digest.minutes, 5)
    }

    func testAPresetsFileIsReadAsTextAndWrittenAsIs() throws {
        let document = try PresetsDocument(contents: Data("airflow: 2\npresets: []\n".utf8))
        XCTAssertEqual(document.text, "airflow: 2\npresets: []\n")
        XCTAssertEqual(document.contents, Data(document.text.utf8))
        XCTAssertEqual(PresetsDocument(text: "x").contents, Data("x".utf8))
        XCTAssertThrowsError(try PresetsDocument(contents: nil)) { XCTAssertEqual($0 as? PresetCodec.Failure, .tooLarge) }
        XCTAssertThrowsError(try PresetsDocument(contents: Data(count: PresetCodec.maximumBytes + 1))) {
            XCTAssertEqual($0 as? PresetCodec.Failure, .tooLarge)
        }
        XCTAssertEqual(try PresetsDocument(contents: Data(count: PresetCodec.maximumBytes)).text.utf8.count, PresetCodec.maximumBytes)
        XCTAssertEqual(PresetsDocument.readableContentTypes, [PresetCodec.contentType])
    }
}
