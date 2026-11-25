import AppKit
import Observation

/// Runs the adaptive controller on every reading, keeps what it has learned, and knows which
/// open apps are known for heavy work. It decides a share of the fans' range and nothing more:
/// the control loop turns that into speeds, within each fan's limits, and the safeguard still
/// overrides it.
@MainActor
@Observable
final class AdaptiveCoordinator {
    /// What the controller sees and asks for now, or nil when it has nothing to steer by.
    private(set) var state: AdaptiveState?
    /// The apps the person has told AirFlow about.
    private(set) var workloads: [AppWorkload]
    /// What the open apps are known for.
    private(set) var hint: WorkloadRegime?
    /// The open app that the hint comes from, for the page to name.
    private(set) var hintAppName: String?

    @ObservationIgnored private var controller: AdaptiveController
    @ObservationIgnored private let memoryFile: JSONFile<AdaptiveMemory>?
    @ObservationIgnored private let workloadsFile: JSONFile<[AppWorkload]>?
    @ObservationIgnored private var running: [String: String] = [:]
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var lastSave = Date.distantPast

    /// What was learned is written this often, and when the app quits.
    static let saveInterval: TimeInterval = 300

    init(memoryURL: URL?, workloadsURL: URL?) {
        memoryFile = memoryURL.map(JSONFile.init)
        workloadsFile = workloadsURL.map(JSONFile.init)
        let memory = memoryFile?.load()
        controller = AdaptiveController(forecaster: memory?.forecaster ?? ThermalForecaster(), scale: memory?.scale)
        workloads = workloadsFile?.load() ?? []
    }

    /// The share of each fan's range that the controller asks for now.
    var fraction: Double? { state?.fraction }

    /// Starts following which apps are open. Launching and quitting an app each change one
    /// entry, so no reading has to list the open apps.
    func startWatching() {
        guard observers.isEmpty else { return }
        for app in NSWorkspace.shared.runningApplications {
            if let bundleID = app.bundleIdentifier { running[bundleID] = app.localizedName ?? bundleID }
        }
        let center = NSWorkspace.shared.notificationCenter
        let changes: [(Notification.Name, Bool)] = [
            (NSWorkspace.didLaunchApplicationNotification, true), (NSWorkspace.didTerminateApplicationNotification, false),
        ]
        for (name, isOpen) in changes {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard let bundleID = app?.bundleIdentifier else { return }
                let appName = app?.localizedName ?? bundleID
                MainActor.assumeIsolated { self?.setRunning(bundleID, name: isOpen ? appName : nil) }
            })
        }
        refreshHint()
    }

    /// For tests and for the notifications above: an app opened (with its name) or quit (nil).
    func setRunning(_ bundleID: String, name: String?) {
        running[bundleID] = name
        refreshHint()
    }

    /// Takes one reading: the controller learns from it and decides.
    func ingest(_ snapshot: ThermalSnapshot, now: Date = Date()) {
        state = controller.step(snapshot: snapshot, hint: hint)
        if now.timeIntervalSince(lastSave) >= Self.saveInterval {
            save(now: now)
        }
    }

    func save(now: Date = Date()) {
        lastSave = now
        memoryFile?.save(AdaptiveMemory(forecaster: controller.forecaster, scale: controller.scale))
    }

    /// What an app is taken to be: the person's own entry first, then what AirFlow knows.
    func regime(forBundleID bundleID: String) -> WorkloadRegime? {
        workloads.first { $0.bundleID == bundleID }?.regime ?? KnownWorkloads.regimes[bundleID]
    }

    /// Saves what the person says an app is known for. This is the only way an app's regime
    /// changes: a suggestion from the on-device model is shown, and the person decides.
    func setWorkload(_ workload: AppWorkload) {
        var cleaned = workload
        cleaned.name = String(workload.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !cleaned.bundleID.isEmpty, cleaned.bundleID.count <= 200 else { return }
        if let index = workloads.firstIndex(where: { $0.bundleID == cleaned.bundleID }) {
            guard workloads[index] != cleaned else { return }
            workloads[index] = cleaned
        } else {
            workloads.append(cleaned)
        }
        workloadsFile?.save(workloads)
        refreshHint()
    }

    func removeWorkload(bundleID: String) {
        guard let index = workloads.firstIndex(where: { $0.bundleID == bundleID }) else { return }
        workloads.remove(at: index)
        workloadsFile?.save(workloads)
        refreshHint()
    }

    private func refreshHint() {
        let own = Dictionary(workloads.map { ($0.bundleID, $0.regime) }, uniquingKeysWith: { first, _ in first })
        hint = WorkloadHint.hint(running: running.keys, workloads: own)
        hintAppName = hint.flatMap { wanted in
            running.first { (own[$0.key] ?? KnownWorkloads.regimes[$0.key]) == wanted }?.value
        }
    }
}
