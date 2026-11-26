import AppIntents
import XCTest
@testable import AirFlow

/// What the coordinators do with the system's notifications, files that go wrong, and the
/// model's own start and end.
@MainActor
final class WatchingTests: XCTestCase {
    private func note(_ name: Notification.Name, app: NSRunningApplication? = .current) -> Notification {
        Notification(name: name, object: nil, userInfo: app.map { [NSWorkspace.applicationUserInfoKey: $0] })
    }

    func testAnAppIsKnownByItsIdentifierAndShownByItsName() throws {
        XCTAssertNil(OpenApp(bundleID: nil, name: "Nameless").named, "Nothing can refer to an app with no identifier")
        let unnamed = try XCTUnwrap(OpenApp(bundleID: "com.example.tool", name: nil).named)
        XCTAssertEqual(unnamed.bundleID, "com.example.tool")
        XCTAssertEqual(unnamed.name, "com.example.tool", "An app with no name is shown by its identifier")
        let named = try XCTUnwrap(OpenApp(bundleID: "com.example.tool", name: "Tool").named)
        XCTAssertEqual(named.name, "Tool")

        let own = OpenApp(NSRunningApplication.current)
        XCTAssertEqual(own.bundleID, Bundle.main.bundleIdentifier)
        XCTAssertEqual(OpenApp(note(NSWorkspace.didLaunchApplicationNotification)), own)
        XCTAssertEqual(OpenApp(note(NSWorkspace.didLaunchApplicationNotification, app: nil)), OpenApp(bundleID: nil, name: nil))
        XCTAssertEqual(OpenApp(nil), OpenApp(bundleID: nil, name: nil))
    }

    func testAutopilotFollowsTheAppInFrontButNotAirFlowItself() throws {
        let host = try XCTUnwrap(Bundle.main.bundleIdentifier)
        let center = NotificationCenter()
        let coordinator = AutomationCoordinator(url: nil)
        XCTAssertNil(coordinator.context(snapshot: Fixtures.snapshot()).frontmostBundleID)
        coordinator.startWatching(center: center, frontmost: "com.apple.finder", own: "com.kevster.airflow")
        XCTAssertEqual(coordinator.context(snapshot: Fixtures.snapshot()).frontmostBundleID, "com.apple.finder")

        center.post(note(NSWorkspace.didActivateApplicationNotification))
        XCTAssertEqual(coordinator.context(snapshot: Fixtures.snapshot()).frontmostBundleID, host)
        // A notification about no app changes nothing.
        center.post(note(NSWorkspace.didActivateApplicationNotification, app: nil))
        XCTAssertEqual(coordinator.context(snapshot: Fixtures.snapshot()).frontmostBundleID, host)
        // Watching twice adds no second watcher and does not read the app in front again.
        coordinator.startWatching(center: center, frontmost: "com.apple.Safari", own: nil)
        XCTAssertEqual(coordinator.context(snapshot: Fixtures.snapshot()).frontmostBundleID, host)

        // AirFlow coming forward is not a change: opening it to look at a rule must not end the rule.
        let second = AutomationCoordinator(url: nil)
        second.startWatching(center: center, frontmost: "com.apple.finder", own: host)
        center.post(note(NSWorkspace.didActivateApplicationNotification))
        XCTAssertEqual(second.context(snapshot: Fixtures.snapshot()).frontmostBundleID, "com.apple.finder")
    }

    func testTheContextHasTheMinuteOfTheDayAndThePowerSource() throws {
        let coordinator = AutomationCoordinator(url: nil)
        var parts = DateComponents()
        parts.year = 2026
        parts.month = 3
        parts.day = 9
        parts.hour = 22
        parts.minute = 41
        let evening = try XCTUnwrap(Calendar.current.date(from: parts))
        let snapshot = Fixtures.snapshot(cpu: 71)
        let context = coordinator.context(snapshot: snapshot, now: evening)
        XCTAssertEqual(context.minuteOfDay, 22 * 60 + 41)
        XCTAssertEqual(context.snapshot, snapshot)
        XCTAssertEqual(context.powerSource, Backend.isOnBattery ? .battery : .adapter)
        XCTAssertEqual(AutomationCoordinator.currentPowerSource(), context.powerSource)
    }

