import SwiftUI

/// The rules Autopilot follows. The order is the priority: the first rule that matches wins.
struct AutomationView: View {
    @Environment(AppModel.self) private var model
    @State private var apps: [AppDirectory.App] = []
    @State private var request = ""
    @State private var draft: DraftState = .idle

    enum DraftState: Equatable {
        case idle
        case working
        case failed(String)
    }

    var body: some View {
        @Bindable var settings = model.settings
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                VStack(alignment: .leading, spacing: Space.sm) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: Space.xxs) {
                            Text("Rules")
                                .airFont(.display)
                            Text("Rules apply a preset automatically when their conditions are met. The first matching rule is used, so drag rules to reorder them.")
                                .airFont(.body)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: Space.lg)
                        Toggle(isOn: $settings.autopilotEnabled) {
                            Text("Autopilot")
                                .airFont(.body)
                        }
                            .toggleStyle(.switch)
                            .help("When Autopilot is on, AirFlow applies your rules automatically")
                    }
                    statusLine
                }

                if model.automation.rules.isEmpty {
                    EmptyState(
                        title: "No Rules",
                        message: "Add a rule to change presets by app, power source, temperature, or time of day.",
                        isActive: false
                    )
                    .frame(minHeight: 240)
                } else {
                    VStack(spacing: Space.xs) {
                        ForEach(model.automation.rules) { rule in
                            RuleRow(rule: rule, apps: apps, isMatched: model.automation.matchedRuleID == rule.id)
                                .draggable(rule.id.uuidString)
                                .dropDestination(for: String.self) { dropped, _ in
                                    return move(dropped.first, before: rule)
                                }
                        }
                    }
                }
            }
            .padding(Space.lg)
            .frame(maxWidth: Layout.detailMaxWidth + 120, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom) {
            footer
                .padding(Space.md)
                .frame(maxWidth: Layout.detailMaxWidth + 120)
                .frame(maxWidth: .infinity)
        }
        .task {
            if apps.isEmpty {
                apps = await Task.detached { AppDirectory.installed() }.value
            }
        }
    }

    /// Puts a dragged rule in the place of the rule it was dropped on.
    private func move(_ dropped: String?, before target: AutomationRule) -> Bool {
        let rules = model.automation.rules
        guard let dropped, let id = UUID(uuidString: dropped), id != target.id,
              let from = rules.firstIndex(where: { $0.id == id }),
              let to = rules.firstIndex(where: { $0.id == target.id })
        else { return false }
        model.automation.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        return true
    }

    @ViewBuilder
    private var statusLine: some View {
        let automation = model.automation
        if !model.settings.autopilotEnabled {
            Label {
                Text("Autopilot is off. Turn it on to apply your rules automatically.")
            } icon: {
                AntIcon("ant-pause-circle", size: IconSize.inline)
            }
            .airFont(.body)
            .foregroundStyle(.secondary)
        } else if automation.isHeldByUser {
            Label {
                Text("You applied \(model.activePreset.name). Autopilot resumes when a different rule matches.")
            } icon: {
                AntIcon("ant-pause-circle", size: IconSize.inline)
            }
            .airFont(.body)
            .foregroundStyle(.secondary)
        } else if automation.matchedRuleID != nil {
            Label {
                Text("Autopilot applied \(model.activePreset.name) because a rule matches.")
            } icon: {
                AntIcon("ant-robot", size: IconSize.inline)
            }
            .airFont(.body)
            .foregroundStyle(Palette.accent)
        } else {
            Label {
                Text("No rules match right now, so your preset stays applied.")
            } icon: {
                AntIcon("ant-robot", size: IconSize.inline)
            }
            .airFont(.body)
            .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.xs) {
                Menu {
                    ForEach(AutomationTrigger.Kind.allCases) { kind in
                        Button {
                            addRule(kind)
                        } label: {
                            Label(kind.title, image: kind.iconName)
                        }
                    }
                } label: {
                    Label("Add Rule", image: "ant-plus")
                        .airFont(.body)
                }
                .buttonStyle(.glass)
                .fixedSize()

                TextField("Describe a rule, such as “Use Quiet on battery”", text: $request)
                    .font(AirType.body.font)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(draftRule)
                    .disabled(!model.intelligence.availability.isAvailable || draft == .working)
                    .help(model.intelligence.availability.reason ?? "Apple Intelligence drafts the rule on this Mac")
                    .accessibilityLabel("Describe a rule")
                if draft == .working {
                    AirAnimation(name: Animations.spark, loops: true)
                        .frame(width: IconSize.title, height: IconSize.title)
                } else {
                    Button {
                        draftRule()
                    } label: {
                        Label("Draft Rule", image: "ant-send")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.glass)
                    .disabled(!model.intelligence.availability.isAvailable || request.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("Draft the rule")
                }
            }
            if case .failed(let message) = draft {
                Text(message)
                    .airFont(.body)
                    .foregroundStyle(Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let reason = model.intelligence.availability.reason {
                Text(reason)
                    .airFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func addRule(_ kind: AutomationTrigger.Kind) {
        let trigger: AutomationTrigger
        switch kind {
        case .app:
            let app = apps.first { $0.bundleID == "com.apple.dt.Xcode" } ?? apps.first
            trigger = .appIsFrontmost(bundleID: app?.bundleID ?? "com.apple.finder", name: app?.name ?? "Finder")
        case .power:
            trigger = .powerSource(.battery)
        case .temperature:
            trigger = .temperatureAbove(source: .cpuAverage, celsius: 85)
        case .time:
            trigger = .timeRange(startMinute: 22 * 60, endMinute: 7 * 60)
        }
        let preset = model.presets.custom.first?.id ?? Preset.automaticID
        model.automation.add(AutomationRule(trigger: trigger, presetID: preset))
    }

    private func draftRule() {
        let text = request
        let presets = model.presets.presets
        draft = .working
        Task {
            do {
                let proposal = try await model.intelligence.draftRule(from: text, presetNames: presets.map(\.name))
                model.automation.add(try proposal.makeRule(presets: presets, apps: apps))
                request = ""
                draft = .idle
            } catch {
                draft = .failed(error.localizedDescription)
            }
        }
    }
}

/// One rule as a sentence that can be edited in place: when this is true, use that preset.
struct RuleRow: View {
    @Environment(AppModel.self) private var model
    let rule: AutomationRule
    let apps: [AppDirectory.App]
    let isMatched: Bool

    var body: some View {
        HStack(spacing: Space.xs) {
            AntIcon("ant-holder", size: IconSize.inline)
                .foregroundStyle(.tertiary)
                .help("Drag to reorder")
            Toggle("Enabled", isOn: binding(\.isEnabled))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel("Rule is enabled")
            // The sentence wraps like text, so a rule never needs more width than the page has.
            FlowLayout(spacing: Space.xs, lineSpacing: Space.xs) {
                sentence
            }
            Spacer(minLength: 0)
            Button {
                model.automation.delete(id: rule.id)
            } label: {
                Label("Delete Rule", image: "ant-delete")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Delete this rule")
        }
        .airFont(.body)
        .padding(.horizontal, Space.sm)
        .padding(.vertical, Space.xs)
        .antGlass(tint: isMatched ? Palette.accent : nil)
        .opacity(rule.isEnabled ? 1 : 0.55)
    }

    /// "When", the trigger, "use", the preset, and the rule's state: the pieces of one sentence.
    @ViewBuilder
    private var sentence: some View {
        HStack(spacing: Space.xs) {
            AntIcon(rule.trigger.kind.iconName)
                .foregroundStyle(.secondary)
            Text("When")
        }
        triggerEditor
        HStack(spacing: Space.xs) {
            Text("use")
            AntSelect(
                title: "Preset", selection: binding(\.presetID),
                options: model.presets.presets.map { AntOption(value: $0.id, title: $0.name) }
            )
        }
        if isMatched {
            StateTag(text: "Matches Now")
        }
    }

    @ViewBuilder
    private var triggerEditor: some View {
        switch rule.trigger {
        case .appIsFrontmost(let bundleID, let name):
            AntSelect(title: "App", selection: Binding {
                bundleID
            } set: { new in
                let app = apps.first { $0.bundleID == new }
                save(.appIsFrontmost(bundleID: new, name: app?.name ?? name))
            }, options: appOptions(bundleID: bundleID, name: name))
            Text("is active")
        case .powerSource(let source):
            Text("the Mac is on")
            AntSelect(title: "Power Source", selection: Binding {
                source
            } set: { new in
                save(.powerSource(new))
            }, options: PowerSource.allCases.map { AntOption(value: $0, title: $0.title) })
        case .temperatureAbove(let source, let celsius):
            AntSelect(title: "Sensor", selection: Binding {
                source
            } set: { new in
                save(.temperatureAbove(source: new, celsius: celsius))
            }, options: sources(including: source).map { AntOption(value: $0, title: model.monitor.snapshot.name(of: $0)) })
            Stepper(value: Binding {
                celsius
            } set: { new in
                save(.temperatureAbove(source: source, celsius: new))
            }, in: SensorRule.temperatureRange, step: 1) {
                Text(readings: "rises above \(model.settings.format.temperature(celsius))")
            }
            .fixedSize()
        case .timeRange(let start, let end):
            Text("the time is between")
            timePicker("Start", minute: start) { save(.timeRange(startMinute: $0, endMinute: end)) }
            Text("and")
            timePicker("End", minute: end) { save(.timeRange(startMinute: start, endMinute: $0)) }
        }
    }

    private func timePicker(_ title: String, minute: Int, set: @escaping (Int) -> Void) -> some View {
        DatePicker(title, selection: Binding {
            Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()) ?? Date()
        } set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            set((parts.hour ?? 0) * 60 + (parts.minute ?? 0))
        }, displayedComponents: .hourAndMinute)
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel(title)
    }

    /// The installed apps, with the rule's own app first when it is no longer installed.
    private func appOptions(bundleID: String, name: String) -> [AntOption<String>] {
        let installed = apps.map { AntOption(value: $0.bundleID, title: $0.name) }
        return apps.contains { $0.bundleID == bundleID } ? installed : [AntOption(value: bundleID, title: name)] + installed
    }

    private func sources(including current: SensorSource) -> [SensorSource] {
        SensorSourceMenu.groups(in: model.monitor.snapshot, including: current)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AutomationRule, Value>) -> Binding<Value> {
        Binding {
            rule[keyPath: keyPath]
        } set: { new in
            var changed = rule
            changed[keyPath: keyPath] = new
            model.automation.update(changed)
        }
    }

    private func save(_ trigger: AutomationTrigger) {
        var changed = rule
        changed.trigger = trigger
        model.automation.update(changed)
    }
}
