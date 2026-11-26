import SwiftUI

/// This shows what one preset is, and what it does with each fan, beside what each fan is doing
/// now.
struct PresetDetail: View {
    @Environment(AppModel.self) private var model
    let preset: Preset

    @State private var name = ""
    @State private var isRenaming = false
    @FocusState private var nameIsFocused: Bool
    private var isActive: Bool { model.settings.activePresetID == preset.id }

    var body: some View {
        let fans = model.monitor.snapshot.fans
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                header
                // A Mac with no fans has nothing to control, so it is not offered the helper.
                if !(model.monitor.isAvailable && fans.isEmpty) {
                    ControlStatusBanner()
                }
                if !model.monitor.hasLoaded {
                    EmptyState(title: "Reading the Fans", message: "AirFlow is asking the Mac for its fans and sensors.")
                        .frame(minHeight: 240)
                } else if !model.monitor.isAvailable {
                    EmptyState(
                        title: "Can't Read the Fans",
                        message: "AirFlow couldn't open the Mac's system management controller. Quit AirFlow and open it again."
                    )
                    .frame(minHeight: 240)
                } else if fans.isEmpty {
                    EmptyState(title: "No Fans", message: "This Mac is cooled without fans, so there is nothing to control. Its temperatures are in the readings.")
                        .frame(minHeight: 240)
                } else {
                    if preset.kind == .adaptive {
                        GlassCard {
                            AdaptiveSummary()
                        }
                    }
                    ForEach(fans) { fan in
                        GlassCard {
                            FanSection(fan: fan, preset: preset, isActive: isActive)
                        }
                    }
                    if preset.kind == .adaptive {
                        GlassCard {
                            AppWorkloadsEditor()
                        }
                    }
                }
            }
            .padding(Space.lg)
            .frame(maxWidth: Layout.detailMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onChange(of: nameIsFocused) { _, focused in
            if !focused, isRenaming { commitName() }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Space.sm) {
            iconMenu
            VStack(alignment: .leading, spacing: Space.xxs) {
                if isRenaming {
                    TextField("Preset Name", text: $name)
                        .textFieldStyle(.plain)
                        .airFont(.display)
                        .focused($nameIsFocused)
                        .onSubmit(commitName)
                        .onExitCommand(perform: cancelRename)
                        .accessibilityLabel("Preset name")
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                        Text(preset.name)
                            .airFont(.display)
                        if !preset.isBuiltIn {
                            // The name is text until a person asks to change it, so opening the
                            // window never puts the keyboard in a field.
                            Button(action: beginRename) {
                                Label("Rename", image: "ant-edit")
                                    .labelStyle(.iconOnly)
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Rename this preset")
                        }
                    }
                }
                Text(subtitle)
                    .airFont(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Space.sm)
            if isActive {
                StateTag(text: activeTag, iconName: "ant-check")
            }
        }
    }

    @ViewBuilder
    private var iconMenu: some View {
        if preset.isBuiltIn {
            AntIcon(preset.icon.assetName, size: IconSize.state)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        } else {
            Menu {
                ForEach(PresetIcon.choices) { icon in
                    Button {
                        var changed = preset
                        changed.icon = icon
                        model.presets.update(changed)
                    } label: {
                        Label(icon.rawValue.replacingOccurrences(of: "-", with: " ").capitalized, image: icon.assetName)
                    }
                }
            } label: {
                AntIcon(preset.icon.assetName, size: IconSize.state)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.top, 2)
            .help("Change the preset's icon")
            .accessibilityLabel("Preset icon")
        }
    }

    private var subtitle: String {
        if !preset.summary.isEmpty { return preset.summary }
        return "Set how each fan runs. Changes are saved as you make them."
    }

    private var activeTag: String {
        // "Active" is true only while AirFlow controls the fans with this preset.
        guard model.controller.mode == .controlling else { return "Chosen" }
        switch model.chosenBy {
        case .autopilot: return "Active by Autopilot"
        case .user, .siri: return "Active"
        }
    }

    private func beginRename() {
        name = preset.name
        isRenaming = true
        nameIsFocused = true
    }

    private func cancelRename() {
        isRenaming = false
    }

    private func commitName() {
        isRenaming = false
        let cleaned = Preset.cleanName(name)
        guard !preset.isBuiltIn, !cleaned.isEmpty, cleaned != preset.name else { return }
        var changed = preset
        changed.name = cleaned
        model.presets.update(changed)
    }
}

/// The sentence under a fan's name: what the preset does with the fan, and who controls the fan
/// now. Only a preset that is active while AirFlow controls the fans says "is held" or "follows" as
/// a fact. Any other preset says what it would do.
enum FanSentence {
    static func text(
        control: FanControl, command: FanCommand, sourceName: (SensorSource) -> String, format: ReadingFormat,
        isActive: Bool, mode: FanController.Mode
    ) -> String {
        let inEffect = isActive && mode == .controlling
        var text: String
        var asked = ""
        switch control {
        case .automatic:
            return "macOS controls this fan."
        case .constant, .constantFraction:
            if case .speed(let rpm) = command {
                text = inEffect ? "Held at \(ReadingFormat.rpmWithUnit(rpm))." : "This preset holds it at \(ReadingFormat.rpmWithUnit(rpm))."
            } else {
                text = inEffect ? "Held at a constant speed." : "This preset holds it at a constant speed."
            }
        case .sensorBased(let rule):
            let range = "from \(format.temperature(rule.startCelsius)) to full speed at \(format.temperature(rule.maxCelsius))"
            text = inEffect ? "Follows \(sourceName(rule.source)), \(range)." : "This preset follows \(sourceName(rule.source)), \(range)."
            switch command {
            case .automatic:
                return text + " This Mac doesn't report that sensor, so macOS controls the fan."
            case .speed(let rpm):
                // A constant speed is in the sentence already. A rule's speed moves, so it is added.
                asked = inEffect ? " It asks for \(ReadingFormat.rpmWithUnit(rpm)) now." : " It would ask for \(ReadingFormat.rpmWithUnit(rpm))."
            }
        }
        if isActive, !inEffect {
            text += mode == .safeguard ? " The safeguard is on, so macOS controls the fan now." : " macOS controls the fan now."
        }
        return text + asked
    }
}

extension FanSentence {
    /// The sentence for a fan under the Adaptive preset.
    static func adaptiveText(command: FanCommand, isActive: Bool, mode: FanController.Mode) -> String {
        guard case .speed(let rpm) = command else {
            return "Adaptive steers by the CPU and GPU temperatures. This Mac doesn't report them, so macOS controls the fan."
        }
        let speed = ReadingFormat.rpmWithUnit(rpm)
        if isActive, mode == .controlling {
            return "Adaptive holds it at \(speed)."
        }
        var text = "Adaptive would ask for \(speed)."
        if isActive {
            text += mode == .safeguard ? " The safeguard is on, so macOS controls the fan now." : " macOS controls the fan now."
        }
        return text
    }
}

/// One fan under one preset: the live speed, and the control the preset gives it.
struct FanSection: View {
    @Environment(AppModel.self) private var model
    let fan: Fan
    let preset: Preset
    let isActive: Bool

