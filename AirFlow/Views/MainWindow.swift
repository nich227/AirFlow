import SwiftUI

enum SidebarItem: Hashable {
    case preset(UUID)
    case rules
    case sensors
}

/// The window's sidebar has presets and pages, and the middle has the selected one. The inspector
/// has the Mac's live readings whichever one is showing.
struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.openSettings) private var openSettings
    @State private var selection: SidebarItem?
    @State private var isDescribing = false
    @State private var isSettingUp = false

    var body: some View {
        @Bindable var settings = model.settings
        @Bindable var model = model
        NavigationSplitView {
            Sidebar(selection: $selection, isDescribing: $isDescribing)
                .id(model.settings.lookID)
                .navigationSplitViewColumnWidth(min: 200, ideal: Layout.sidebarWidth, max: 240)
        } detail: {
            detail
                // A page reads its colors as it is built, so a new palette builds it again.
                .id(model.settings.lookID)
                // The readings are a panel of AirFlow's own beside the page, rounded on every
                // side as the sidebar is. The system's inspector is square and fills its edge.
                .safeAreaInset(edge: .trailing, spacing: 0) {
                    if settings.showsInspector {
                        readingsPanel
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .toolbar {
                    // Both buttons sit together at the window's trailing edge.
                    ToolbarSpacer(.flexible)
                    applyItem
                    readingsItem
                }
        }
        .overlay {
            SheetShadow(size: model.openSheetSize)
        }
        // The palette's main color is the accent of every control in the window.
        .tint(Palette.accent)
        // The window lets the desktop show through, so the glass components have something to bend.
        // While Adaptive is on, fields of color lie over it.
        .containerBackground(for: .window) {
            if model.settings.activePresetID == Preset.adaptiveID {
                AirBackdrop()
                    .transition(.opacity)
            } else {
                Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            }
        }
        // Each page has its own heading, so the title bar does not repeat it. The title still
        // names the window in the Window menu and to VoiceOver.
        .environment(\.airRainbow, model.settings.activePresetID == Preset.adaptiveID)
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .navigationTitle(title)
        .sheet(isPresented: $isSettingUp, onDismiss: { model.settings.setupShown = true }) {
            SetupSheet()
        }
        .sheet(isPresented: $isDescribing) {
            DescribePresetSheet { preset in
                selection = .preset(preset.id)
            }
        }
        .fileImporter(isPresented: $model.transfer.isImporting, allowedContentTypes: [PresetCodec.contentType]) { result in
            guard case .success(let url) = result, let first = model.importPresets(from: url).first else { return }
            selection = .preset(first.id)
        }
        .fileExporter(
            isPresented: $model.transfer.isExporting, document: model.transfer.export,
            contentType: PresetCodec.contentType, defaultFilename: model.transfer.exportName
        ) { result in
            if case .failure(let error) = result {
                model.transfer.message = "AirFlow couldn't save the file. \(error.localizedDescription)"
            }
        }
        .alert("The preset file could not be imported.", isPresented: transferFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.transfer.message ?? "")
        }
        .onAppear {
            model.monitor.visibleSurfaces += 1
            if selection == nil { selection = Self.launchSelection(model) ?? .preset(model.settings.activePresetID) }
            // The first time the window opens, it asks for everything AirFlow needs at once.
            isSettingUp = Self.showsSetup(model)
        }
        .onDisappear { model.monitor.visibleSurfaces -= 1 }
        #if DEBUG
        // A script that records the readings column asks for it to close and open by itself.
        .task {
            // A script that captures Preferences asks for that window by name.
            if ProcessInfo.processInfo.environment["AIRFLOW_SHOW"]?.lowercased() == "preferences" { openSettings() }
            guard ProcessInfo.processInfo.environment["AIRFLOW_TOGGLE_READINGS"] != nil else { return }
            for _ in 0..<2 {
                try? await Task.sleep(for: .seconds(5))
                withAnimation(Anim.standard) { model.settings.showsInspector.toggle() }
            }
        }
        #endif
        .onChange(of: model.presets.custom.map(\.id)) { _, ids in
            // The selected preset was deleted.
            if case .preset(let id) = selection, model.presets.preset(id: id) == nil, !ids.contains(id) {
                selection = .preset(model.settings.activePresetID)
            }
        }
    }

    private var transferFailed: Binding<Bool> {
        Binding {
            model.transfer.message != nil
        } set: { shown in
            if !shown { model.transfer.message = nil }
        }
    }

    /// A Debug build opens on the page that AIRFLOW_SHOW names: rules, sensors, or a preset's
    /// name. The scripts that capture the window use it. A Release build ignores it.
    /// A script that captures the window never gets the sheet, unless it asks for it by name.
    private static func showsSetup(_ model: AppModel) -> Bool {
        #if DEBUG
        if let wanted = ProcessInfo.processInfo.environment["AIRFLOW_SHOW"] { return wanted.lowercased() == "setup" }
        #endif
        return !AppModel.isRunningTests && !model.settings.setupShown
    }

    private static func launchSelection(_ model: AppModel) -> SidebarItem? {
        #if DEBUG
        guard let wanted = ProcessInfo.processInfo.environment["AIRFLOW_SHOW"] else { return nil }
        switch wanted.lowercased() {
        case "apps": return .preset(Preset.adaptiveID)
        case "rules": return .rules
        case "sensors": return .sensors
        default: return model.presets.preset(named: wanted).map { .preset($0.id) }
        }
        #else
        return nil
        #endif
    }

    private var title: String {
        switch selection {
        case .preset(let id): return model.presets.preset(id: id)?.name ?? "AirFlow"
        case .rules: return "Rules"
        case .sensors: return "Sensors"
        case nil: return "AirFlow"
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .preset(let id):
            if let preset = model.presets.preset(id: id) {
                PresetDetail(preset: preset)
                    .id(id)
            } else {
                PageEmptyState(title: "No Preset Selected", message: "Choose a preset in the sidebar.")
            }
        case .rules:
            AutomationView()
        case .sensors:
            SensorsView()
        case nil:
            PageEmptyState(title: "No Preset Selected", message: "Choose a preset in the sidebar.")
        }
    }

    @ToolbarContentBuilder
    private var applyItem: some ToolbarContent {
        // The active preset says so in its header, so it needs no button.
        if case .preset(let id) = selection, let preset = model.presets.preset(id: id), model.settings.activePresetID != id {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.apply(id)
                } label: {
                    Label("Apply", image: "ant-check")
                        .labelStyle(.titleAndIcon)
                        .airFont(.body)
                }
                .buttonStyle(.glassProminent)
                .help("Run the fans with \(preset.name)")
                .keyboardShortcut(.return, modifiers: .command)
                .padding(.top, Self.toolbarDrop)
            }
            .sharedBackgroundVisibility(.hidden)
        }
    }

    /// How far the toolbar's buttons sit below the middle of the bar and in from the window's
    /// edge, so the readings button lies inside the corner of the readings panel and not on it.
    private static let toolbarDrop: CGFloat = 15
    private static let toolbarInset: CGFloat = 8

    /// The readings beside the page: a rounded panel a little in from the window's edges, which
    /// reaches up behind the toolbar as the sidebar does.
    private var readingsPanel: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.panel)
        return LiveInspector()
            .id(model.settings.lookID)
            .frame(width: Layout.inspectorWidth)
            .background {
                shape
                    .fill(.regularMaterial)
                    .overlay(shape.strokeBorder(Palette.hairline(contrast)))
                    .padding(.top, Space.xs)
                    .ignoresSafeArea(.container, edges: .top)
            }
            .padding([.bottom, .trailing], Space.xs)
    }

    @ToolbarContentBuilder
    private var readingsItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                // The column slides in and out at one pace. With no animation it waits and then
                // jumps.
                withAnimation(Anim.allowed(Anim.standard, reduceMotion: reduceMotion)) {
                    model.settings.showsInspector.toggle()
                }
            } label: {
                // The chart's line draws on as the readings arrive and leaves as they go.
                AirAnimation(name: Animations.readings, isReversed: !model.settings.showsInspector, tint: .primary)
                    .frame(width: IconSize.title, height: IconSize.title)
                    .padding(Space.xs)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .antGlass(radius: nil, isInteractive: true)
            .accessibilityLabel("Readings")
            .help(model.settings.showsInspector ? "Hide the readings" : "Show the readings")
            .padding(.top, Self.toolbarDrop)
            .padding(.trailing, Self.toolbarInset)
        }
        // The button draws its own glass, so it can sit where the panel's corner leaves room.
        .sharedBackgroundVisibility(.hidden)
    }
}

