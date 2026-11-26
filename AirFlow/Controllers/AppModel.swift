import Foundation
import Observation

/// Owns every long-lived object and is the one place that changes the active preset.
@MainActor
@Observable
final class AppModel {
    /// Who chose the active preset.
    enum ChosenBy: Equatable {
        case user
        case autopilot(ruleID: UUID)
        case siri
    }

    static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    static let shared = AppModel.makeShared()

    let settings: AppSettings
    let presets: PresetStore
    let monitor: ThermalMonitor
    let controller: FanController
    let automation: AutomationCoordinator
    let adaptive: AdaptiveCoordinator
    let intelligence: IntelligenceService
    let helper: HelperManager

    private(set) var chosenBy: ChosenBy = .user
    /// What the window should do about importing and exporting presets.
    var transfer = PresetTransfer()
    /// The size of a sheet that is open over the window, or nil. A sheet sets it
    /// (`castsSheetShadow`), and the window draws the sheet's shadow, because macOS gives a sheet none.
    var openSheetSize: CGSize?

    @ObservationIgnored private let client: HelperClient?
    @ObservationIgnored private let defaults: UserDefaults
    /// The preset the person chose themselves. Autopilot returns to it when no rule matches.
    @ObservationIgnored private var userPresetID: UUID

    static let userPresetKey = "userPresetID"

    init(
        defaults: UserDefaults, presetsURL: URL?, rulesURL: URL?, adaptiveURL: URL? = nil, workloadsURL: URL? = nil,
        sampler: HardwareSampler, commander: FanCommanding, helper: HelperManager, client: HelperClient? = nil
    ) {
        self.defaults = defaults
        self.client = client
        settings = AppSettings(defaults: defaults)
        presets = PresetStore(url: presetsURL)
        monitor = ThermalMonitor(sampler: sampler)
        controller = FanController(commander: commander)
        automation = AutomationCoordinator(url: rulesURL)
        adaptive = AdaptiveCoordinator(memoryURL: adaptiveURL, workloadsURL: workloadsURL)
        intelligence = IntelligenceService()
        self.helper = helper
        userPresetID = defaults.string(forKey: Self.userPresetKey).flatMap(UUID.init) ?? settings.activePresetID
        if presets.preset(id: settings.activePresetID) == nil {
            settings.activePresetID = Preset.automaticID
        }
        monitor.onSnapshot = { [weak self] snapshot in self?.handle(snapshot) }
    }

    private static func makeShared() -> AppModel {
        let client = HelperClient()
        if isRunningTests {
            // The tests load into the app. This instance must not touch the person's presets,
            // preferences, or fans.
            let suite = "com.kevster.airflow.tests.\(UUID().uuidString)"
            return AppModel(
                defaults: UserDefaults(suiteName: suite) ?? .standard, presetsURL: nil, rulesURL: nil,
                sampler: HardwareSampler(makeSource: { throw HardwareError.cannotOpenSMC }),
                commander: client, helper: HelperManager(isSigned: false), client: nil
            )
        }
        let folder = Bundle.main.bundleIdentifier?.hasSuffix(".debug") == true ? "Debug/" : ""
        return AppModel(
            defaults: .standard,
            presetsURL: JSONFile<[Preset]>.inApplicationSupport(folder + "presets.yaml"),
            rulesURL: JSONFile<[AutomationRule]>.inApplicationSupport(folder + "rules.json"),
            adaptiveURL: JSONFile<AdaptiveMemory>.inApplicationSupport(folder + "adaptive.json"),
            workloadsURL: JSONFile<[AppWorkload]>.inApplicationSupport(folder + "workloads.json"),
            sampler: HardwareSampler(), commander: client, helper: HelperManager(), client: client
        )
    }

    var activePreset: Preset {
        presets.preset(id: settings.activePresetID) ?? .automatic
    }

    /// The rule that chose the active preset, when Autopilot did.
    var activeRule: AutomationRule? {
        guard case .autopilot(let ruleID) = chosenBy else { return nil }
        return automation.rules.first { $0.id == ruleID }
    }

    func start() {
        guard !Self.isRunningTests else { return }
        automation.startWatching()
        adaptive.startWatching()
        monitor.start()
    }

    /// Makes a preset the active one and sends its commands at once.
    func apply(_ id: UUID, by source: ChosenBy = .user) {
        guard presets.preset(id: id) != nil else { return }
        settings.activePresetID = id
        chosenBy = source
        if case .autopilot = source {} else {
            userPresetID = id
            defaults.set(id.uuidString, forKey: Self.userPresetKey)
            automation.userChosePreset()
        }
        runControlLoop()
        // The Dock icon's fan has the rainbow while Adaptive is the current preset.
        if !Self.isRunningTests { DockIcon.update() }
    }

    /// Asks the window to save presets to a YAML file: the ones named, or all of them.
    func beginExport(ids: [UUID]? = nil) {
        do {
            let names = ids?.compactMap { presets.preset(id: $0)?.name } ?? []
            transfer.export = PresetsDocument(text: try presets.exportText(ids: ids))
            transfer.exportName = names.count == 1 ? names[0] : "AirFlow Presets"
            transfer.isExporting = true
        } catch {
            transfer.message = "AirFlow couldn't write the presets. \(error.localizedDescription)"
        }
    }

