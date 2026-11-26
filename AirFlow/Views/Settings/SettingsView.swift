import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    /// A tab's icon at 14 points. The tab bar draws every image as large as its own box, whatever
    /// size the image has, so the icon is drawn small in the middle of an empty picture the size
    /// of that box. The assets also differ in size: the fan is 18 points and the Ant Design icons
    /// are 16.
    static func tabIcon(_ name: String) -> Image {
        guard let icon = NSImage(named: name) else { return Image(name) }
        let box = NSSize(width: tabIconBox, height: tabIconBox)
        let picture = NSImage(size: box, flipped: false) { rect in
            // An Ant Design icon leaves a margin inside its own square, and the fan fills its
            // square to the edge. The fan is drawn that much smaller, so the four look one size.
            let side = name == "MenuBarIcon" ? IconSize.inline * antArtShare : IconSize.inline
            icon.draw(in: NSRect(x: (rect.width - side) / 2, y: (rect.height - side) / 2, width: side, height: side))
            return true
        }
        picture.isTemplate = true
        return Image(nsImage: picture)
    }

    /// The side of the box a Preferences tab gives its image, measured on macOS 26.
    static let tabIconBox: CGFloat = 32
    /// The share of its square that an Ant Design icon's drawing covers (896 of 1024 units).
    static let antArtShare: CGFloat = 0.875

    var body: some View {
        TabView {
            Tab {
                GeneralSettingsPane()
            } label: {
                Label {
                    Text("General")
                } icon: {
                    Self.tabIcon("ant-setting")
                }
            }
            Tab {
                FanControlSettingsPane()
            } label: {
                Label {
                    Text("Fan Control")
                } icon: {
                    Self.tabIcon("MenuBarIcon")
                }
            }
            Tab {
                IntelligenceSettingsPane()
            } label: {
                Label {
                    Text("Intelligence")
                } icon: {
                    Self.tabIcon("ant-sparkles")
                }
            }
            Tab {
                AboutSettingsPane()
            } label: {
                Label {
                    Text("About")
                } icon: {
                    Self.tabIcon("ant-info-circle")
                }
            }
        }
        .frame(width: Layout.settingsWidth)
        // Preferences shows the palette's main color at once, and the Dock icon changes with it.
        .tint(Palette.accent)
        .id(model.settings.lookID)
        .onChange(of: model.settings.colorPalette) {
            DockIcon.update()
        }
    }
}

extension View {
    /// Makes a pane of Preferences as tall as what it holds, so the window shows the whole pane.
    /// A grouped form scrolls, and a window that is given no height for it cuts the pane off
    /// below its third section.
    func settingsPaneHeight() -> some View {
        fixedSize(horizontal: false, vertical: true)
    }
}

/// A palette's colors side by side: the five steps of the temperature scale as beads, its main
/// color, then the CPU's and the GPU's lines.
struct PaletteSwatch: View {
    let palette: ColorPalette

    var body: some View {
        HStack(spacing: Space.xs) {
            ForEach(TemperatureBand.allCases, id: \.self) { band in
                let color = Palette.temperature(band, in: palette)
                Circle()
                    .fill(color.gradient)
                    .frame(width: Layout.statusDot + 4, height: Layout.statusDot + 4)
                    .shadow(color: color.opacity(0.6), radius: 3)
            }
            RoundedRectangle(cornerRadius: Radius.xs)
                .fill(Color(palette.accent).gradient)
                .frame(width: 20, height: Layout.statusDot + 4)
            ForEach([Palette.cpu(in: palette), Palette.gpu(in: palette)], id: \.self) { line in
                Capsule()
                    .fill(LinearGradient(colors: line, startPoint: .leading, endPoint: .trailing))
                    .frame(width: 28, height: 4)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("The colors of \(palette.title)")
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
            Section {
                Picker("Color Palette", selection: $settings.colorPalette) {
                    ForEach(ColorPalette.allCases) { palette in
                        Text(palette.title).tag(palette)
                    }
                }
                LabeledContent("Preview") {
                    PaletteSwatch(palette: settings.colorPalette)
                }
                Picker("Status Dots", selection: $settings.dotColoring) {
                    ForEach(DotColoring.allCases) { coloring in
                        Text(coloring.title).tag(coloring)
                    }
                }
            } header: {
                Text("Colors")
            } footer: {
                Text("The palette colors what is selected, the temperatures, the charts, and the fan in AirFlow's icon. By Temperature, a dot shows how hot a part is for its own limits. By Part, each part keeps one color.")
            }
        }
        .formStyle(.grouped)
        .settingsPaneHeight()
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
        .settingsPaneHeight()
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
        .settingsPaneHeight()
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