private extension View {
    /// The selected row of the sidebar has the accent the person chose in System Settings, whether
    /// or not the window is in front.
    @ViewBuilder
    func selectedInAccent(_ isSelected: Bool) -> some View {
        if isSelected {
            foregroundStyle(.white)
                .listRowBackground(
                    RoundedRectangle(cornerRadius: Radius.md).fill(Palette.accent.gradient).padding(.horizontal, Space.xs + 2)
                )
        } else {
            self
        }
    }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SidebarItem?
    @Binding var isDescribing: Bool
    /// The preset the person asked to delete, until they confirm or cancel.
    @State private var deleting: Preset?

    var body: some View {
        list
            .confirmationDialog(
                "Are you sure you want to delete “\(deleting?.name ?? "")”?",
                isPresented: Binding { deleting != nil } set: { if !$0 { deleting = nil } },
                titleVisibility: .visible, presenting: deleting
            ) { preset in
                Button("Delete", role: .destructive) { model.deletePreset(id: preset.id) }
                Button("Cancel", role: .cancel) {}
            } message: { preset in
                Text(Self.deleteWarning(rules: model.automation.rules.count(where: { $0.presetID == preset.id })))
            }
    }

    /// What deleting a preset costs, in the words of the dialog.
    static func deleteWarning(rules: Int) -> String {
        switch rules {
        case 0: return "You can’t undo this action."
        case 1: return "The rule that uses this preset is deleted too. You can’t undo this action."
        default: return "The \(rules) rules that use this preset are deleted too. You can’t undo this action."
        }
    }

