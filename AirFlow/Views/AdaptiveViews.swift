import SwiftUI

/// What the adaptive controller sees: the kind of work, the power, the temperature now, and
/// the temperature it expects.
struct AdaptiveSummary: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let format = model.settings.format
        VStack(alignment: .leading, spacing: Space.sm) {
            if let state = model.adaptive.state {
                HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                    Text("Workload")
                        .airFont(.title)
                    StateTag(text: state.regime.title, color: Palette.workload(state.regime))
                    Spacer()
                }
                Text(readings: Self.explanation(state: state, hintApp: model.adaptive.hintAppName, hint: model.adaptive.hint))
                    .airFont(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top, spacing: Space.xl) {
                    Statistic(value: state.watts.map(ReadingFormat.watts) ?? "--", unit: "W", title: "Power", role: .title)
                    Statistic(value: format.temperature(state.celsius), title: "Now", role: .title)
                    Statistic(value: format.temperature(state.forecastCelsius), title: "In \(Int(ThermalForecaster.horizon)) Seconds", role: .title)
                    Spacer()
                }
                .accessibilityElement(children: .contain)
                if !state.isLearned {
                    Text("AirFlow is still learning how your Mac uses power and how it heats up and cools down. This takes a few minutes of light and heavy use.")
                        .airFont(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Workload")
                    .airFont(.title)
                Text("Adaptive needs CPU and GPU temperatures, and this Mac doesn't report them. macOS controls the fans.")
                    .airFont(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// What the regime means for the fans, and which open app made AirFlow expect it.
    static func explanation(state: AdaptiveState, hintApp: String?, hint: WorkloadRegime?) -> String {
        var text = state.regime.explanation
        if state.watts == nil {
            text += " This Mac doesn't report power usage, so AirFlow uses temperature alone."
        } else if let hintApp, let hint, hint != .light {
            text += " \(hintApp) is open, so AirFlow expects \(hint == .sustained ? "a long, heavy load" : "short bursts") sooner."
        }
        return text
    }
}

/// The apps a person has told AirFlow about, and the way to add one. The on-device model can
/// suggest what an app is known for. The suggestion counts only after the person accepts it.
struct AppWorkloadsEditor: View {
    @Environment(AppModel.self) private var model
    @State private var apps: [AppDirectory.App] = []
    @State private var suggestion: Suggestion = .none

    enum Suggestion: Equatable {
        case none
        case working(bundleID: String)
        case proposed(bundleID: String, name: String, proposal: WorkloadProposal)
        case failed(String)
    }

    private static let regimeOptions = WorkloadRegime.allCases.map { AntOption(value: $0, title: $0.title) }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("Apps")
                .airFont(.title)
            Text("Add apps that put a heavy load on your Mac. While one is open, the fans respond sooner when the load increases. An idle app changes nothing.")
                .airFont(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(model.adaptive.workloads) { workload in
                row(workload)
            }
            proposal
            AntSelect(title: "Add an App", selection: Binding {
                ""
            } set: { bundleID in
                add(bundleID)
            }, options: [AntOption(value: "", title: "Add an App")] + addable)
        }
        .task {
            if apps.isEmpty {
                apps = await Task.detached { AppDirectory.installed() }.value
            }
        }
    }

    /// The installed apps that have no entry yet.
    private var addable: [AntOption<String>] {
        let taken = Set(model.adaptive.workloads.map(\.bundleID))
        return apps.filter { !taken.contains($0.bundleID) }.map { AntOption(value: $0.bundleID, title: $0.name) }
    }

    private func row(_ workload: AppWorkload) -> some View {
        HStack(spacing: Space.xs) {
            Text(workload.name)
                .airFont(.body)
            Spacer(minLength: Space.sm)
            if model.intelligence.availability.isAvailable {
                Button {
                    suggest(workload)
                } label: {
                    Label("Suggest", image: "ant-sparkles")
                        .airFont(.label)
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .disabled(suggestion == .working(bundleID: workload.bundleID))
                .help("Ask Apple Intelligence to suggest a workload for \(workload.name)")
            }
            // The color of the kind of work, beside its name in the menu.
            Circle()
                .fill(Palette.workload(workload.regime).gradient)
                .frame(width: Layout.statusDot, height: Layout.statusDot)
                .accessibilityHidden(true)
            AntSelect(title: "\(workload.name) workload", selection: Binding {
                workload.regime
            } set: { regime in
                model.adaptive.setWorkload(AppWorkload(bundleID: workload.bundleID, name: workload.name, regime: regime))
            }, options: Self.regimeOptions)
            Button {
                model.adaptive.removeWorkload(bundleID: workload.bundleID)
            } label: {
                Label("Remove \(workload.name)", image: "ant-delete")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Remove \(workload.name)")
        }
    }

    @ViewBuilder
    private var proposal: some View {
        switch suggestion {
        case .none:
            EmptyView()
        case .working:
            HStack(spacing: Space.xs) {
                AirAnimation(name: Animations.spark, loops: true)
                    .frame(width: IconSize.title, height: IconSize.title)
                Text("Asking Apple Intelligence…")
                    .airFont(.body)
                    .foregroundStyle(.secondary)
            }
        case .proposed(let bundleID, let name, let proposal):
            StatusBanner(
                kind: .info, title: "Apple Intelligence Suggests \(proposal.regime.title) for \(name)",
                message: proposal.reason.isEmpty ? "No reason was given." : proposal.reason,
                actionTitle: "Use \(proposal.regime.title)"
            ) {
                model.adaptive.setWorkload(AppWorkload(bundleID: bundleID, name: name, regime: proposal.regime))
                suggestion = .none
            }
        case .failed(let message):
            Text(message)
                .airFont(.body)
                .foregroundStyle(Palette.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func add(_ bundleID: String) {
        guard let app = apps.first(where: { $0.bundleID == bundleID }) else { return }
        let regime = KnownWorkloads.regimes[bundleID] ?? .sustained
        model.adaptive.setWorkload(AppWorkload(bundleID: bundleID, name: app.name, regime: regime))
    }

    private func suggest(_ workload: AppWorkload) {
        suggestion = .working(bundleID: workload.bundleID)
        Task {
            do {
                let proposal = try await model.intelligence.suggestWorkload(appName: workload.name)
                suggestion = .proposed(bundleID: workload.bundleID, name: workload.name, proposal: proposal)
            } catch {
                suggestion = .failed(error.localizedDescription)
            }
        }
    }
}
