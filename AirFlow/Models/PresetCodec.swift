import Foundation
import UniformTypeIdentifiers
import Yams

/// Presets as a YAML document that a person can read, edit, and share.
///
///     airflow: 1
///     presets:
///       - name: Quiet
///         icon: coffee
///         summary: Fans stay at their minimum until the CPU is hot.
///         fans:
///           mode: sensor
///           sensor: cpu average
///           start: 70
///           full: 95
///         overrides:
///           - fan: 2
///             mode: constant
///             rpm: 3200
///
/// `fans` is the control for every fan, and `overrides` changes it for one fan, counted from 1. A
/// file is only data. Every number in it goes through the same limits as a preset made in the app.
/// Nothing in a file can name a command or a path.
enum PresetCodec {
    static let version = 1
    static let fileExtension = "yaml"
    static let contentType = UTType.yaml
    /// Limits on a file that is read, so a mistaken or hostile file cannot stall the app.
    static let maximumBytes = 1_000_000
    static let maximumPresets = 200
    static let maximumFans = 16

    static let header = """
        # AirFlow fan presets.
        # mode is automatic, constant (with rpm, or percent of the fan's range), or sensor
        # (with sensor, start, and full, in degrees Celsius).

        """

    enum Failure: Error, Equatable, LocalizedError {
        case tooLarge
        case notYAML(String)
        case newerVersion(Int)
        case noPresets
        case tooManyPresets
        case invalid(preset: String, reason: String)

        var errorDescription: String? {
            switch self {
            case .tooLarge: return "The file is too large to be a list of presets."
            case .notYAML(let detail): return "The file isn't a list of AirFlow presets. \(detail)"
            case .newerVersion(let version): return "This file was created by a newer version of AirFlow (format \(version))."
            case .noPresets: return "The file has no presets."
            case .tooManyPresets: return "The file has more than \(PresetCodec.maximumPresets) presets."
            case .invalid(let preset, let reason): return "The preset “\(preset)” can't be read: \(reason)"
            }
        }
    }

    // MARK: - The document, as it is read

    struct Document: Decodable {
        var airflow: Int
        var presets: [Record]
    }

    struct Record: Decodable {
        var id: String?
        var name: String
        var icon: String?
        var summary: String?
        var fans: Control
        var overrides: [Control]?
    }

    struct Control: Decodable {
        /// The fan an override is for, counted from 1. Absent in `fans`.
        var fan: Int?
        var mode: String
        var rpm: Number?
        var percent: Number?
        var sensor: String?
        var start: Number?
        var full: Number?
    }