    func testTheHintFollowsTheAppsThatOpenAndQuit() throws {
        let host = try XCTUnwrap(Bundle.main.bundleIdentifier)
        let center = NotificationCenter()
        let coordinator = AdaptiveCoordinator(memoryURL: nil, workloadsURL: nil)
        coordinator.setWorkload(AppWorkload(bundleID: host, name: "AirFlow Under Test", regime: .sustained))
        coordinator.setWorkload(AppWorkload(bundleID: "com.example.editor", name: "Editor", regime: .bursty))
        XCTAssertNil(coordinator.hint, "No app is open yet")

        coordinator.startWatching(center: center, open: [
            OpenApp(bundleID: "com.example.editor", name: nil), OpenApp(bundleID: nil, name: "Nameless"),
            OpenApp(bundleID: "com.example.notes", name: "Notes"),
        ])
        XCTAssertEqual(coordinator.hint, .bursty)
        XCTAssertEqual(coordinator.hintAppName, "com.example.editor", "An app with no name is shown by its identifier")

        center.post(note(NSWorkspace.didLaunchApplicationNotification))
        XCTAssertEqual(coordinator.hint, .sustained, "The heaviest open app decides")
        XCTAssertEqual(coordinator.hintAppName, NSRunningApplication.current.localizedName)
        center.post(note(NSWorkspace.didTerminateApplicationNotification, app: nil))
        XCTAssertEqual(coordinator.hint, .sustained, "A notification about no app changes nothing")
        center.post(note(NSWorkspace.didTerminateApplicationNotification))
        XCTAssertEqual(coordinator.hint, .bursty)

        // Watching twice adds no second watcher and does not list the open apps again.
        coordinator.startWatching(center: center, open: [OpenApp(bundleID: host, name: "Again")])
        XCTAssertEqual(coordinator.hint, .bursty)
    }

    func testAStoredAppThatIsListedTwiceCountsOnce() throws {
        let folder = try Fixtures.scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("workloads.json")
        JSONFile(url: url).save([
            AppWorkload(bundleID: "com.example.editor", name: "Editor", regime: .bursty),
            AppWorkload(bundleID: "com.example.editor", name: "Editor Again", regime: .sustained),
        ])
        let coordinator = AdaptiveCoordinator(memoryURL: nil, workloadsURL: url)
        coordinator.setRunning("com.example.editor", name: "Editor")
        XCTAssertEqual(coordinator.hint, .bursty, "The first entry is the one that counts")
        XCTAssertEqual(coordinator.regime(forBundleID: "com.example.editor"), .bursty)

        // Saving the same entry again changes nothing, and a changed one replaces it.
        coordinator.setWorkload(AppWorkload(bundleID: "com.example.editor", name: " Editor ", regime: .bursty))
        XCTAssertEqual(coordinator.workloads.count, 2)
        coordinator.setWorkload(AppWorkload(bundleID: "com.example.editor", name: "Editor", regime: .light))
        XCTAssertEqual(coordinator.workloads.first?.regime, .light)
    }
}

