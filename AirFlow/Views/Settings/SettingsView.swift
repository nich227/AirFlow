import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab {
                GeneralSettingsPane()
            } label: {
                Label("General", image: "ant-setting")
            }
            Tab {
                FanControlSettingsPane()
            } label: {
                Label("Fan Control", image: "MenuBarIcon")
            }
            Tab {
                IntelligenceSettingsPane()
            } label: {
                Label("Intelligence", image: "ant-sparkles")
            }
            Tab {
                AboutSettingsPane()
            } label: {
                Label("About", image: "ant-info-circle")
            }
        }
        .frame(width: Layout.settingsWidth)
    }
}

struct GeneralSettingsPane: View {
    @Environment(AppModel.self) private var model
    @State private var launchesAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Toggle("Open at Login", isOn: Binding {
                    launchesAtLogin
                } set: { new in
                    setLaunchAtLogin(new)
                })
                if let loginError {
                    Text(loginError)
                        .foregroundStyle(Palette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } footer: {
                Text("AirFlow opens in the menu bar without a window.")
            }
            Section("Menu Bar") {
                Picker("Show", selection: $settings.menuBarReadout) {
                    ForEach(MenuBarReadout.allCases) { readout in
                        Text(readout.title).tag(readout)
                    }
                }
            }
            Section("Temperatures") {
                Picker("Unit", selection: $settings.temperatureUnit) {
                    ForEach(TemperatureUnit.allCases) { unit in
                        Text(unit.title).tag(unit)
                    }
                }
                Toggle("Show Tenths of a Degree", isOn: $settings.preciseTemperatures)
            }
        }
        .formStyle(.grouped)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItem.set(enabled)
            loginError = nil
        } catch {
            loginError = "AirFlow couldn't change the login item. \(error.localizedDescription)"
        }
        launchesAtLogin = LoginItem.isEnabled
    }
}

struct FanControlSettingsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        let format = settings.format
        Form {
            Section {
                LabeledContent("Helper") {
                    Text(helperStatus)
                        .foregroundStyle(.secondary)
                }
                switch model.helper.status {
                case .enabled:
                    Button("Remove Helper Tool") {
                        Task { await model.removeHelper() }
                    }
                case .needsApproval:
                    Button("Open System Settings") { model.openFanControlSettings() }
                case .notInstalled, .failed:
                    Button("Turn On Fan Control") { model.enableFanControl() }
                case .unsignedBuild:
                    EmptyView()
                }
            } footer: {
                Text("Changing fan speeds requires administrator privileges, so AirFlow uses a small helper tool. The helper accepts requests only from AirFlow and keeps every speed within the fan's limits. It returns control to macOS when AirFlow quits or stops responding. Without the helper, AirFlow can only monitor.")
            }
            Section {
                Toggle("Return Fans to macOS When the Mac Runs Hot", isOn: $settings.safeguardEnabled)
                Stepper(value: $settings.safeguardLimit, in: Safeguard.limitRange, step: 1) {
                    LabeledContent("Limit") {
                        Text(format.temperatureWithUnit(settings.safeguardLimit))
                            .monospacedDigit()
                    }
                }
                .disabled(!settings.safeguardEnabled)
            } header: {
                Text("Safeguard")
            } footer: {
                Text("When the average CPU or GPU temperature reaches the limit, macOS controls the fans until it falls to \(format.temperatureWithUnit(settings.safeguardLimit - Safeguard.releaseMargin)).")
            }
        }
        .formStyle(.grouped)
        .onAppear { model.helper.refresh() }
    }

    private var helperStatus: String {
        switch model.helper.status {
        case .enabled: return "On"
        case .needsApproval: return "Waiting for approval in Login Items"
        case .notInstalled: return "Off"
        case .unsignedBuild: return "Not available in this copy"
        case .failed: return "Couldn't be installed"
        }
    }
}

struct IntelligenceSettingsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                LabeledContent("Apple Intelligence") {
                    Text(model.intelligence.availability.isAvailable ? "Available" : "Not available")
                        .foregroundStyle(.secondary)
                }
                if let reason = model.intelligence.availability.reason {
                    Text(reason)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } footer: {
                Text("AirFlow uses Apple Intelligence on this Mac to draft presets and rules from your descriptions and to explain recent readings. Your descriptions and readings never leave your Mac. Apple Intelligence can't change fan speeds. You approve every preset and rule it drafts.")
            }
            Section {
                Toggle("Autopilot", isOn: $settings.autopilotEnabled)
            } footer: {
                Text("When Autopilot is on, AirFlow applies your rules automatically. A preset you apply yourself stays on until a different rule matches. You can also ask Siri to “Apply Quiet in AirFlow”.")
            }
        }
        .formStyle(.grouped)
        .onAppear { model.intelligence.refreshAvailability() }
    }
}

struct AboutSettingsPane: View {
    private let updates = Updates.shared
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    var body: some View {
        VStack(spacing: Space.sm) {
            Rotor(fan: nil, size: IconSize.illustration, isActive: false, tint: Palette.accent)
            Text("AirFlow")
                .airFont(.display)
            Text("Version \(version)")
                .airFont(.body)
                .foregroundStyle(.secondary)
            if updates.isAvailable {
                VStack(spacing: Space.xs) {
                    Button("Check for Updates…") { updates.check() }
                        .disabled(!updates.canCheck)
                    Toggle("Check for Updates Automatically", isOn: Binding {
                        updates.checksAutomatically
                    } set: { on in
                        updates.checksAutomatically = on
                    })
                    .toggleStyle(.checkbox)
                }
            }
            Text("Changing fan speeds changes how your Mac cools itself. AirFlow keeps every speed within the limits the fan reports, but you are responsible for the settings you choose.")
                .airFont(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 400)
        }
        .padding(Space.xl)
        .frame(maxWidth: .infinity)
    }
}
