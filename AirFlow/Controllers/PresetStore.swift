import Foundation
import Observation

/// Reads and writes one Codable value as JSON, replacing the file in one step.
struct JSONFile<Value: Codable> {
    let url: URL

    /// The stored value, or nil when there is none. A file that exists but cannot be read is
    /// moved aside, so the next save does not write over something a person may want back.
    func load() -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            Log.store.error("Could not read \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            let aside = url.appendingPathExtension("unreadable")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: url, to: aside)
            return nil
        }
    }

    func save(_ value: Value) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(value).write(to: url, options: .atomic)
        } catch {
            Log.store.error("Could not write \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    static func inApplicationSupport(_ name: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("AirFlow", isDirectory: true).appendingPathComponent(name)
    }
}

/// The YAML file the person's presets are kept in. It is the same format the app exports, so
/// the file can be read, edited by hand, or copied to another Mac.
struct PresetFile {
    let url: URL

    /// The stored presets, or nil when there is no file. A file that cannot be read is moved
    /// aside, so the next save does not write over something a person may want back.
    func load() -> [Preset]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try PresetCodec.decode(String(decoding: data, as: UTF8.self))
        } catch PresetCodec.Failure.noPresets {
            // A person who deleted every preset has an empty list, not a first launch.
            return []
        } catch {
            Log.store.error("Could not read \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            let aside = url.appendingPathExtension("unreadable")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: url, to: aside)
            return nil
        }
    }

    func save(_ presets: [Preset]) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(try PresetCodec.encode(presets).utf8).write(to: url, options: .atomic)
        } catch {
            Log.store.error("Could not write \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }
}

/// The presets: the two built in, then the person's own in the order they keep them.
@MainActor
@Observable
final class PresetStore {
    private(set) var custom: [Preset]
    @ObservationIgnored private let file: PresetFile?

    /// - Parameter url: where the person's presets are kept, or nil to keep them in memory only.
    init(url: URL?) {
        file = url.map(PresetFile.init)
        if let saved = file?.load() {
            custom = saved
        } else {
            custom = Preset.starters()
            file?.save(custom)
        }
    }

    var presets: [Preset] { Preset.builtIn + custom }

    func preset(id: UUID) -> Preset? {
        presets.first { $0.id == id }
    }

    func preset(named name: String) -> Preset? {
        let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
        return presets.first { $0.name.lowercased() == wanted }
    }

    /// Adds a preset under a name no other preset has, and returns it as stored.
    @discardableResult
    func add(_ preset: Preset) -> Preset {
        let new = prepared(preset)
        custom.append(new)
        save()
        return new
    }

    /// The presets as a YAML document: the ones named, or every preset the person made.
    func exportText(ids: [UUID]? = nil) throws -> String {
        let chosen = ids.map(Set.init).map { ids in custom.filter { ids.contains($0.id) } } ?? custom
        return try PresetCodec.encode(chosen)
    }

    /// Adds every preset in a YAML document. Each one gets a new identifier and a name of its
    /// own, so importing never replaces a preset the person already has.
    @discardableResult
    func importText(_ text: String) throws -> [Preset] {
        // One set of the names in use for the whole document, so each preset costs the same
        // however many there are.
        var names = NameRegistry(taken: presets.map(\.name))
        let added = try PresetCodec.decode(text).map { decoded -> Preset in
            var preset = decoded
            preset.id = UUID()
            preset.kind = .custom
            preset.name = names.claim(Preset.cleanName(decoded.name))
            return preset
        }
        custom.append(contentsOf: added)
        save()
        return added
    }

    private func prepared(_ preset: Preset) -> Preset {
        var new = preset
        new.kind = .custom
        new.name = uniqueName(Preset.cleanName(preset.name), excluding: nil)
        return new
    }

    func update(_ preset: Preset) {
        guard preset.kind == .custom, let index = custom.firstIndex(where: { $0.id == preset.id }) else { return }
        var changed = preset
        changed.name = uniqueName(Preset.cleanName(preset.name), excluding: preset.id)
        guard custom[index] != changed else { return }
        custom[index] = changed
        save()
    }

    func delete(id: UUID) {
        guard let index = custom.firstIndex(where: { $0.id == id }) else { return }
        custom.remove(at: index)
        save()
    }

    @discardableResult
    func duplicate(id: UUID) -> Preset? {
        guard let source = preset(id: id) else { return nil }
        var copy = source
        copy.id = UUID()
        if source.isBuiltIn {
            // The built-in's sentence stops being true once the copy is changed.
            copy.summary = ""
            copy.icon = .sliders
        }
        if source.kind == .fullBlast {
            copy.fallback = .constantFraction(1)
            copy.icon = .fire
        }
        if source.kind == .adaptive {
            // Only the built-in preset is adaptive. Its copy starts as a curve to change.
            copy.fallback = .sensorBased(SensorRule(source: .cpuAverage, startCelsius: 65, maxCelsius: 90))
        }
        copy.name = source.name + " Copy"
        return add(copy)
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        custom.move(fromOffsets: source, toOffset: destination)
        save()
    }

    private func uniqueName(_ name: String, excluding id: UUID?) -> String {
        var names = NameRegistry(taken: presets.filter { $0.id != id }.map(\.name))
        return names.claim(name)
    }

    private func save() {
        file?.save(custom)
    }
}


/// The preset names in use, without regard to case. A name that is taken gets the next free
/// number after it: Quiet, Quiet 2, Quiet 3.
struct NameRegistry {
    private var taken: Set<String>
    /// Where the count for a name stopped, so that many presets with one name do not each count
    /// from 2 again.
    private var nextNumber: [String: Int] = [:]

    init(taken names: some Sequence<String>) {
        taken = Set(names.map { $0.lowercased() })
    }

    mutating func claim(_ name: String) -> String {
        let base = name.isEmpty ? "Untitled Preset" : name
        let key = base.lowercased()
        guard taken.contains(key) else {
            taken.insert(key)
            return base
        }
        var number = nextNumber[key] ?? 2
        while taken.contains("\(key) \(number)") { number += 1 }
        nextNumber[key] = number + 1
        taken.insert("\(key) \(number)")
        return "\(base) \(number)"
    }
}
