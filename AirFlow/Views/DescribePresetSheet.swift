import SwiftUI

/// Describe a preset in plain words. Apple Intelligence drafts it on this Mac, and nothing is
/// saved until the person says so.
struct DescribePresetSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let onSaved: (Preset) -> Void

    @State private var request = ""
    @State private var state: DraftState = .editing
    @FocusState private var requestIsFocused: Bool

    enum DraftState: Equatable {
        case editing
        case drafting
        case drafted(Preset)
        case failed(String)
    }

    static let examples = [
        "Quiet for video calls",
        "Keep the GPU cool while I render",
        "Half speed all the time",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("Describe a Preset")
                    .airFont(.display)
                Text("Describe what you'd like the fans to do. Apple Intelligence drafts a preset on this Mac, and you decide whether to save it.")
                    .airFont(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextField("For example, “Stay quiet until the CPU reaches 80°”", text: $request, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...3)
                .focused($requestIsFocused)
                .onSubmit(draft)
                .disabled(state == .drafting)
                .accessibilityLabel("Preset description")

            HStack(spacing: Space.xs) {
                ForEach(Self.examples, id: \.self) { example in
                    Button(example) {
                        request = example
                        draft()
                    }
                    .buttonStyle(.glass)
                    .tint(nil)
                    .controlSize(.small)
                    .disabled(state == .drafting)
                }
            }

            result
                .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)

            HStack {
                Spacer()
                Button(role: .cancel) {
                    dismiss()
                } label: {
                    Text("Cancel")
                        .airFont(.body)
                }
                .keyboardShortcut(.cancelAction)
                if case .drafted(let preset) = state {
                    Button {
                        save(preset)
                    } label: {
                        Text("Save Preset")
                            .airFont(.body)
                    }
                    .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button {
                        draft()
                    } label: {
                        Text("Draft")
                            .airFont(.body)
                    }
                    .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(state == .drafting || request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(Space.lg)
        .frame(width: 520)
        .castsSheetShadow()
        .onAppear { requestIsFocused = true }
    }

    @ViewBuilder
    private var result: some View {
        switch state {
        case .editing:
            EmptyView()
        case .drafting:
            HStack(spacing: Space.sm) {
                AirAnimation(name: Animations.spark, loops: true)
                    .frame(width: IconSize.rotor, height: IconSize.rotor)
                Text("Drafting your preset…")
                    .airFont(.body)
                    .foregroundStyle(.secondary)
            }
        case .drafted(let preset):
            ProposalPreview(preset: preset)
        case .failed(let message):
            StatusBanner(kind: .caution, title: "No Draft", message: message)
        }
    }

    private func draft() {
        let text = request
        state = .drafting
        Task {
            do {
                state = .drafted(try await model.intelligence.draftPreset(from: text).makePreset())
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    private func save(_ preset: Preset) {
        let saved = model.presets.add(preset)
        onSaved(saved)
        dismiss()
    }
}

/// What a drafted preset would do, in the same words and drawing the preset page uses.
struct ProposalPreview: View {
    @Environment(AppModel.self) private var model
    let preset: Preset

    var body: some View {
        let snapshot = model.monitor.snapshot
        let format = model.settings.format
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.xs) {
                AntIcon(preset.icon.assetName, size: IconSize.title)
                Text(preset.name)
                    .airFont(.title)
            }
            if !preset.summary.isEmpty {
                Text(preset.summary)
                    .airFont(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            switch preset.fallback {
            case .automatic:
                Text("macOS controls every fan.")
                    .airFont(.body)
            case .constant(let rpm):
                Text(readings: "Every fan is held at \(ReadingFormat.rpmWithUnit(rpm)).")
                    .airFont(.body)
            case .constantFraction(let fraction):
                Text(readings: "Every fan is held at \(ReadingFormat.percent(fraction)) of its range.")
                    .airFont(.body)
            case .sensorBased(let rule):
                Text(readings: "Every fan follows \(snapshot.name(of: rule.source)), from \(format.temperature(rule.startCelsius)) to full speed at \(format.temperature(rule.maxCelsius)).")
                    .airFont(.body)
                    .fixedSize(horizontal: false, vertical: true)
                if let fan = snapshot.fans.first, case .group(let group, _) = rule.source {
                    CurveEditor(
                        rule: .constant(rule), fan: fan, currentCelsius: snapshot.celsius(for: rule.source),
                        group: group, format: format, isEditable: false
                    )
                }
            }
        }
    }
}
