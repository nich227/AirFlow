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

    var body: some View {
        let updates = Updates.shared
        VStack(alignment: .leading, spacing: Space.md) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("Set Up AirFlow")
                    .airFont(.display)
                Text("AirFlow needs your permission for a few things. You can change any of them later in Settings.")
                    .airFont(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            GlassCard(padding: 0) {
                VStack(spacing: 0) {
                    row(icon: "MenuBarIcon", title: "Fan Control", detail: fanControlDetail) {
                        fanControl
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
        .onAppear { model.helper.refresh() }
    }

    private var fanControlDetail: String {
        switch model.helper.status {
        case .enabled:
            return "AirFlow can change fan speeds."
        case .needsApproval:
            return "Turn on AirFlow in System Settings > General > Login Items & Extensions."
        case .notInstalled:
            return "To change fan speeds, AirFlow installs a helper tool. macOS asks you to allow it in Login Items & Extensions. Without it, AirFlow only monitors."
        case .unsignedBuild:
            return "This copy of AirFlow isn't signed by a developer, so it can only monitor."
        case .failed(let message):
            return "The helper tool couldn't be installed. \(message)"
        }
    }

    @ViewBuilder
    private var fanControl: some View {
        switch model.helper.status {
        case .enabled:
            StateTag(text: "On", color: Palette.success, iconName: "ant-check")
        case .needsApproval:
            Button {
                model.helper.openLoginItems()
            } label: {
                Text("Open Login Items Settings").airFont(.body)
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
