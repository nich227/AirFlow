import FoundationModels
import XCTest
@testable import AirFlow

/// A model that answers from a script, in order. An answer that is an error is thrown.
final class ScriptedModel: OnDeviceModel, @unchecked Sendable {
    struct Asked: Equatable {
        var prompt: String
        var instructions: String
    }

    struct OutOfAnswers: Error {}

    var availability: IntelligenceService.Availability = .available
    var answers: [Any] = []
    /// What the model becomes after it fails, as when it is turned off in the middle of a request.
    var availabilityAfterFailure: IntelligenceService.Availability?
    private(set) var asked: [Asked] = []

    private func next<Answer>(_ prompt: String, _ instructions: String) throws -> Answer {
        asked.append(Asked(prompt: prompt, instructions: instructions))
        guard !answers.isEmpty, let answer = answers.removeFirst() as? Answer else {
            if let availabilityAfterFailure { availability = availabilityAfterFailure }
            throw OutOfAnswers()
        }
        return answer
    }

    func respond<Content: Generable & Sendable>(to prompt: String, instructions: String, generating type: Content.Type) async throws -> Content {
        try next(prompt, instructions)
    }

    func respond(to prompt: String, instructions: String) async throws -> String {
        try next(prompt, instructions)
    }
}

@MainActor
final class IntelligenceServiceTests: XCTestCase {
    private func failure(_ body: () async throws -> Void) async -> IntelligenceError? {
        do {
            try await body()
            return nil
        } catch {
            return error as? IntelligenceError
        }
    }

    private func preset(_ mode: DraftMode, sensor: DraftSensor = .cpu) -> PresetDraft {
        PresetDraft(name: "Quiet Work", mode: mode, speedPercent: 40, sensor: sensor, startCelsius: 70, fullSpeedCelsius: 90, summary: "Fans stay quiet.")
    }

    private func rule(_ trigger: DraftTrigger) -> RuleDraft {
        RuleDraft(trigger: trigger, appName: "Xcode", sensor: .gpu, celsius: 80, startHour: 22, endHour: 7, presetName: "Quiet")
    }

    private func load(_ name: String, now: Double, overall: Double = 0, seconds: Double = 0) -> AppLoad {
        AppLoad(name: name, bundleID: "com.example.\(name)", coresNow: now, coresOverall: overall, cpuSeconds: seconds)
    }

    func testWhatTheSystemSaysAboutItsModelIsPutInWords() {
        XCTAssertEqual(IntelligenceService.Availability(.available), .available)
        XCTAssertEqual(
            IntelligenceService.Availability(.unavailable(.deviceNotEligible)),
            .unavailable("Apple Intelligence is not supported on this Mac.")
        )
        XCTAssertEqual(
            IntelligenceService.Availability(.unavailable(.appleIntelligenceNotEnabled)),
            .unavailable("Turn on Apple Intelligence in System Settings to draft presets from a description.")
        )
        XCTAssertEqual(
            IntelligenceService.Availability(.unavailable(.modelNotReady)),
            .unavailable("Apple Intelligence is still downloading. Try again later.")
        )
        XCTAssertTrue(IntelligenceService.Availability.available.isAvailable)
        XCTAssertNil(IntelligenceService.Availability.available.reason)
        XCTAssertNil(IntelligenceService.Availability.available.error)
        let off = IntelligenceService.Availability.unavailable("Off.")
        XCTAssertFalse(off.isAvailable)
        XCTAssertEqual(off.reason, "Off.")
        XCTAssertEqual(off.error, .unavailable("Off."))
    }

    func testEachErrorSaysWhatToDo() {
        XCTAssertEqual(IntelligenceError.unavailable("Off.").errorDescription, "Off.")
        XCTAssertEqual(IntelligenceError.emptyRequest.errorDescription, "Enter a description first.")
        XCTAssertEqual(IntelligenceError.noHistory.errorDescription, "AirFlow needs a few more seconds of readings before it can explain them.")
        XCTAssertEqual(IntelligenceError.failed.errorDescription, "Apple Intelligence couldn't draft that. Try describing it another way.")
    }

