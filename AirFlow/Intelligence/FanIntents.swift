import AppIntents
import Foundation

/// A preset as Siri, Spotlight, and Shortcuts see it.
struct PresetEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Fan Preset"
    static let defaultQuery = PresetQuery()

    let id: UUID
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    init(_ preset: Preset) {
        id = preset.id
        name = preset.name
    }
}

struct PresetQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [PresetEntity] {
        Self.entities(for: identifiers, in: AppModel.shared.presets)
    }

    @MainActor
    func entities(matching string: String) async throws -> [PresetEntity] {
        Self.entities(matching: string, in: AppModel.shared.presets)
    }

    @MainActor
    func suggestedEntities() async throws -> [PresetEntity] {
        Self.entities(matching: "", in: AppModel.shared.presets)
    }

    /// The presets with these identifiers that still exist, in the order asked for.
    @MainActor
    static func entities(for identifiers: [UUID], in store: PresetStore) -> [PresetEntity] {
        identifiers.compactMap { store.preset(id: $0) }.map(PresetEntity.init)
    }

    /// The presets whose name holds the text, whatever its case. No text matches every preset.
    @MainActor
    static func entities(matching string: String, in store: PresetStore) -> [PresetEntity] {
        let wanted = string.lowercased()
        return store.presets
            .filter { wanted.isEmpty || $0.name.lowercased().contains(wanted) }
            .map(PresetEntity.init)
    }
}

struct ApplyPresetIntent: AppIntent {
    static let title: LocalizedStringResource = "Apply Fan Preset"
    static let description = IntentDescription("Changes the preset AirFlow uses to run the fans.")

    @Parameter(title: "Preset")
    var preset: PresetEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Apply \(\.$preset)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "\(Self.apply(preset, to: AppModel.shared))")
    }

    /// Makes the preset the current one, and says what happened.
    @MainActor
    static func apply(_ preset: PresetEntity, to model: AppModel) -> String {
        guard model.presets.preset(id: preset.id) != nil else {
            return "AirFlow no longer has a preset named \(preset.name)."
        }
        model.apply(preset.id, by: .siri)
        if model.helper.status.allowsControl {
            return "AirFlow is using \(preset.name)."
        }
        return "AirFlow is set to \(preset.name), but fan control isn't turned on."
    }
}

struct FanStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Fan Status"
    static let description = IntentDescription("Reports the fan speeds, the CPU temperature, and the active preset.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let status = await Self.status(of: AppModel.shared)
        return .result(value: status, dialog: "\(status)")
    }

    /// One sentence about the fans now. A model that has not read the Mac yet reads it first.
    @MainActor
    static func status(of model: AppModel) async -> String {
        if !model.monitor.hasLoaded { await model.monitor.refresh() }
        return FanStatus.sentence(
            snapshot: model.monitor.snapshot, presetName: model.activePreset.name, format: model.settings.format
        )
    }
}

enum FanStatus {
    /// One spoken sentence about the fans and the CPU.
    static func sentence(snapshot: ThermalSnapshot, presetName: String, format: ReadingFormat) -> String {
        guard !snapshot.fans.isEmpty else {
            return "This Mac has no fans that AirFlow can read."
        }
        let fans = snapshot.fans
            .map { "\($0.name) is at \(ReadingFormat.rpmWithUnit($0.currentRPM))" }
            .formatted(.list(type: .and))
        var sentence = "\(fans)."
        if let cpu = snapshot.summary(of: .cpu) {
            sentence += " The CPU is at \(format.spokenTemperature(cpu.average))."
        }
        return sentence + " The preset is \(presetName)."
    }
}

struct AirFlowShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ApplyPresetIntent(),
            phrases: [
                "Apply \(\.$preset) in \(.applicationName)",
                "Set \(.applicationName) to \(\.$preset)",
            ],
            shortTitle: "Apply Preset",
            systemImageName: "fan"
        )
        AppShortcut(
            intent: FanStatusIntent(),
            phrases: [
                "What are my fans doing in \(.applicationName)",
                "Get fan status from \(.applicationName)",
            ],
            shortTitle: "Fan Status",
            systemImageName: "thermometer.medium"
        )
    }
}
