import Foundation
import FoundationModels
import Observation

// The shapes the on-device model fills in. Guided generation makes the model return exactly
// these fields, so its answer is data and never text to parse.

@Generable(description: "How the fans are driven")
enum DraftMode {
    case automatic
    case constant
    case sensorBased
}

@Generable(description: "A part of the Mac that has temperature sensors")
enum DraftSensor {
    case cpu
    case gpu
    case battery
    case storage
    case enclosure

    var group: SensorGroup {
        switch self {
        case .cpu: return .cpu
        case .gpu: return .gpu
        case .battery: return .battery
        case .storage: return .storage
        case .enclosure: return .enclosure
        }
    }
}

@Generable(description: "A cooling preset for the fans of a Mac")
struct PresetDraft {
    @Guide(description: "A short title of one to three words, in title case, with no quotation marks")
    var name: String
    @Guide(description: "automatic leaves the fans to macOS. constant holds one speed. sensorBased makes the fans follow a temperature.")
    var mode: DraftMode
    @Guide(description: "For constant: the share of the fan's range, where 0 is the slowest and 100 is the fastest", .range(0...100))
    var speedPercent: Int
    @Guide(description: "For sensorBased: the part of the Mac whose temperature the fans follow. Use cpu unless the request names another part.")
    var sensor: DraftSensor
    @Guide(description: "For sensorBased: the temperature in degrees Celsius where the fans start to speed up", .range(30...95))
    var startCelsius: Int
    @Guide(description: "For sensorBased: the temperature in degrees Celsius where the fans reach full speed. It is higher than startCelsius.", .range(40...105))
    var fullSpeedCelsius: Int
    @Guide(description: "One plain sentence that says what the preset does")
    var summary: String

    var proposal: PresetProposal {
        let mode: PresetProposal.Mode
        switch self.mode {
        case .automatic: mode = .automatic
        case .constant: mode = .constant
        case .sensorBased: mode = .sensorBased
        }
        return PresetProposal(
            name: name, mode: mode, speedPercent: speedPercent, sensor: sensor.group,
            startCelsius: startCelsius, fullSpeedCelsius: fullSpeedCelsius, summary: summary
        )
    }
}

@Generable(description: "How hard an app works a computer")
enum DraftWorkload {
    case light
    case bursty
    case sustained
}

@Generable(description: "The apps on a Mac that are known for heavy work")
struct AppSelectionDraft {
    @Guide(description: "The names of the apps known for heavy work, each copied exactly from the list. Empty if none fit.")
    var names: [String]
}

@Generable(description: "What kind of load an app puts on a Mac")
struct WorkloadDraft {
    @Guide(description: "light: browsing, writing, chat, coding without long builds. bursty: short heavy spikes, such as photo editing or compiling. sustained: minutes of heavy load, such as video export, 3D rendering, or running a language model.")
    var workload: DraftWorkload
    @Guide(description: "One short sentence that says why, in plain words.")
    var reason: String

    var proposal: WorkloadProposal {
        let regime: WorkloadRegime
        switch workload {
        case .light: regime = .light
        case .bursty: regime = .bursty
        case .sustained: regime = .sustained
        }
        return WorkloadProposal(regime: regime, reason: reason)
    }
}

@Generable(description: "What makes an automation rule apply")
enum DraftTrigger {
    case app
    case battery
    case adapter
    case temperature
    case time
}

@Generable(description: "A rule that applies a fan preset when a condition holds")
struct RuleDraft {
    @Guide(description: "app: a named app is in front. battery: the Mac runs on battery. adapter: the Mac is plugged in. temperature: a part gets hotter than a limit. time: a time of day.")
    var trigger: DraftTrigger
    @Guide(description: "For app: the app's name as written in the request. Otherwise an empty string.")
    var appName: String
    @Guide(description: "For temperature: the part of the Mac. Use cpu unless the request names another part.")
    var sensor: DraftSensor
    @Guide(description: "For temperature: the limit in degrees Celsius", .range(30...105))
    var celsius: Int
    @Guide(description: "For time: the hour the rule starts, on a 24 hour clock", .range(0...23))
    var startHour: Int
    @Guide(description: "For time: the hour the rule ends, on a 24 hour clock", .range(0...23))
    var endHour: Int
    @Guide(description: "The name of the preset to apply. It must be one of the available presets, spelled the same way.")
    var presetName: String

    var proposal: RuleProposal {
        let trigger: RuleProposal.Trigger
        switch self.trigger {
        case .app: trigger = .app
        case .battery: trigger = .battery
        case .adapter: trigger = .adapter
        case .temperature: trigger = .temperature
        case .time: trigger = .time
        }
        return RuleProposal(
            trigger: trigger, appName: appName, sensor: sensor.group, celsius: celsius,
            startHour: startHour, endHour: endHour, presetName: presetName
        )
    }
}

enum IntelligenceError: Error, LocalizedError, Equatable {
    case unavailable(String)
    case emptyRequest
    case noHistory
    case failed

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return reason
        case .emptyRequest: return "Enter a description first."
        case .noHistory: return "AirFlow needs a few more seconds of readings before it can explain them."
        case .failed: return "Apple Intelligence couldn't draft that. Try describing it another way."
        }
    }
}

/// The on-device Apple Intelligence model. It drafts presets and rules and explains readings. It
/// has no way to reach a fan. Every draft comes back as a proposal for a person to approve.
@MainActor
@Observable
final class IntelligenceService {
    enum Availability: Equatable {
        case available
        case unavailable(String)

        var isAvailable: Bool { self == .available }