    func testADescriptionBecomesAPresetProposal() async throws {
        let model = ScriptedModel()
        let service = IntelligenceService(model: model)
        XCTAssertEqual(service.availability, .available)
        model.answers = [preset(.sensorBased, sensor: .battery), preset(.constant, sensor: .gpu), preset(.automatic, sensor: .storage), preset(.automatic, sensor: .enclosure)]
        let followed = try await service.draftPreset(from: "  keep it quiet while I write  \n")
        XCTAssertEqual(followed, PresetProposal(
            name: "Quiet Work", mode: .sensorBased, speedPercent: 40, sensor: .battery, startCelsius: 70, fullSpeedCelsius: 90, summary: "Fans stay quiet."
        ))
        XCTAssertEqual(model.asked, [.init(prompt: "keep it quiet while I write", instructions: IntelligenceService.presetInstructions)])
        let constant = try await service.draftPreset(from: String(repeating: "a", count: 500))
        XCTAssertEqual(constant.mode, .constant)
        XCTAssertEqual(constant.sensor, .gpu)
        XCTAssertEqual(model.asked.last?.prompt.count, IntelligenceService.requestLimit, "A long request is cut")
        let automatic = try await service.draftPreset(from: "let the Mac decide")
        XCTAssertEqual(automatic.mode, .automatic)
        XCTAssertEqual(automatic.sensor, .storage)
        let enclosure = try await service.draftPreset(from: "again")
        XCTAssertEqual(enclosure.sensor, .enclosure)
    }

    func testARequestIsRefusedBeforeTheModelIsAsked() async {
        let model = ScriptedModel()
        let service = IntelligenceService(model: model)
        let empty = await failure { _ = try await service.draftPreset(from: "  \n ") }
        XCTAssertEqual(empty, .emptyRequest)

        model.availability = .unavailable("Turn it on.")
        service.refreshAvailability()
        XCTAssertEqual(service.availability.reason, "Turn it on.")
        let off = IntelligenceError.unavailable("Turn it on.")
        let preset = await failure { _ = try await service.draftPreset(from: "quiet") }
        let rule = await failure { _ = try await service.draftRule(from: "quiet at night", presetNames: ["Quiet"]) }
        let workload = await failure { _ = try await service.suggestWorkload(appName: "Xcode") }
        let apps = await failure { _ = try await service.suggestHeavyApps(loads: [], known: []) }
        let digest = ThermalDigest(history: Fixtures.history(count: 10), presetName: "Quiet")
        let explained = await failure { _ = try await service.explain(digest, format: ReadingFormat()) }
        XCTAssertEqual([preset, rule, workload, apps, explained], [off, off, off, off, off])
        let nothing = await failure { _ = try await service.explain(nil, format: ReadingFormat()) }
        XCTAssertEqual(nothing, .noHistory, "With no readings there is nothing to explain, whatever the model")
        XCTAssertTrue(model.asked.isEmpty)
    }

    func testAModelThatFailsSaysToTryAgainOrWhyItIsGone() async {
        let model = ScriptedModel()
        let service = IntelligenceService(model: model)
        let preset = await failure { _ = try await service.draftPreset(from: "quiet") }
        let rule = await failure { _ = try await service.draftRule(from: "quiet at night", presetNames: []) }
        let workload = await failure { _ = try await service.suggestWorkload(appName: "Xcode") }
        let digest = ThermalDigest(history: Fixtures.history(count: 10), presetName: "Quiet")
        let explained = await failure { _ = try await service.explain(digest, format: ReadingFormat()) }
        XCTAssertEqual([preset, rule, workload, explained], [.failed, .failed, .failed, .failed])
        XCTAssertEqual(model.asked.count, 4)

        // The model was turned off while it worked: that is the reason, not the request.
        model.availabilityAfterFailure = .unavailable("Turn it on.")
        let gone = await failure { _ = try await service.draftPreset(from: "quiet") }
        XCTAssertEqual(gone, .unavailable("Turn it on."))
        XCTAssertEqual(service.availability, .unavailable("Turn it on."))
    }

