import Foundation

/// The icon a preset carries: one of Ant Design's outlined icons, or one of AirFlow's own two.
/// The raw value is the icon's name in the asset catalog after the `ant-` prefix, and it is what
/// a presets file stores.
struct PresetIcon: RawRepresentable, Hashable, Codable, Sendable, Identifiable {
    let rawValue: String

    /// Nil for a name that is not an icon AirFlow has.
    init?(rawValue: String) {
        guard Self.names.contains(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    private init(known name: String) {
        rawValue = name
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let name = try container.decode(String.self)
        guard let icon = PresetIcon(rawValue: name) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "“\(name)” is not an icon AirFlow has.")
        }
        self = icon
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var id: String { rawValue }

    var assetName: String { "ant-\(rawValue)" }

    /// The icon's name as a person reads it: “Video Camera” for `video-camera`.
    var title: String {
        Self.titles[rawValue] ?? rawValue.split(separator: "-").map(\.capitalized).joined(separator: " ")
    }

    /// The names that are not words, as their owners write them.
    private static let titles = [
        "api": "API", "ci": "CI", "ci-circle": "CI Circle", "dot-net": ".NET", "gif": "GIF", "file-gif": "File GIF",
        "file-jpg": "File JPG", "file-pdf": "File PDF", "file-ppt": "File PPT", "github": "GitHub", "gitlab": "GitLab",
        "harmony-o-s": "HarmonyOS", "hdd": "HDD", "html5": "HTML5", "idcard": "ID Card", "ie": "IE", "java-script": "JavaScript",
        "linkedin": "LinkedIn", "open-a-i": "OpenAI", "qq": "QQ", "qrcode": "QR Code", "tik-tok": "TikTok", "usb": "USB",
        "wechat": "WeChat", "wechat-work": "WeChat Work", "whats-app": "WhatsApp", "wifi": "Wi-Fi", "youtube": "YouTube",
        "console-sql": "Console SQL",
    ]

    private static let names = Set(AntIconCatalog.names)

    /// Every icon, in the order of their names.
    static let allCases: [PresetIcon] = AntIconCatalog.names.map(PresetIcon.init(known:))

    /// Automatic's icon: macOS runs the fans.
    static let apple = PresetIcon(known: "apple")
    /// Full Blast's icon.
    static let thunderbolt = PresetIcon(known: "thunderbolt")
    /// Adaptive's icon, and the mark of everything Apple Intelligence does. No other preset takes it.
    static let sparkles = PresetIcon(known: "sparkles")
    static let airplane = PresetIcon(known: "airplane")
    static let cloud = PresetIcon(known: "cloud")
    static let coffee = PresetIcon(known: "coffee")
    static let compass = PresetIcon(known: "compass")
    static let dashboard = PresetIcon(known: "dashboard")
    static let fire = PresetIcon(known: "fire")
    static let moon = PresetIcon(known: "moon")
    static let rocket = PresetIcon(known: "rocket")
    static let sliders = PresetIcon(known: "sliders")
    static let sound = PresetIcon(known: "sound")
    static let videoCamera = PresetIcon(known: "video-camera")

    /// The icons that mark the built-in presets. A preset a person makes takes none of them, so
    /// it is never taken for a built-in one.
    static let reserved: Set<PresetIcon> = [.apple, .thunderbolt, .sparkles]

    /// The icons offered for a preset a person makes.
    static let choices: [PresetIcon] = allCases.filter { !reserved.contains($0) }

    /// The choices whose name holds every word of the text, whatever its case. No text is every
    /// choice.
    static func choices(matching text: String) -> [PresetIcon] {
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return choices.filter { icon in
            let name = (icon.title + " " + icon.rawValue).lowercased()
            return words.allSatisfy { name.contains($0) }
        }
    }
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

    /// A built-in preset's identifier, `A1F10000-0000-4000-8000-00000000000N`. Stored settings
    /// and rules name a built-in preset by it, so it never changes.
    private static func builtInID(_ number: UInt8) -> UUID {
        UUID(uuid: (0xA1, 0xF1, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, number))
    }

    static let automaticID = builtInID(1)
    static let fullBlastID = builtInID(2)

    static let automatic = Preset(
        id: automaticID, name: "Automatic", icon: .apple, kind: .automatic,
        summary: "macOS controls every fan."
    )

    static let fullBlast = Preset(
        id: fullBlastID, name: "Full Blast", icon: .thunderbolt, kind: .fullBlast,
        summary: "Every fan runs at full speed."
    )

    static let adaptiveID = builtInID(3)

    static let adaptive = Preset(
        id: adaptiveID, name: "Adaptive", icon: .sparkles, kind: .adaptive,
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
                name: "Travel", icon: .airplane,
                // Below the start, macOS has the fans, so a hot CPU is still cooled on a cool battery.
                fallback: .sensorBased(SensorRule(source: .group(.battery, .average), startCelsius: 33, maxCelsius: 43, belowStart: .automatic)),
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