@MainActor
final class RuleAndFileTests: XCTestCase {
    func testARuleCanBeChangedAndDeleted() throws {
        let folder = try Fixtures.scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("rules.json")
        let coordinator = AutomationCoordinator(url: url)
        let preset = UUID()
        var rule = AutomationRule(trigger: .powerSource(.battery), presetID: preset)
        let other = AutomationRule(trigger: .powerSource(.adapter), presetID: preset)
        coordinator.add(rule)
        coordinator.add(other)

        rule.isEnabled = false
        coordinator.update(rule)
        XCTAssertEqual(coordinator.rules, [rule, other])
        XCTAssertEqual(AutomationCoordinator(url: url).rules, [rule, other], "The change is stored")

        // A rule that is the same as before, or that is not there, changes nothing.
        let written = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: url)
        coordinator.update(rule)
        coordinator.update(AutomationRule(trigger: .powerSource(.battery), presetID: preset))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "Nothing was written")
        try written.write(to: url)

        coordinator.delete(id: rule.id)
        XCTAssertEqual(coordinator.rules, [other])
        XCTAssertEqual(AutomationCoordinator(url: url).rules, [other])
    }

    func testAStoredFileThatCannotBeReadIsSetAside() throws {
        let folder = try Fixtures.scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("rules.json")
        let aside = url.appendingPathExtension("unreadable")
        let file = JSONFile<[AutomationRule]>(url: url)
        XCTAssertNil(file.load(), "No file is no value, and nothing is set aside")
        XCTAssertFalse(FileManager.default.fileExists(atPath: aside.path))

        try Data("an older damaged file".utf8).write(to: aside)
        let damaged = Data("{ not json".utf8)
        try damaged.write(to: url)
        XCTAssertNil(file.load())
        XCTAssertEqual(try Data(contentsOf: aside), damaged, "The file a person may want back replaces the older one")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(AutomationCoordinator(url: url).rules.isEmpty)
    }

    func testAFileThatCannotBeWrittenLeavesTheAppRunning() throws {
        let folder = try Fixtures.scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // A file where the folder should be: nothing can be written under it.
        let blocker = folder.appendingPathComponent("blocker")
        try Data("x".utf8).write(to: blocker)
        let rules = blocker.appendingPathComponent("rules.json")
        JSONFile<[AutomationRule]>(url: rules).save([])
        XCTAssertNil(JSONFile<[AutomationRule]>(url: rules).load())

        let presets = blocker.appendingPathComponent("presets.yaml")
        PresetFile(url: presets).save([Preset(name: "Quiet", icon: .moon, fallback: .automatic)])
        XCTAssertNil(PresetFile(url: presets).load())
        XCTAssertEqual(try Data(contentsOf: blocker), Data("x".utf8))
    }

    func testAirFlowKeepsItsFilesInItsOwnFolderOfApplicationSupport() {
        let url = JSONFile<[AutomationRule]>.inApplicationSupport("Debug/rules.json")
        XCTAssertTrue(url.path.hasSuffix("/Library/Application Support/AirFlow/Debug/rules.json"), url.path)
    }

    func testThePersonsPresetsCanBePutInAnotherOrder() throws {
        let folder = try Fixtures.scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("presets.yaml")
        let store = PresetStore(url: url)
        let names = store.custom.map(\.name)
        XCTAssertGreaterThanOrEqual(names.count, 3)
        store.move(fromOffsets: IndexSet(integer: 0), toOffset: names.count)
        XCTAssertEqual(store.custom.map(\.name), Array(names.dropFirst()) + [names[0]])
        XCTAssertEqual(PresetStore(url: url).custom.map(\.name), store.custom.map(\.name), "The order is stored")
    }

    func testInstalledAppsAreFoundInTheFoldersGiven() throws {
        let folder = try Fixtures.scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        func makeApp(_ name: String, identifier: String?) throws {
            let contents = folder.appendingPathComponent("\(name).app/Contents", isDirectory: true)
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            var info: [String: Any] = ["CFBundleName": name]
            info["CFBundleIdentifier"] = identifier
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        }
        try makeApp("zeta", identifier: "com.example.zeta")
        try makeApp("Alpha", identifier: "com.example.alpha")
        try makeApp("Nameless", identifier: nil)
        try Data().write(to: folder.appendingPathComponent("notes.txt"))
        let found = AppDirectory.installed(in: [folder.path, folder.path + "/missing"])
        XCTAssertEqual(found, [
            AppDirectory.App(bundleID: "com.example.alpha", name: "Alpha"), AppDirectory.App(bundleID: "com.example.zeta", name: "zeta"),
        ], "In the order of their names, whatever their case")
        XCTAssertEqual(found.map(\.id), ["com.example.alpha", "com.example.zeta"])
        XCTAssertTrue(AppDirectory.installed().contains { $0.bundleID == "com.apple.calculator" }, "The Mac's own apps are found")
    }

    func testACopyThatDoesNotUpdateItselfHasNothingToCheck() {
        let updates = Updates.shared
        XCTAssertFalse(updates.isAvailable, "A test never starts the updater")
        XCTAssertFalse(updates.canCheck)
        updates.checksAutomatically = true
        XCTAssertFalse(updates.checksAutomatically)
        updates.check()
        XCTAssertFalse(updates.isAvailable)
    }
}

/// A reader that says how many times it was asked, and can stop working.
final class CountingSource: SnapshotSource, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var samples: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func snapshot(at date: Date, groups: Set<SensorGroup>) -> ThermalSnapshot {
        lock.lock()
        count += 1
        lock.unlock()
        return Fixtures.snapshot(cpu: 64, date: date)
    }
}

