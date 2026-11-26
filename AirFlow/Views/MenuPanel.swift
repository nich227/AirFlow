import SwiftUI

/// The menu bar item shows the mark, and the readings the person chose.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let text = Self.text(readout: model.settings.menuBarReadout, snapshot: model.monitor.snapshot, format: model.settings.format)
        HStack(spacing: Space.xxs) {
            Image("MenuBarIcon")
            if let text {
                Text(text).readingFont(.body)
            }
        }
        .accessibilityLabel(text.map { "AirFlow, \($0)" } ?? "AirFlow")
        .onAppear {
            WindowOpener.shared.openMain = { openWindow(id: AirFlowApp.mainWindowID) }
            // The first time AirFlow opens, its window shows what it can do and how to turn on
            // fan control. After that it stays in the menu bar.
            if !AppModel.isRunningTests, !model.settings.welcomeShown {
                model.settings.welcomeShown = true
                WindowOpener.shared.open()
            }
            #if DEBUG
            // A script that captures the window opens it without taking the keyboard.
            if ProcessInfo.processInfo.environment["AIRFLOW_SHOW"] != nil {
                WindowOpener.shared.open(activating: false)
            }
            #endif
        }
    }

    static func text(readout: MenuBarReadout, snapshot: ThermalSnapshot, format: ReadingFormat) -> String? {
        let fan = snapshot.fans.map(\.currentRPM).max().map { ReadingFormat.rpm($0) }
        let cpu = snapshot.summary(of: .cpu).map { format.temperature($0.average) }
        let gpu = snapshot.summary(of: .gpu).map { format.temperature($0.average) }
        switch readout {
        case .none: return nil
        case .fastestFan: return fan
        case .cpu: return cpu
        case .gpu: return gpu
        case .fanAndCPU:
            let parts = [fan, cpu].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: "  ")
        }
    }
}

/// The panel under the menu bar item shows what the fans are doing, and one click changes the
/// preset.
struct MenuPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isShowing = false

    var body: some View {
        let snapshot = model.monitor.snapshot
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, Space.md)
                .padding(.top, Space.md)
                .padding(.bottom, Space.sm)

            if model.helper.status != .enabled || model.controller.safeguard.isEngaged || model.controller.lastError != nil {
                ControlStatusBanner(isCompact: true)
                    .padding(.horizontal, Space.sm)
                    .padding(.bottom, Space.sm)
            }

            if !snapshot.fans.isEmpty {
                VStack(spacing: Space.sm) {
                    ForEach(snapshot.fans) { fan in
                        fanRow(fan)
                    }
                }
                .padding(.horizontal, Space.md)
                .padding(.bottom, Space.sm)
            }

            temperatures(snapshot)
                .padding(.horizontal, Space.md)
                .padding(.bottom, Space.sm)

            divider
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(model.presets.presets) { preset in
                        PresetMenuRow(preset: preset, isActive: preset.id == model.settings.activePresetID) {
                            model.apply(preset.id)
                        }
                    }
                }
                .padding(Space.xxs)
            }
            .frame(maxHeight: 260)
            .fixedSize(horizontal: false, vertical: true)

            divider
            HStack(spacing: Space.xs) {
                Button {
                    WindowOpener.shared.open()
                } label: {
                    Text("Open AirFlow")
                }
                Button {
                    NSApp.activate()
                    openSettings()
                } label: {
                    Text("Settings…")
                }
                Spacer()
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Text("Quit AirFlow")
                }
            }
            .airFont(.label)
            .buttonStyle(.glass)
            .controlSize(.small)
            .padding(Space.sm)
        }
        .frame(width: Layout.panelWidth)
        // The panel reads its colors as it is built, so a new palette builds it again.
        .id(model.settings.colorPalette)
        .tint(Palette.accent)
        .background {
            if model.settings.activePresetID == Preset.adaptiveID {
                AirBackdrop()
            }
        }
        .environment(\.airRainbow, model.settings.activePresetID == Preset.adaptiveID)
        .onAppear {
            isShowing = true
            model.monitor.visibleSurfaces += 1
            Task { await model.monitor.refresh() }
        }
        .onDisappear {
            isShowing = false
            model.monitor.visibleSurfaces -= 1
        }
    }

    private var divider: some View {
        Rectangle().fill(Palette.hairline(contrast)).frame(height: 1)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Space.xs) {
            AntIcon(model.activePreset.icon.assetName, size: IconSize.title)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.activePreset.name)
                    .airFont(.title)
                Text(chosenLine)
                    .airFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    private var chosenLine: String {
        if model.controller.safeguard.isEngaged { return "Paused by the safeguard" }
        switch model.chosenBy {
        case .autopilot: return "Applied by Autopilot"
        case .siri: return "Applied with Siri"
        case .user: return model.settings.autopilotEnabled ? "Applied by you. Autopilot is on." : "Applied by you"
        }
    }

    private func fanRow(_ fan: Fan) -> some View {
        let command = model.controller.plan[fan.index]
        var target: Double?
        if model.controller.mode == .controlling, case .speed(let rpm)? = command { target = rpm }
        return HStack(spacing: Space.sm) {
            Rotor(fan: fan, size: IconSize.state, isActive: isShowing)
            VStack(alignment: .leading, spacing: Space.xxs) {
                HStack(alignment: .firstTextBaseline) {
                    Text(fan.name)
                        .airFont(.body)
                    Spacer()
                    Statistic(value: ReadingFormat.rpm(fan.currentRPM), unit: "RPM", role: .body)
                }
                FanTrack(fan: fan, target: target, showsLimits: false)
            }
        }
    }

    private func temperatures(_ snapshot: ThermalSnapshot) -> some View {
        let format = model.settings.format
        let groups: [SensorGroup] = [.cpu, .gpu, .battery]
        return HStack(spacing: Space.xs) {
            ForEach(groups.compactMap(snapshot.summary(of:)), id: \.group) { summary in
                HStack(spacing: Space.xxs) {
                    StatusDot(band: TemperatureBand.band(for: summary.average, in: summary.group))
                    Text(summary.group.title)
                        .foregroundStyle(.secondary)
                    Text(format.temperature(summary.average))
                        .readingFont(.label)
                }
                .airFont(.label)
                .padding(.horizontal, Space.xs)
                .padding(.vertical, Space.xxs)
                .antGlass(radius: nil)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(summary.group.title)
                .accessibilityValue(format.spokenTemperature(summary.average))
            }
            Spacer()
        }
    }
}

struct PresetMenuRow: View {
    let preset: Preset
    let isActive: Bool
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.xs) {
                AntIcon(preset.icon.assetName)
                    .foregroundStyle(isActive ? Palette.accent : .secondary)
                Text(preset.name)
                    .airFont(.body)
                Spacer()
                if isActive {
                    AntIcon("ant-check", size: IconSize.inline)
                        .foregroundStyle(Palette.accent)
                }
            }
            .padding(.horizontal, Space.sm)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovered ? Palette.fillStrong(contrast) : .clear, in: RoundedRectangle(cornerRadius: Radius.md))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(preset.name)
        .accessibilityValue(isActive ? "Active" : "")
        .accessibilityHint(isActive ? "" : "Applies this preset")
    }
}