    private var list: some View {
        List(selection: $selection) {
            Section {
                ForEach(Preset.builtIn) { preset in
                    row(for: preset)
                }
                ForEach(model.presets.custom) { preset in
                    row(for: preset)
                }
                .onMove { model.presets.move(fromOffsets: $0, toOffset: $1) }
            } header: {
                Text("Presets").airFont(.label)
            }
            Section {
                Label {
                    Text("Rules").airFont(.body)
                } icon: {
                    AntIcon("ant-branches")
                }
                .badge(model.settings.autopilotEnabled ? Text("Autopilot").font(AirType.label.font) : nil)
                .tag(SidebarItem.rules)
                .selectedInAccent(selection == .rules)
            } header: {
                Text("Automation").airFont(.label)
            }
            Section {
                Label {
                    Text("Sensors").airFont(.body)
                } icon: {
                    AntIcon("ant-dashboard")
                }
                .tag(SidebarItem.sensors)
                .selectedInAccent(selection == .sensors)
            } header: {
                Text("Monitor").airFont(.label)
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: Space.xs) {
                Button {
                    addPreset()
                } label: {
                    Label("New Preset", image: "ant-plus")
                        .labelStyle(.iconOnly)
                }
                .help("Add a preset based on the selected one")
                Button {
                    isDescribing = true
                } label: {
                    Label("Describe a Preset", image: "ant-sparkles")
                        .labelStyle(.iconOnly)
                }
                .help(model.intelligence.availability.reason ?? "Describe a preset and let Apple Intelligence draft it")
                .disabled(!model.intelligence.availability.isAvailable)
                Menu {
                    Button("Import Presets…") { model.transfer.isImporting = true }
                    Button("Export Presets…") { model.beginExport() }
                        .disabled(model.presets.custom.isEmpty)
                } label: {
                    Label("Import and Export", image: "ant-ellipsis")
                        .labelStyle(.iconOnly)
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Import or export presets as a YAML file")
                Spacer()
            }
            .buttonStyle(.glass)
            .tint(nil)
            .padding(Space.sm)
        }
    }

    private func row(for preset: Preset) -> some View {
        let isActive = model.settings.activePresetID == preset.id
        return Label {
            HStack {
                Text(preset.name).airFont(.body)
                Spacer()
                if isActive {
                    // The row's own text style keeps the mark visible when the row is selected.
                    AntIcon("ant-check", size: IconSize.inline)
                        .foregroundStyle(selection == .preset(preset.id) ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                }
            }
        } icon: {
            AntIcon(preset.icon.assetName)
        }
        .tag(SidebarItem.preset(preset.id))
        .selectedInAccent(selection == .preset(preset.id))
        .accessibilityLabel(isActive ? "\(preset.name), active" : preset.name)
        .contextMenu {
            Button {
                model.apply(preset.id)
            } label: {
                Label("Apply", image: "ant-check")
            }
            .disabled(isActive)
            Button {
                if let copy = model.presets.duplicate(id: preset.id) { selection = .preset(copy.id) }
            } label: {
                Label("Duplicate", image: "ant-copy")
            }
            if !preset.isBuiltIn {
                Button {
                    model.beginExport(ids: [preset.id])
                } label: {
                    Label("Export…", image: "ant-export")
                }
                Divider()
                // The dialog asks first, so the menu item ends in an ellipsis.
                Button(role: .destructive) {
                    deleting = preset
                } label: {
                    Label("Delete…", image: "ant-delete")
                }
            }
        }
    }

    /// A new preset starts as a copy of what the selected preset does, so there is something to
    /// change instead of a blank.
    private func addPreset() {
        var source = model.activePreset
        if case .preset(let id) = selection, let selected = model.presets.preset(id: id) { source = selected }
        var preset = Preset(name: "New Preset", icon: .sliders, summary: "")
        switch source.kind {
        case .custom:
            preset.controls = source.controls
            preset.fallback = source.fallback
        case .fullBlast:
            preset.fallback = .constantFraction(1)
        case .automatic, .adaptive:
            preset.fallback = .sensorBased(SensorRule(source: .cpuAverage, startCelsius: 55, maxCelsius: 85))
        }
        selection = .preset(model.presets.add(preset).id)
    }
}