@MainActor
final class SamplingLoopTests: XCTestCase {
    private func wait(for condition: @MainActor () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func testTheSamplerOpensItsReaderOnceAndTriesAgainAfterAFailure() async throws {
        let source = CountingSource()
        var attempts = 0
        let sampler = HardwareSampler(makeSource: {
            attempts += 1
            if attempts == 1 { throw HardwareError.cannotOpenSMC }
            return source
        })
        do {
            _ = try await sampler.sample()
            XCTFail("The first attempt has no reader")
        } catch {
            XCTAssertEqual(error as? HardwareError, .cannotOpenSMC)
        }
        let first = try await sampler.sample()
        let second = try await sampler.sample(groups: [.cpu])
        XCTAssertEqual(first.summary(of: .cpu)?.average, 64)
        XCTAssertEqual(second.fans.count, 2)
        XCTAssertEqual(source.samples, 2)
        XCTAssertEqual(attempts, 2, "A reader that opened is kept")
    }

    func testTheMonitorReadsUntilItIsStopped() async {
        let source = CountingSource()
        let monitor = ThermalMonitor(sampler: HardwareSampler(makeSource: { source }))
        var seen = 0
        monitor.onSnapshot = { _ in seen += 1 }
        monitor.visibleSurfaces = 1
        monitor.start()
        monitor.start()
        await wait { monitor.hasLoaded }
        XCTAssertTrue(monitor.isAvailable)
        XCTAssertEqual(monitor.snapshot.summary(of: .cpu)?.average, 64)
        XCTAssertEqual(seen, 1, "Starting twice runs one loop")
        monitor.stop()
        monitor.stop()
        let stopped = source.samples
        try? await Task.sleep(for: .milliseconds(1200))
        XCTAssertEqual(source.samples, stopped, "A stopped monitor reads nothing")
    }

    func testAMonitorThatIsGoneStopsReading() async {
        let source = CountingSource()
        var monitor: ThermalMonitor? = ThermalMonitor(sampler: HardwareSampler(makeSource: { source }))
        monitor?.visibleSurfaces = 1
        monitor?.start()
        await wait { source.samples > 0 }
        monitor = nil
        try? await Task.sleep(for: .milliseconds(1300))
        let after = source.samples
        try? await Task.sleep(for: .milliseconds(1200))
        XCTAssertEqual(source.samples, after)
    }

    func testOldReadingsAreDroppedFromTheHistoryAsItGrows() {
        let monitor = ThermalMonitor(sampler: HardwareSampler(makeSource: { throw HardwareError.cannotOpenSMC }))
        let start = Date(timeIntervalSince1970: 1_000_000)
        for second in 0..<2500 {
            monitor.ingest(Fixtures.snapshot(cpu: 50, date: start.addingTimeInterval(Double(second))))
        }
        XCTAssertEqual(monitor.history.count, Int(ThermalMonitor.historyDuration) + 1)
        XCTAssertEqual(monitor.history.first?.date, start.addingTimeInterval(2499 - ThermalMonitor.historyDuration))
        XCTAssertEqual(monitor.history.last?.date, start.addingTimeInterval(2499))
    }

    func testAHistoryMadeUpForMeasuringIsFifteenMinutesLong() {
        let monitor = ThermalMonitor(sampler: HardwareSampler(makeSource: { throw HardwareError.cannotOpenSMC }))
        let now = Date(timeIntervalSince1970: 2_000_000)
        monitor.ingest(Fixtures.snapshot(date: now.addingTimeInterval(-5000)))
        monitor.fillHistoryForMeasuring(now: now)
        XCTAssertEqual(monitor.history.count, Int(ThermalMonitor.historyDuration))
        XCTAssertEqual(monitor.history.first?.date, now.addingTimeInterval(-ThermalMonitor.historyDuration))
        XCTAssertEqual(monitor.history.last?.date, now.addingTimeInterval(-1))
        XCTAssertTrue(monitor.history.allSatisfy { ($0.cpu ?? 0) >= 53 && ($0.cpu ?? 0) <= 77 && $0.fanFractions.count == 2 })
    }

    func testTheGroupsAreNumberedAndSortedAsTheBackendListsThem() {
        XCTAssertEqual(SensorGroup.allCases.map(\.backendCode), Array(0..<UInt8(SensorGroup.allCases.count)))
        XCTAssertEqual(SensorGroup.allCases.map(\.sortIndex), Array(0..<SensorGroup.allCases.count))
        XCTAssertEqual(SensorGroup.allCases.map { SensorGroup(backendCode: $0.backendCode) }, SensorGroup.allCases)
        XCTAssertEqual(SensorGroup(backendCode: 200), .other)
    }
}