    func testADescriptionBecomesARuleProposal() async throws {
        let model = ScriptedModel()
        let service = IntelligenceService(model: model)
        let triggers: [(DraftTrigger, RuleProposal.Trigger)] = [(.app, .app), (.battery, .battery), (.adapter, .adapter), (.temperature, .temperature), (.time, .time)]
        model.answers = triggers.map { rule($0.0) }
        for (_, expected) in triggers {
            let proposal = try await service.draftRule(from: " quiet in Xcode ", presetNames: ["Quiet", "Full Blast"])
            XCTAssertEqual(proposal, RuleProposal(
                trigger: expected, appName: "Xcode", sensor: .gpu, celsius: 80, startHour: 22, endHour: 7, presetName: "Quiet"
            ))
        }
        XCTAssertEqual(model.asked.first, .init(
            prompt: "Available presets: Quiet, Full Blast.\nRequest: quiet in Xcode", instructions: IntelligenceService.ruleInstructions
        ))
    }

    func testAnAppsNameBecomesAProposalOfWhatItIsKnownFor() async throws {
        let model = ScriptedModel()
        let service = IntelligenceService(model: model)
        model.answers = [
            WorkloadDraft(workload: .sustained, reason: "  It exports video for minutes.\nIt also does more.  "),
            WorkloadDraft(workload: .bursty, reason: "It compiles."), WorkloadDraft(workload: .light, reason: "It shows text."),
        ]
        let sustained = try await service.suggestWorkload(appName: " Final Cut Pro ")
        XCTAssertEqual(sustained, WorkloadProposal(regime: .sustained, reason: "It exports video for minutes."), "One line, trimmed")
        XCTAssertEqual(model.asked, [.init(prompt: "App: Final Cut Pro", instructions: IntelligenceService.workloadInstructions)])
        let bursty = try await service.suggestWorkload(appName: "Xcode")
        XCTAssertEqual(bursty.regime, .bursty)
        let light = try await service.suggestWorkload(appName: "TextEdit")
        XCTAssertEqual(light.regime, .light)
    }

    func testTheModelIsAskedOnlyAboutBusyAppsThatAreNotHeavyByMeasurement() async throws {
        let model = ScriptedModel()
        let service = IntelligenceService(model: model)
        let loads = [
            load("Render", now: 1.4), load("Editor", now: 0.3), load("Chat", now: 0.2), load("Sync", now: 0.16),
            load("Clock", now: 0.01), load(String(repeating: "N", count: 90), now: 0.2),
        ]
        // Editor is judged heavy, Chat light, the model cannot judge Sync, and the long name bursty.
        model.answers = [
            WorkloadDraft(workload: .sustained, reason: ""), WorkloadDraft(workload: .light, reason: ""),
            ScriptedModel.OutOfAnswers(), WorkloadDraft(workload: .bursty, reason: ""),
        ]
        let proposal = try await service.suggestHeavyApps(loads: loads, known: ["Xcode"])
        XCTAssertEqual(proposal.names, ["Render", "Editor", String(repeating: "N", count: 90), "Xcode"], "Measured, then judged, then known")
        XCTAssertEqual(model.asked.map(\.prompt), ["App: Editor", "App: Chat", "App: Sync", "App: " + String(repeating: "N", count: 60)])
        XCTAssertTrue(model.asked.allSatisfy { $0.instructions == IntelligenceService.workloadInstructions })
        XCTAssertEqual(service.availability, .available, "An app the model cannot judge is not a failure")
    }

    func testReadingsAreExplainedInTheModelsWords() async throws {
        let model = ScriptedModel()
        let service = IntelligenceService(model: model)
        let digest = try XCTUnwrap(ThermalDigest(history: Fixtures.history(count: 10), presetName: "Quiet"))
        model.answers = ["\n  The CPU stayed warm.  \n"]
        let answer = try await service.explain(digest, format: ReadingFormat())
        XCTAssertEqual(answer, "The CPU stayed warm.")
        XCTAssertEqual(model.asked, [.init(prompt: digest.prompt(format: ReadingFormat()), instructions: IntelligenceService.explainInstructions)])
    }
}
