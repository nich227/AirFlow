import ServiceManagement
import SwiftUI

/// Whether AirFlow opens when the person logs in.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

/// The first thing a person sees: everything AirFlow needs permission for, in one place, before
/// the window. Each item can also be changed later in Settings.
struct SetupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var opensAtLogin = LoginItem.isEnabled
    @State private var loginError: String?
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let updates = Updates.shared
        VStack(alignment: .leading, spacing: Space.md) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("Set Up AirFlow")
                    .airFont(.display)
                Text("A few quick choices and AirFlow is ready. You can change any of them later in Settings.")
                    .airFont(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            GlassCard(padding: 0) {
                VStack(spacing: 0) {
                    row(icon: "MenuBarIcon", title: "Fan Control", detail: fanControlDetail) {
                        fanControl
                    }
                    if model.helper.status == .needsApproval {
                        steps
                    }
                    if model.helper.status == .enabled {
                        Divider()
                        presetChoice
                    }
                    Divider()
                    row(icon: "ant-poweroff", title: "Open at Login", detail: loginError ?? "AirFlow opens in the menu bar when you log in.") {
                        Toggle("Open at Login", isOn: Binding {
                            opensAtLogin
                        } set: { wanted in
                            do {
                                try LoginItem.set(wanted)
                                loginError = nil
                            } catch {
                                loginError = "AirFlow couldn't change the login item. \(error.localizedDescription)"
                            }
                            opensAtLogin = LoginItem.isEnabled
                        })
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }
                    if updates.isAvailable {
                        Divider()
                        row(icon: "ant-sync", title: "Automatic Updates", detail: "AirFlow checks for a new version and asks before it installs one.") {
                            Toggle("Automatic Updates", isOn: Binding {
                                updates.checksAutomatically
                            } set: { wanted in
                                updates.checksAutomatically = wanted
                            })
                            .labelsHidden()
                            .toggleStyle(.switch)
                        }
                    }
                }
            }

            Text("Changing fan speeds changes how your Mac cools itself. AirFlow keeps every speed within the limits the fan reports, but you are responsible for the settings you choose.")
                .airFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button {
                    model.settings.setupShown = true
                    dismiss()
                } label: {
                    Text("Continue").airFont(.body)
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.lg)
        .frame(width: 520)
        .castsSheetShadow()
        .onAppear { model.helper.refresh() }
    }

    private var fanControlDetail: String {
        switch model.helper.status {
        case .enabled:
            return "Fan control is on. You're all set."
        case .needsApproval:
            return "Almost there. Your Mac needs your OK."
        case .notInstalled:
            return "Let AirFlow change your fan speeds. It takes two clicks, and you can turn it off at any time."
        case .unsignedBuild:
            return "This copy of AirFlow can show your fans, but it can't change their speed."
        case .failed:
            return "That didn't work. Try again. If it still doesn't work, restart your Mac and try once more."
        }
    }

    /// What to do in System Settings, in the order a person does it. AirFlow watches for the
    /// switch, so nothing has to be clicked here afterward.
    private var steps: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            step(1, "System Settings is open. Look for AirFlow under Allow in the Background.")
            step(2, "Turn on the switch next to AirFlow. Your Mac may ask for your password or Touch ID.")
            step(3, "Come back to this window. AirFlow notices by itself.")
            HStack(spacing: Space.xs) {
                ProgressView().controlSize(.small)
                Text("Waiting for you to turn on the switch…")
                    .airFont(.label)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, Space.xxs)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Space.md)
        .padding(.bottom, Space.md)
        // The status is read again every second, so the sheet moves on as soon as the switch is on.
        .task {
            while !Task.isCancelled, model.helper.status == .needsApproval {
                try? await Task.sleep(for: .seconds(1))
                model.helper.refresh()
            }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
            Text("\(number)")
                .readingFont(.label)
                .frame(width: 20, height: 20)
                .background(Palette.accent.opacity(0.2), in: Circle())
            Text(text)
                .airFont(.label)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Once fan control is on, one click chooses how the fans run. Automatic leaves them to macOS.
    private var presetChoice: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Try Adaptive")
                .airFont(.title)
            Text("Adaptive sets the fans for you. It stays quiet for light work and speeds up before a heavy task heats up your Mac. You can change presets at any time.")
                .airFont(.label)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.xs) {
                ForEach(startingPresets) { preset in
                    let isCurrent = model.settings.activePresetID == preset.id
                    Button {
                        model.apply(preset.id)
                    } label: {
                        VStack(spacing: Space.xxs) {
                            AntIcon(preset.icon.assetName, size: IconSize.title)
                            Text(preset.name).airFont(.body)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Space.xs)
                        .foregroundStyle(isCurrent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                        .background(isCurrent ? AnyShapeStyle(Palette.accent.gradient) : AnyShapeStyle(Palette.fill(contrast)), in: RoundedRectangle(cornerRadius: Radius.md))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isCurrent ? "\(preset.name), current" : preset.name)
                }
            }
            Text(model.activePreset.summary)
                .airFont(.label)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Space.md)
    }

    /// Three places to start. Adaptive comes first, because it is the one to try.
    private var startingPresets: [Preset] {
        [Preset.adaptive, model.presets.preset(named: "Quiet"), Preset.automatic].compactMap { $0 }
    }

    @ViewBuilder
    private var fanControl: some View {
        switch model.helper.status {
        case .enabled:
            StateTag(text: "On", color: Palette.success, iconName: "ant-check")
        case .needsApproval:
            Button {
                model.openFanControlSettings()
            } label: {
                Text("Open System Settings").airFont(.body)
            }
        case .notInstalled:
            Button {
                model.enableFanControl()
            } label: {
                Text("Turn On").airFont(.body)
            }
        case .failed:
            Button {
                model.enableFanControl()
            } label: {
                Text("Try Again").airFont(.body)
            }
        case .unsignedBuild:
            StateTag(text: "Not Available", color: Palette.caution)
        }
    }

    private func row(icon: String, title: String, detail: String, @ViewBuilder control: () -> some View) -> some View {
        HStack(alignment: .center, spacing: Space.sm) {
            AntIcon(icon, size: IconSize.title)
                .foregroundStyle(Palette.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).airFont(.title)
                Text(detail)
                    .airFont(.label)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Space.sm)
            control()
        }
        .padding(Space.md)
    }
}
