import Foundation
import Observation

/// The control loop. Each snapshot, it works out what the active preset asks of every fan and
/// sends the helper only what changed.
@MainActor
@Observable
final class FanController {
    enum Mode: Equatable {
        /// Nothing is sent, because the helper is not available.
        case monitoring
        case controlling
        /// The safeguard gave the fans back to the system.
        case safeguard
    }

    private(set) var mode: Mode = .monitoring
    private(set) var safeguard = Safeguard()
    /// What the active preset asks of each fan right now, by fan index.
    private(set) var plan: [Int: FanCommand] = [:]
    private(set) var lastError: String?

    /// Whether the helper is installed and trusted. The app model keeps this current.
    var isControlAllowed = false

    @ObservationIgnored private let commander: FanCommanding
    /// The last command the helper accepted for each fan. A fan with no entry is the system's.
    @ObservationIgnored private var sent: [Int: FanCommand] = [:]
    @ObservationIgnored private var isApplying = false
    @ObservationIgnored private var retryAfter = Date.distantPast

    static let retryDelay: TimeInterval = 10

    init(commander: FanCommanding) {
        self.commander = commander
    }

    /// True while AirFlow holds at least one fan.
    var holdsAnyFan: Bool {
        sent.values.contains { $0 != .automatic }
    }

    /// - Parameter adaptiveFraction: what the adaptive controller asks for now. Only the
    ///   Adaptive preset uses it.
    func tick(
        snapshot: ThermalSnapshot, preset: Preset, safeguardEnabled: Bool, safeguardLimit: Double,
        adaptiveFraction: Double? = nil, now: Date = Date()
    ) {
        safeguard.update(snapshot: snapshot, limit: safeguardLimit, isEnabled: safeguardEnabled)
        let effective = safeguard.isEngaged ? Preset.automatic : preset
        plan = FanPlanner.plan(preset: effective, snapshot: snapshot, adaptiveFraction: adaptiveFraction)

        guard isControlAllowed else {
            mode = .monitoring
            sent.removeAll()
            return
        }
        mode = safeguard.isEngaged ? .safeguard : .controlling

        // A fan AirFlow set that reads as the system's again was taken back, after sleep for
        // example, so its command must go out again.
        for fan in snapshot.fans where !fan.isManual && !isApplying {
            if case .speed = sent[fan.index] { sent[fan.index] = nil }
        }

        let changes = plan
            .filter { FanPlanner.differs($0.value, from: sent[$0.key] ?? .automatic) }
            .sorted { $0.key < $1.key }
        guard !changes.isEmpty else {
            if holdsAnyFan {
                Task { await commander.keepAlive() }
            }
            return
        }
        guard !isApplying, now >= retryAfter else { return }
        isApplying = true
        Task { await apply(changes) }
    }

    /// Gives every fan back to the system, for example before the helper is removed.
    func releaseAll() async {
        guard holdsAnyFan else { return }
        try? await commander.resetAllFans()
        sent.removeAll()
    }

    /// After the Mac wakes, the SMC may have dropped what it was told.
    func forgetSentCommands() {
        sent.removeAll()
    }

    private func apply(_ changes: [(key: Int, value: FanCommand)]) async {
        defer { isApplying = false }
        // A preset that leaves every fan to the system gives them all back in one request. The
        // helper then also gives the system its own control back, which one fan at a time cannot
        // do until the last fan.
        if plan.values.allSatisfy({ $0 == .automatic }) {
            do {
                try await commander.resetAllFans()
                sent.removeAll()
                lastError = nil
            } catch {
                lastError = error.localizedDescription
                retryAfter = Date().addingTimeInterval(Self.retryDelay)
                Log.control.error("Giving the fans back failed: \(error.localizedDescription, privacy: .public)")
            }
            return
        }
        for (index, command) in changes {
            do {
                switch command {
                case .automatic: try await commander.setFanAutomatic(index)
                case .speed(let rpm): try await commander.setFan(index, rpm: rpm)
                }
                sent[index] = command
                lastError = nil
            } catch {
                lastError = error.localizedDescription
                retryAfter = Date().addingTimeInterval(Self.retryDelay)
                Log.control.error("Fan \(index) command failed: \(error.localizedDescription, privacy: .public)")
                return
            }
        }
    }
}