    private var control: FanControl { preset.control(for: fan) }
    private var snapshot: ThermalSnapshot { model.monitor.snapshot }

    /// What this preset asks of the fan with the sensors where they are now.
    private var command: FanCommand {
        if preset.kind == .adaptive {
            return FanPlanner.adaptiveCommand(fan: fan, fraction: model.adaptive.fraction)
        }
        return FanPlanner.command(for: control, fan: fan, snapshot: snapshot)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(alignment: .center, spacing: Space.md) {
                Rotor(fan: fan)
                VStack(alignment: .leading, spacing: 2) {
                    Text(fan.name)
                        .airFont(.title)
                    Text(readings: sentence)
                        .airFont(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Space.sm)
                Statistic(value: ReadingFormat.rpm(fan.currentRPM), unit: "RPM")
            }
            FanTrack(fan: fan, target: heldTarget)
            if preset.kind == .custom {
                editor
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// The mark on the track: the speed AirFlow is holding the fan at.
    private var heldTarget: Double? {
        guard isActive, model.controller.mode == .controlling, case .speed(let rpm) = command else { return nil }
        return rpm
    }

    private var sentence: String {
        if preset.kind == .adaptive {
            return FanSentence.adaptiveText(command: command, isActive: isActive, mode: model.controller.mode)
        }
        return FanSentence.text(
            control: control, command: command, sourceName: { snapshot.name(of: $0) }, format: model.settings.format,
            isActive: isActive, mode: model.controller.mode
        )
    }

    @ViewBuilder
    private var editor: some View {
        AntSegmented(
            title: "\(fan.name) control", selection: kind,
            options: FanControl.Kind.allCases.map { AntOption(value: $0, title: $0.title) }
        )

        switch control {
        case .automatic:
            EmptyView()
        case .constant, .constantFraction:
            HStack(spacing: Space.sm) {
                Slider(value: constantRPM, in: fan.minimumRPM...fan.maximumRPM) {
                    Text("Speed")
                }
                .labelsHidden()
                .accessibilityLabel("\(fan.name) speed")
                .accessibilityValue(ReadingFormat.rpmWithUnit(constantRPM.wrappedValue))
                Text(ReadingFormat.rpmWithUnit(constantRPM.wrappedValue))
                    .readingFont(.body)
                    .frame(width: 84, alignment: .trailing)
            }
        case .sensorBased(let rule):
            SensorRuleEditor(rule: sensorRule(rule), fan: fan, snapshot: snapshot, format: model.settings.format)
        }
    }

    private var kind: Binding<FanControl.Kind> {
        Binding {
            control.kind
        } set: { new in
            guard new != control.kind else { return }
            switch new {
            case .automatic:
                save(.automatic)
            case .constant:
                save(.constant(rpm: (fan.clamp(max(fan.currentRPM, fan.minimumRPM)) / 50).rounded() * 50))
            case .sensorBased:
                save(.sensorBased(SensorRule(source: .cpuAverage, startCelsius: 55, maxCelsius: 85)))
            }
        }
    }

    private var constantRPM: Binding<Double> {
        Binding {
            if case .speed(let rpm) = command { return rpm }
            return fan.minimumRPM
        } set: { new in
            // The slider moves freely, and the speed it sets is a round number.
            save(.constant(rpm: fan.clamp((new / 50).rounded() * 50)))
        }
    }

    private func sensorRule(_ rule: SensorRule) -> Binding<SensorRule> {
        Binding {
            rule
        } set: { new in
            save(.sensorBased(new))
        }
    }

    private func save(_ control: FanControl) {
        var changed = preset
        changed.setControl(control, for: fan)
        model.presets.update(changed)
        if isActive { model.runControlLoop() }
    }
}

/// The parts of a sensor rule: what it follows, the curve, and the two temperatures as numbers.
struct SensorRuleEditor: View {
    @Binding var rule: SensorRule
    let fan: Fan
    let snapshot: ThermalSnapshot
    let format: ReadingFormat

    private var group: SensorGroup {
        switch rule.source {
        case .group(let group, _): return group
        case .key(let key): return snapshot.sensor(key: key)?.group ?? .other
        }
    }

    /// The parts first, then the single sensors whose meaning is known.
    private var sourceOptions: [AntOption<SensorSource>] {
        let groups = SensorSourceMenu.groups(in: snapshot, including: rule.source)
        let named = SensorSourceMenu.namedSensors(in: snapshot, including: rule.source)
        return groups.map { AntOption(value: $0, title: snapshot.name(of: $0)) }
            + named.enumerated().map { AntOption(value: $1, title: snapshot.name(of: $1), startsGroup: $0 == 0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.xs) {
                Text("Follows")
                    .airFont(.body)
                AntSelect(title: "Follows", selection: source, options: sourceOptions)
                Spacer()
                if let celsius = snapshot.celsius(for: rule.source) {
                    HStack(spacing: Space.xs) {
                        StatusDot(band: TemperatureBand.band(for: celsius, in: group))
                        Text(readings: "Now \(format.temperature(celsius))")
                            .airFont(.body)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            CurveEditor(rule: $rule, fan: fan, currentCelsius: snapshot.celsius(for: rule.source), group: group, format: format)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Space.lg) {
                    steppers
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: Space.xs) {
                    steppers
                }
            }
            .airFont(.body)
        }
    }

    @ViewBuilder
    private var steppers: some View {
        Stepper(value: start, in: SensorRule.temperatureRange.lowerBound...(rule.maxCelsius - SensorRule.minimumSpan), step: 1) {
            Text(readings: "Starts rising at \(format.temperature(rule.startCelsius))")
        }
        .fixedSize()
        Stepper(value: full, in: (rule.startCelsius + SensorRule.minimumSpan)...SensorRule.temperatureRange.upperBound, step: 1) {
            Text(readings: "Full speed at \(format.temperature(rule.maxCelsius))")
        }
        .fixedSize()
    }

    private var source: Binding<SensorSource> {
        Binding {
            rule.source
        } set: { new in
            rule = SensorRule(source: new, startCelsius: rule.startCelsius, maxCelsius: rule.maxCelsius)
        }
    }

    private var start: Binding<Double> {
        Binding {
            rule.startCelsius
        } set: { new in
            rule = SensorRule(source: rule.source, startCelsius: new, maxCelsius: rule.maxCelsius)
        }
    }

    private var full: Binding<Double> {
        Binding {
            rule.maxCelsius
        } set: { new in
            rule = SensorRule(source: rule.source, startCelsius: rule.startCelsius, maxCelsius: new)
        }
    }
}

/// The sensors a rule can follow, in the order a menu lists them.
enum SensorSourceMenu {
    /// Each group this Mac reports, as an average and as its hottest sensor.
    /// The menu always holds `current`, so a rule that follows a part this Mac lacks still
    /// shows what it follows.
    static func groups(in snapshot: ThermalSnapshot, including current: SensorSource) -> [SensorSource] {
        var sources: [SensorSource] = []
        for summary in snapshot.summaries {
            sources.append(.group(summary.group, .average))
            if summary.count > 1 { sources.append(.group(summary.group, .hottest)) }
        }
        if case .group = current, !sources.contains(current) { sources.append(current) }
        return sources
    }

    /// The single sensors whose meaning is known.
    static func namedSensors(in snapshot: ThermalSnapshot, including current: SensorSource) -> [SensorSource] {
        var sources: [SensorSource] = snapshot.sensors.filter(\.isKnown).map { .key($0.key) }
        if case .key = current, !sources.contains(current) { sources.append(current) }
        return sources
    }
}