    /// A number that a person may have written with or without a decimal point.
    struct Number: Decodable, Equatable {
        var value: Double

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let whole = try? container.decode(Int.self) {
                value = Double(whole)
            } else {
                value = try container.decode(Double.self)
            }
        }
    }

    // MARK: - Writing

    /// The presets as YAML. The text is written line by line, so a file always has the same
    /// plain shape: one key per line, whole numbers as whole numbers, and quotes only where
    /// YAML needs them.
    static func encode(_ presets: [Preset]) throws -> String {
        let custom = presets.filter { $0.kind == .custom }
        var lines = ["airflow: \(version)"]
        guard !custom.isEmpty else { return header + lines.joined(separator: "\n") + "\npresets: []\n" }
        lines.append("presets:")
        for preset in custom {
            lines.append("  - id: \(preset.id.uuidString)")
            lines.append("    name: \(scalar(preset.name))")
            lines.append("    icon: \(scalar(preset.icon.rawValue))")
            if !preset.summary.isEmpty { lines.append("    summary: \(scalar(preset.summary))") }
            lines.append("    fans:")
            lines += control(preset.fallback).map { "      " + $0 }
            let overrides = preset.controls.keys.sorted()
            guard !overrides.isEmpty else { continue }
            lines.append("    overrides:")
            for index in overrides {
                guard let override = preset.controls[index] else { continue }
                lines.append("      - fan: \(index + 1)")
                lines += control(override).map { "        " + $0 }
            }
        }
        return header + lines.joined(separator: "\n") + "\n"
    }

    private static func control(_ control: FanControl) -> [String] {
        switch control {
        case .automatic:
            return ["mode: automatic"]
        case .constant(let rpm):
            return ["mode: constant", "rpm: \(number(rpm))"]
        case .constantFraction(let fraction):
            return ["mode: constant", "percent: \(number(fraction * 100))"]
        case .sensorBased(let rule):
            return [
                "mode: sensor", "sensor: \(scalar(name(of: rule.source)))",
                "start: \(number(rule.startCelsius))", "full: \(number(rule.maxCelsius))",
            ]
        }
    }

    /// "70" for a whole number, and at most two decimals otherwise.
    static func number(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        let rounded = (value * 100).rounded() / 100
        if rounded == rounded.rounded(), abs(rounded) < 1e12 { return String(Int(rounded)) }
        var text = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), rounded)
        while text.hasSuffix("0") { text.removeLast() }
        return text
    }

    private static let reservedWords: Set<String> = ["true", "false", "yes", "no", "on", "off", "null", "y", "n"]

    /// A string as a YAML scalar. Text made of letters, digits, spaces, and a few marks is
    /// written bare. Anything YAML could read as something else is written in double quotes,
    /// where YAML takes the same escapes as JSON.
    static func scalar(_ text: String) -> String {
        let plainMarks: Set<Character> = [" ", ".", "-", "'", ",", "°", "(", ")", "%"]
        let safe = text.first.map { $0.isASCII && $0.isLetter } == true
            && text.last != " "
            && text.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || plainMarks.contains($0) }
            && !reservedWords.contains(text.lowercased())
        if safe { return text }
        var quoted = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": quoted += "\\\""
            case "\\": quoted += "\\\\"
            case "\n": quoted += "\\n"
            case "\r": quoted += "\\r"
            case "\t": quoted += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F || scalar.value == 0x85 || scalar.value == 0x2028 || scalar.value == 0x2029 {
                    quoted += String(format: "\\u%04X", scalar.value)
                } else {
                    quoted.unicodeScalars.append(scalar)
                }
            }
        }
        return quoted + "\""
    }

    static func name(of source: SensorSource) -> String {
        switch source {
        case .group(let group, let reduction): return "\(group.rawValue) \(reduction.rawValue)"
        case .key(let key): return "key \(key)"
        }
    }

    // MARK: - Reading

    /// The presets in a document, with every value checked. A preset keeps the identifier the
    /// file gives it, or gets a new one.
    static func decode(_ text: String) throws -> [Preset] {
        guard text.utf8.count <= maximumBytes else { throw Failure.tooLarge }
        let document: Document
        do {
            document = try YAMLDecoder().decode(Document.self, from: text)
        } catch {
            throw Failure.notYAML(describe(error))
        }
        guard document.airflow <= version else { throw Failure.newerVersion(document.airflow) }
        guard !document.presets.isEmpty else { throw Failure.noPresets }
        guard document.presets.count <= maximumPresets else { throw Failure.tooManyPresets }
        return try document.presets.map(preset)
    }

    private static func preset(_ record: Record) throws -> Preset {
        let name = Preset.cleanName(record.name)
        let label = name.isEmpty ? "Untitled Preset" : name
        var controls: [Int: FanControl] = [:]
        for override in record.overrides ?? [] {
            guard let fan = override.fan, (1...maximumFans).contains(fan) else {
                throw Failure.invalid(preset: label, reason: "an override needs a fan number from 1 to \(maximumFans).")
            }
            controls[fan - 1] = try control(override, preset: label)
        }
        return Preset(
            id: record.id.flatMap(UUID.init) ?? UUID(),
            name: label,
            icon: record.icon.flatMap(PresetIcon.init) ?? .sliders,
            controls: controls,
            fallback: try control(record.fans, preset: label),
            summary: String((record.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
        )
    }

    private static func control(_ control: Control, preset: String) throws -> FanControl {
        switch control.mode.lowercased() {
        case "automatic", "auto":
            return .automatic
        case "constant":
            if let rpm = control.rpm?.value, rpm.isFinite {
                return .constant(rpm: min(max(rpm, 0), 100_000))
            }
            if let percent = control.percent?.value, percent.isFinite {
                return .constantFraction(min(max(percent, 0), 100) / 100)
            }
            throw Failure.invalid(preset: preset, reason: "a constant speed needs rpm or percent.")
        case "sensor", "sensor-based", "sensorbased":
            guard let start = control.start?.value, let full = control.full?.value, start.isFinite, full.isFinite else {
                throw Failure.invalid(preset: preset, reason: "a sensor mode needs start and full temperatures.")
            }
            guard let source = source(named: control.sensor ?? "cpu average") else {
                throw Failure.invalid(preset: preset, reason: "“\(control.sensor ?? "")” isn't a sensor AirFlow knows.")
            }
            return .sensorBased(SensorRule(source: source, startCelsius: start, maxCelsius: full))
        default:
            throw Failure.invalid(preset: preset, reason: "“\(control.mode)” isn't a mode. Use automatic, constant, or sensor.")
        }
    }

    static func source(named name: String) -> SensorSource? {
        let words = name.lowercased().split(separator: " ").map(String.init)
        guard let first = words.first else { return nil }
        if first == "key", words.count == 2, let key = name.split(separator: " ").last, key.count == 4 {
            return .key(String(key))
        }
        guard let group = SensorGroup(rawValue: first) else { return nil }
        guard words.count > 1 else { return .group(group, .average) }
        guard words.count == 2, let reduction = SensorReduction(rawValue: words[1]) else { return nil }
        return .group(group, reduction)
    }

    private static func describe(_ error: Error) -> String {
        if case DecodingError.keyNotFound(let key, _) = error { return "It has no “\(key.stringValue)”." }
        if case DecodingError.typeMismatch(_, let context) = error, let key = context.codingPath.last {
            return "The value of “\(key.stringValue)” is the wrong kind."
        }
        return "Check that it is YAML with a list named “presets”."
    }
}
