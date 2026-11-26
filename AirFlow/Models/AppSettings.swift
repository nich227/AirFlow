import Foundation
import Observation

/// What the menu bar item shows beside its icon.
enum MenuBarReadout: String, CaseIterable, Identifiable, Codable, Sendable {
    case none, fastestFan, cpu, gpu, fanAndCPU

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "Icon Only"
        case .fastestFan: return "Fastest Fan"
        case .cpu: return "CPU Temperature"
        case .gpu: return "GPU Temperature"
        case .fanAndCPU: return "Fan and CPU Temperature"
        }
    }
}

/// The preferences, kept in UserDefaults. Each property writes itself when it changes.
@MainActor
@Observable
final class AppSettings {
    enum Key {
        static let temperatureUnit = "temperatureUnit"
        static let preciseTemperatures = "preciseTemperatures"
        static let menuBarReadout = "menuBarReadout"
        static let safeguardEnabled = "safeguardEnabled"
        static let safeguardLimit = "safeguardLimit"
        static let autopilotEnabled = "autopilotEnabled"
        static let activePresetID = "activePresetID"
        static let showsInspector = "showsInspector"
        static let welcomeShown = "welcomeShown"
        static let setupShown = "setupShown"
        static let colorPalette = "colorPalette"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var temperatureUnit: TemperatureUnit { didSet { defaults.set(temperatureUnit.rawValue, forKey: Key.temperatureUnit) } }
    var preciseTemperatures: Bool { didSet { defaults.set(preciseTemperatures, forKey: Key.preciseTemperatures) } }
    var menuBarReadout: MenuBarReadout { didSet { defaults.set(menuBarReadout.rawValue, forKey: Key.menuBarReadout) } }
    var safeguardEnabled: Bool { didSet { defaults.set(safeguardEnabled, forKey: Key.safeguardEnabled) } }
    var safeguardLimit: Double { didSet { defaults.set(safeguardLimit, forKey: Key.safeguardLimit) } }
    var autopilotEnabled: Bool { didSet { defaults.set(autopilotEnabled, forKey: Key.autopilotEnabled) } }
    var activePresetID: UUID { didSet { defaults.set(activePresetID.uuidString, forKey: Key.activePresetID) } }
    var showsInspector: Bool { didSet { defaults.set(showsInspector, forKey: Key.showsInspector) } }
    var welcomeShown: Bool { didSet { defaults.set(welcomeShown, forKey: Key.welcomeShown) } }
    /// True once the person has been through the setup sheet, which asks for every permission at once.
    var setupShown: Bool { didSet { defaults.set(setupShown, forKey: Key.setupShown) } }
    /// The colors of the temperatures and the charts. The drawing code reads `ColorPalette.current`.
    var colorPalette: ColorPalette {
        didSet {
            defaults.set(colorPalette.rawValue, forKey: Key.colorPalette)
            ColorPalette.current = colorPalette
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        temperatureUnit = defaults.string(forKey: Key.temperatureUnit).flatMap(TemperatureUnit.init) ?? .celsius
        preciseTemperatures = defaults.bool(forKey: Key.preciseTemperatures)
        menuBarReadout = defaults.string(forKey: Key.menuBarReadout).flatMap(MenuBarReadout.init) ?? .fanAndCPU
        safeguardEnabled = defaults.object(forKey: Key.safeguardEnabled) as? Bool ?? true
        let limit = defaults.object(forKey: Key.safeguardLimit) as? Double ?? Safeguard.defaultLimit
        safeguardLimit = min(max(limit, Safeguard.limitRange.lowerBound), Safeguard.limitRange.upperBound)
        autopilotEnabled = defaults.bool(forKey: Key.autopilotEnabled)
        activePresetID = defaults.string(forKey: Key.activePresetID).flatMap(UUID.init) ?? Preset.automaticID
        showsInspector = defaults.object(forKey: Key.showsInspector) as? Bool ?? true
        welcomeShown = defaults.bool(forKey: Key.welcomeShown)
        setupShown = defaults.bool(forKey: Key.setupShown)
        colorPalette = defaults.string(forKey: Key.colorPalette).flatMap(ColorPalette.init) ?? .standard
        ColorPalette.current = colorPalette
    }

    var format: ReadingFormat {
        ReadingFormat(unit: temperatureUnit, isPrecise: preciseTemperatures)
    }
}