    /// Reads presets from a YAML file a person chose and returns the ones added.
    @discardableResult
    func importPresets(from url: URL) -> [Preset] {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= PresetCodec.maximumBytes else { throw PresetCodec.Failure.tooLarge }
            let added = try presets.importText(String(decoding: try Data(contentsOf: url), as: UTF8.self))
            Task { AirFlowShortcuts.updateAppShortcutParameters() }
            return added
        } catch {
            transfer.message = error.localizedDescription
            return []
        }
    }

    func deletePreset(id: UUID) {
        automation.removeRules(forPreset: id)
        if userPresetID == id { userPresetID = Preset.automaticID }
        if settings.activePresetID == id { apply(Preset.automaticID) }
        presets.delete(id: id)
    }

    /// Runs the control loop on the readings already in hand, after a change to the active
    /// preset or to one of its rules.
    func runControlLoop() {
        guard monitor.hasLoaded, monitor.isAvailable else { return }
        tickController(monitor.snapshot)
    }

    func enableFanControl() {
        helper.install()
        // macOS wants the person to allow AirFlow in System Settings. Opening the page for them
        // saves the search for it.
        if helper.status == .needsApproval { openFanControlSettings() }
        controller.isControlAllowed = helper.status.allowsControl
        runControlLoop()
    }

    /// Opens the page of System Settings where AirFlow is allowed, with a panel beside it that
    /// says what to do there.
    func openFanControlSettings() {
        guard !Self.isRunningTests else { return }
        helper.openLoginItems()
        SettingsGuide.shared.show(model: self)
    }

    func removeHelper() async {
        await controller.releaseAll()
        controller.isControlAllowed = false
        client?.disconnect()
        await helper.remove()
    }

    func systemDidWake() {
        controller.forgetSentCommands()
        helper.refresh()
    }

    /// Returns the fans to the system before the app ends. The helper does the same when the
    /// connection closes, so this only makes it prompt.
    func prepareToQuit() {
        monitor.stop()
        adaptive.save()
        if controller.holdsAnyFan {
            client?.resetAllFansBeforeQuitting()
        }
        client?.disconnect()
    }

    /// How long the two readings of the running apps are apart.
    static let appLoadInterval: Duration = .milliseconds(1500)

    /// What each installed app that is running uses: two readings of the running apps, a
    /// moment apart, off the main thread. AirFlow itself is left out.
    func measureAppLoads(installed: [AppDirectory.App]) async -> [AppLoad] {
        let before = await Task.detached { Backend.appUsage() }.value
        try? await Task.sleep(for: Self.appLoadInterval)
        let after = await Task.detached { Backend.appUsage() }.value
        let seconds = Double(Self.appLoadInterval.components.seconds) + Double(Self.appLoadInterval.components.attoseconds) / 1e18
        return AppLoad.loads(
            before: before, after: after, seconds: seconds, installed: installed, own: Log.subsystem,
            bundleID: { Bundle(path: $0)?.bundleIdentifier }
        )
    }

    /// The parts that a preset's fan or a rule follows, so the monitor reads them on every
    /// sample. A single sensor counts as its part. One that the Mac does not report counts as
    /// every part, because its part is not known.
    static func followedGroups(presets: [Preset], rules: [AutomationRule], snapshot: ThermalSnapshot) -> Set<SensorGroup> {
        var sources: [SensorSource] = rules.compactMap { rule in
            if case .temperatureAbove(let source, _) = rule.trigger { return source }
            return nil
        }
        for preset in presets {
            for control in [preset.fallback] + preset.controls.values {
                if case .sensorBased(let rule) = control { sources.append(rule.source) }
            }
        }
        var groups: Set<SensorGroup> = []
        for source in sources {
            switch source {
            case .group(let group, _): groups.insert(group)
            case .key(let key):
                guard let sensor = snapshot.sensor(key: key) else { return Set(SensorGroup.allCases) }
                groups.insert(sensor.group)
            }
        }
        return groups
    }

    private func handle(_ snapshot: ThermalSnapshot) {
        monitor.followedGroups = Self.followedGroups(presets: presets.presets, rules: automation.rules, snapshot: snapshot)
        if helper.status == .needsApproval || helper.status == .notInstalled { helper.refresh() }
        // The adaptive controller learns from every reading, whichever preset is active, so
        // its forecast is ready when the person chooses it.
        adaptive.ingest(snapshot)
        let decision = automation.evaluate(
            context: automation.context(snapshot: snapshot),
            presets: presets.presets,
            isEnabled: settings.autopilotEnabled
        )
        switch decision {
        case .keep:
            break
        case .apply(let presetID, let ruleID):
            settings.activePresetID = presetID
            chosenBy = .autopilot(ruleID: ruleID)
        case .revert:
            settings.activePresetID = presets.preset(id: userPresetID)?.id ?? Preset.automaticID
            chosenBy = .user
        }
        tickController(snapshot)
    }

    private func tickController(_ snapshot: ThermalSnapshot) {
        controller.isControlAllowed = helper.status.allowsControl
        controller.tick(
            snapshot: snapshot, preset: activePreset,
            safeguardEnabled: settings.safeguardEnabled, safeguardLimit: settings.safeguardLimit,
            adaptiveFraction: adaptive.fraction
        )
    }
}