        var reason: String? {
            if case .unavailable(let reason) = self { return reason }
            return nil
        }
    }

    private(set) var availability: Availability = .unavailable("Checking for Apple Intelligence…")

    static let requestLimit = 300

    static let presetInstructions = """
        You design cooling presets for AirFlow, an app that controls the fans of a Mac. \
        Turn the person's request into one preset. \
        A lower starting temperature makes the fans louder sooner and keeps the Mac cooler. \
        A request for quiet means a starting temperature of 70 or more. \
        A request for cooling or heavy work means a starting temperature between 45 and 55. \
        Prefer sensorBased. Use constant only when the request asks for a fixed speed. \
        Use automatic only when the request asks to let the Mac decide.
        """

    static let ruleInstructions = """
        You write automation rules for AirFlow, an app that controls the fans of a Mac. \
        Turn the person's request into one rule. Choose the preset from the available presets only.
        """

    static let workloadInstructions = """
        You judge how hard a Mac app works the computer, from the app's name alone. \
        Choose light, bursty, or sustained. If you do not know the app, choose light. \
        Give one short sentence that says why. Do not give advice.
        """

    static let heavyAppsInstructions = """
        You are given the names of the apps on a Mac, one on each line. Choose only the apps that are \
        known to work the computer hard for more than a moment: video editing and export, 3D, games, \
        building code, virtual machines, photo editing, and running language models. \
        Copy each name exactly as it is given. Leave out an app you do not know. If none fit, choose none.
        """

    static let explainInstructions = """
        You explain a Mac's recent temperatures and fan speeds to its owner in two short sentences. \
        Use plain words and the numbers you are given. Do not give advice about hardware safety, \
        and do not mention anything you were not told.
        """

    init() {
        refreshAvailability()
    }

    func refreshAvailability() {
        switch SystemLanguageModel.default.availability {
        case .available:
            availability = .available
        case .unavailable(.deviceNotEligible):
            availability = .unavailable("Apple Intelligence is not supported on this Mac.")
        case .unavailable(.appleIntelligenceNotEnabled):
            availability = .unavailable("Turn on Apple Intelligence in System Settings to draft presets from a description.")
        case .unavailable(.modelNotReady):
            availability = .unavailable("Apple Intelligence is still downloading. Try again later.")
        case .unavailable:
            availability = .unavailable("Apple Intelligence is not currently available. Try again later.")
        }
    }

    func draftPreset(from request: String) async throws -> PresetProposal {
        let text = try checked(request)
        let session = LanguageModelSession(instructions: Self.presetInstructions)
        do {
            return try await session.respond(to: text, generating: PresetDraft.self).content.proposal
        } catch {
            throw failure(error)
        }
    }

    func draftRule(from request: String, presetNames: [String]) async throws -> RuleProposal {
        let text = try checked(request)
        let session = LanguageModelSession(instructions: Self.ruleInstructions)
        let prompt = "Available presets: \(presetNames.joined(separator: ", ")).\nRequest: \(text)"
        do {
            return try await session.respond(to: prompt, generating: RuleDraft.self).content.proposal
        } catch {
            throw failure(error)
        }
    }

    /// Proposes what an app is known for. Nothing is saved. The person sees the proposal and
    /// decides.
    func suggestWorkload(appName: String) async throws -> WorkloadProposal {
        let text = try checked(appName)
        let session = LanguageModelSession(instructions: Self.workloadInstructions)
        do {
            return try await session.respond(to: "App: \(text)", generating: WorkloadDraft.self).content.proposal.cleaned
        } catch {
            throw failure(error)
        }
    }

    /// Picks the apps known for heavy work out of the installed ones. Nothing is saved. The grid
    /// of apps opens with them selected, and the person decides.
    func suggestHeavyApps(among names: [String]) async throws -> AppSelectionProposal {
        guard availability.isAvailable else { throw unavailable }
        let session = LanguageModelSession(instructions: Self.heavyAppsInstructions)
        do {
            let draft = try await session.respond(to: Self.heavyAppsPrompt(names), generating: AppSelectionDraft.self).content
            return AppSelectionProposal(names: draft.names)
        } catch {
            throw failure(error)
        }
    }

    /// The installed apps as a list the model can copy names from. The list is cut so that it
    /// fits what the model on the Mac can read at once.
    static func heavyAppsPrompt(_ names: [String]) -> String {
        "Apps:\n" + names.prefix(heavyAppsListLimit).map { String($0.prefix(60)) }.joined(separator: "\n")
    }

    static let heavyAppsListLimit = 240

    func explain(_ digest: ThermalDigest?, format: ReadingFormat) async throws -> String {
        guard let digest else { throw IntelligenceError.noHistory }
        guard availability.isAvailable else { throw unavailable }
        let session = LanguageModelSession(instructions: Self.explainInstructions)
        do {
            let answer = try await session.respond(to: digest.prompt(format: format)).content
            return answer.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw failure(error)
        }
    }

    private var unavailable: IntelligenceError {
        .unavailable(availability.reason ?? "Apple Intelligence is not currently available. Try again later.")
    }

    private func checked(_ request: String) throws -> String {
        guard availability.isAvailable else { throw unavailable }
        let text = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw IntelligenceError.emptyRequest }
        return String(text.prefix(Self.requestLimit))
    }

    private func failure(_ error: Error) -> IntelligenceError {
        Log.intelligence.error("Generation failed: \(String(describing: error), privacy: .public)")
        refreshAvailability()
        return availability.isAvailable ? .failed : unavailable
    }
}
