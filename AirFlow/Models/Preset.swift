import Foundation

/// The Ant Design icons a preset can carry. The raw value is the icon's name in the asset catalog
/// after the `ant-` prefix.
enum PresetIcon: String, Codable, CaseIterable, Sendable, Identifiable {
    case sync, thunderbolt, coffee, rocket, compass
    case moon, sun, fire, code, videoCamera = "video-camera", experiment, laptop, desktop, home
    case sound, car, cloud, dashboard, sliders, heart, star
    case aim

    var id: String { rawValue }

    var assetName: String { "ant-\(rawValue)" }

    /// The icons offered for a preset a person makes.
    static let choices: [PresetIcon] = allCases.filter { $0 != .sync && $0 != .thunderbolt && $0 != .aim }
}

/// A named way to run the fans.
struct Preset: Identifiable, Equatable, Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// The system controls every fan. Built in.
        case automatic
        /// Every fan at its maximum. Built in.
        case fullBlast
        /// The predictive controller chooses each fan's speed. Built in.
        case adaptive
        case custom
    }

    var id: UUID
    var name: String
    var icon: PresetIcon
    var kind: Kind
    /// Controls set for particular fans, by fan index.
    var controls: [Int: FanControl]
    /// The control for every fan not listed in `controls`.
    var fallback: FanControl
    /// One sentence that says what the preset is for.
    var summary: String

    init(
        id: UUID = UUID(), name: String, icon: PresetIcon, kind: Kind = .custom,
        controls: [Int: FanControl] = [:], fallback: FanControl = .automatic, summary: String = ""
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.kind = kind
        self.controls = controls
        self.fallback = fallback
        self.summary = summary
    }

    var isBuiltIn: Bool { kind != .custom }

    func control(for fan: Fan) -> FanControl {
        switch kind {
        // The adaptive controller's speed comes from FanPlanner.plan, not from a control.
        case .automatic, .adaptive: return .automatic
        case .fullBlast: return .constantFraction(1)
        case .custom: return controls[fan.index] ?? fallback
        }
    }

    mutating func setControl(_ control: FanControl, for fan: Fan) {
        guard kind == .custom else { return }
        controls[fan.index] = control
    }

    static let automaticID = UUID(uuidString: "A1F10000-0000-4000-8000-000000000001") ?? UUID()
    static let fullBlastID = UUID(uuidString: "A1F10000-0000-4000-8000-000000000002") ?? UUID()

    static let automatic = Preset(
        id: automaticID, name: "Automatic", icon: .sync, kind: .automatic,
        summary: "macOS controls every fan."
    )

    static let fullBlast = Preset(
        id: fullBlastID, name: "Full Blast", icon: .thunderbolt, kind: .fullBlast,
        summary: "Every fan runs at full speed."
    )

    static let adaptiveID = UUID(uuidString: "A1F10000-0000-4000-8000-000000000003") ?? UUID()

    static let adaptive = Preset(
        id: adaptiveID, name: "Adaptive", icon: .aim, kind: .adaptive,
        summary: "Fans adapt to what your Mac is doing and what it's about to do."
    )

    static let builtIn = [automatic, adaptive, fullBlast]

    /// The presets a new installation starts with. A person can change or delete them.
    static func starters() -> [Preset] {
        [
            Preset(
                name: "Quiet", icon: .coffee,
                fallback: .sensorBased(SensorRule(source: .cpuAverage, startCelsius: 70, maxCelsius: 95)),
                summary: "Fans stay at minimum speed until the CPU gets hot."
            ),
            Preset(
                name: "Heavy Workload", icon: .rocket,
                fallback: .sensorBased(SensorRule(source: .cpuAverage, startCelsius: 45, maxCelsius: 75)),
                summary: "Fans speed up early to keep temperatures down during long tasks."
            ),
            Preset(
                name: "Travel", icon: .compass,
                fallback: .sensorBased(SensorRule(source: .group(.battery, .average), startCelsius: 33, maxCelsius: 43)),
                summary: "Fans follow the battery temperature, for a Mac on your lap."
            ),
        ]
    }

    /// The fields a person may set, with the name trimmed and bounded.
    static func cleanName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(40)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
