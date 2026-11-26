import AppKit
import Observation

/// What Autopilot decided on one pass.
enum AutopilotDecision: Equatable {
    /// Leave the active preset alone.
    case keep
    /// A rule started to match: apply its preset.
    case apply(presetID: UUID, ruleID: UUID)
    /// No rule matches anymore: go back to the preset the person chose.
    case revert
}

/// Keeps the rules, watches what they depend on, and decides when Autopilot changes the preset.
@MainActor
@Observable
final class AutomationCoordinator {
    private(set) var rules: [AutomationRule]
    /// The rule that matches now, whether or not Autopilot is on.
    private(set) var matchedRuleID: UUID?
    /// True while the person's own choice holds. It ends when a different rule starts to match.
    private(set) var isHeldByUser = false

    @ObservationIgnored private let file: JSONFile<[AutomationRule]>?
    @ObservationIgnored private var engine = AutomationEngine()
    @ObservationIgnored private var appliedRuleID: UUID?
    @ObservationIgnored private var heldRuleID: UUID?
    @ObservationIgnored private var frontmostBundleID: String?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?

    init(url: URL?) {
        file = url.map(JSONFile.init)
        rules = file?.load() ?? []
    }

    /// Starts following the frontmost app. AirFlow coming forward is not a change of context,
    /// because opening AirFlow to look at a rule must not end the rule.
    /// - Parameters:
    ///   - center: where the workspace says that an app came forward.
    ///   - frontmost: the app in front now.
    ///   - own: AirFlow's own identifier.
    func startWatching(
        center: NotificationCenter = NSWorkspace.shared.notificationCenter,
        frontmost: String? = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
        own: String? = Bundle.main.bundleIdentifier
    ) {
        guard activationObserver == nil else { return }
        frontmostBundleID = frontmost
        activationObserver = center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let bundleID = OpenApp(note).bundleID, bundleID != own else { return }
            MainActor.assumeIsolated { self?.frontmostBundleID = bundleID }
        }
    }

    func context(snapshot: ThermalSnapshot, now: Date = Date()) -> AutomationContext {
        let calendar = Calendar.current
        return AutomationContext(
            frontmostBundleID: frontmostBundleID,
            powerSource: Self.currentPowerSource(),
            minuteOfDay: calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now),
            snapshot: snapshot
        )
    }

    /// Judges the rules against the context and says what Autopilot should do, if it is on.
    func evaluate(context: AutomationContext, presets: [Preset], isEnabled: Bool) -> AutopilotDecision {
        let matched = engine.match(rules: rules, context: context, presets: Set(presets.map(\.id)))
        if matchedRuleID != matched?.id { matchedRuleID = matched?.id }
        guard isEnabled else {
            appliedRuleID = nil
            isHeldByUser = false
            return .keep
        }
        if isHeldByUser {
            guard matched?.id != heldRuleID else { return .keep }
            isHeldByUser = false
            appliedRuleID = nil
        }
        if let matched {
            guard appliedRuleID != matched.id else { return .keep }
            appliedRuleID = matched.id
            return .apply(presetID: matched.presetID, ruleID: matched.id)
        }
        guard appliedRuleID != nil else { return .keep }
        appliedRuleID = nil
        return .revert
    }

    /// The person chose a preset themselves. Their choice holds until the context changes.
    func userChosePreset() {
        isHeldByUser = true
        heldRuleID = matchedRuleID
    }

    func add(_ rule: AutomationRule) {
        rules.append(rule)
        save()
    }

    func update(_ rule: AutomationRule) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }), rules[index] != rule else { return }
        rules[index] = rule
        save()
    }

    func delete(id: UUID) {
        rules.removeAll { $0.id == id }
        save()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        rules.move(fromOffsets: source, toOffset: destination)
        save()
    }

    /// Drops the rules that point at a preset that no longer exists.
    func removeRules(forPreset id: UUID) {
        guard rules.contains(where: { $0.presetID == id }) else { return }
        rules.removeAll { $0.presetID == id }
        save()
    }

    private func save() {
        file?.save(rules)
    }

    static func currentPowerSource() -> PowerSource {
        Backend.isOnBattery ? .battery : .adapter
    }
}

/// An app as the workspace reports it. Either part can be missing.
struct OpenApp: Equatable {
    var bundleID: String?
    var name: String?

    init(bundleID: String?, name: String?) {
        self.bundleID = bundleID
        self.name = name
    }

    init(_ app: NSRunningApplication?) {
        self.init(bundleID: app?.bundleIdentifier, name: app?.localizedName)
    }

    /// The app that a workspace notification is about.
    init(_ note: Notification) {
        self.init(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
    }

    /// The identifier with the name to show: the app's own, or its identifier when it has none.
    /// Nil for an app with no identifier, which nothing can refer to.
    var named: (bundleID: String, name: String)? {
        guard let bundleID else { return nil }
        guard let name else { return (bundleID, bundleID) }
        return (bundleID, name)
    }
}

/// Finds an installed app by the name a person would say.
enum AppDirectory {
    struct App: Equatable, Identifiable {
        let bundleID: String
        let name: String

        var id: String { bundleID }
    }

    static let folders = ["/Applications", "/System/Applications", "/System/Applications/Utilities", "/Applications/Utilities"]

    static func installed(in folders: [String] = folders + [NSHomeDirectory() + "/Applications"]) -> [App] {
        var apps: [String: App] = [:]
        for folder in folders {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            for file in names where file.hasSuffix(".app") {
                guard let bundle = Bundle(path: folder + "/" + file), let bundleID = bundle.bundleIdentifier else { continue }
                apps[bundleID] = App(bundleID: bundleID, name: String(file.dropLast(4)))
            }
        }
        return apps.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func find(named name: String, among apps: [App]) -> App? {
        let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !wanted.isEmpty else { return nil }
        return apps.first { $0.name.lowercased() == wanted }
            ?? apps.first { $0.name.lowercased().hasPrefix(wanted) }
            ?? apps.first { $0.name.lowercased().contains(wanted) }
    }
}
