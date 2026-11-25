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
        identifiers.compactMap { AppModel.shared.presets.preset(id: $0) }.map(PresetEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [PresetEntity] {
        let wanted = string.lowercased()
        return AppModel.shared.presets.presets
            .filter { $0.name.lowercased().contains(wanted) }
            .map(PresetEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [PresetEntity] {
        AppModel.shared.presets.presets.map(PresetEntity.init)
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
        let model = AppModel.shared
        guard model.presets.preset(id: preset.id) != nil else {
            return .result(dialog: "AirFlow no longer has a preset named \(preset.name).")
        }
        model.apply(preset.id, by: .siri)
        if model.helper.status.allowsControl {
            return .result(dialog: "AirFlow is using \(preset.name).")
        }
        return .result(dialog: "AirFlow is set to \(preset.name), but fan control isn't turned on.")
    }
}

struct FanStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Fan Status"
    static let description = IntentDescription("Reports the fan speeds, the CPU temperature, and the active preset.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let model = AppModel.shared
        if !model.monitor.hasLoaded { await model.monitor.refresh() }
        let status = FanStatus.sentence(
            snapshot: model.monitor.snapshot, presetName: model.activePreset.name, format: model.settings.format
        )
        return .result(value: status, dialog: "\(status)")
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
