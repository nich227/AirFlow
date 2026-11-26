import SwiftUI

/// Ant Design's status dot: a temperature band as a color, always beside the number it describes.
struct StatusDot: View {
    let band: TemperatureBand

    var body: some View {
        // A bead lit from above, with a little of its own light around it.
        let color = Palette.temperature(band)
        Circle()
            .fill(color.gradient)
            .overlay(alignment: .top) {
                Circle().fill(.white.opacity(0.5)).frame(width: 3, height: 2).offset(y: 1.5)
            }
            .frame(width: Layout.statusDot, height: Layout.statusDot)
            .shadow(color: color.opacity(0.7), radius: 3)
            .accessibilityHidden(true)
    }
}

/// Ant Design's tag: a short state word on tinted glass.
struct StateTag: View {
    let text: String
    var color: Color = Palette.accent
    var iconName: String?

    var body: some View {
        HStack(spacing: Space.xxs) {
            if let iconName {
                AntIcon(iconName, size: IconSize.inline - 2)
            }
            Text(text)
        }
        .airFont(.label)
        .foregroundStyle(.primary)
        .padding(.horizontal, Space.sm)
        .padding(.vertical, Space.xxs)
        .antGlass(tint: color, radius: nil)
    }
}

/// Ant Design's statistic: a reading with its unit, both in the monospaced face.
struct Statistic: View {
    let value: String
    var unit: String?
    var title: String?
    var role: AirType = .statistic

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            if let title {
                Text(title)
                    .airFont(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: Space.xxs) {
                Text(value)
                    .readingFont(role)
                    .contentTransition(.numericText())
                if let unit {
                    Text(unit)
                        .readingFont(.label)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A fan's range from its minimum to its maximum, with the current speed filled in and the
/// speed it has been asked for marked.
struct FanTrack: View {
    let fan: Fan
    /// The speed the active preset asks for, when AirFlow holds the fan.
    var target: Double?
    var showsLimits = true

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(spacing: Space.xxs) {
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.fillStrong(contrast)).frame(height: Layout.trackHeight)
                    // The fill has the accent the person chose in System Settings. It is lit from
                    // above and glows a little, like liquid in a tube.
                    Capsule()
                        .fill(Palette.accent.gradient)
                        .overlay(alignment: .top) {
                            Capsule().fill(.white.opacity(0.4)).frame(height: 2).padding(.horizontal, 2).padding(.top, 1)
                        }
                        .frame(width: max(Layout.trackHeight, width * fan.fraction), height: Layout.trackHeight)
                        .shadow(color: Palette.accent.opacity(0.6), radius: 4)
                    if let target {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.primary)
                            .frame(width: 2, height: Layout.trackHeight + 6)
                            .offset(x: min(max(width * fan.fraction(of: target) - 1, 0), width - 2))
                    }
                }
            }
            .frame(height: Layout.trackHeight + 6)
            if showsLimits {
                HStack {
                    Text(ReadingFormat.rpm(fan.minimumRPM))
                    Spacer()
                    Text(ReadingFormat.rpm(fan.maximumRPM))
                }
                .readingFont(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("\(fan.name) speed")
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        var value = "\(ReadingFormat.rpmWithUnit(fan.currentRPM)), \(ReadingFormat.percent(fan.fraction)) of its range"
        if let target { value += ", set to \(ReadingFormat.rpmWithUnit(target))" }
        return value
    }
}

/// A message about the app's state with one thing to do about it. Ant Design's alert on glass
/// tinted with the state's color.
struct StatusBanner: View {
    enum Kind {
        case info, caution, danger, success

        var color: Color {
            switch self {
            case .info: return Palette.accent
            case .caution: return Palette.caution
            case .danger: return Palette.danger
            case .success: return Palette.success
            }
        }

        var iconName: String {
            switch self {
            case .info: return "ant-info-circle"
            case .caution: return "ant-exclamation-circle"
            case .danger: return "ant-warning"
            case .success: return "ant-check-circle"
            }
        }
    }

    let kind: Kind
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?
    /// A narrow surface, such as the menu bar panel, puts the action under the message.
    var isCompact = false
    /// A drawn animation that plays once in place of the icon.
    var animation: String?

    var body: some View {
        HStack(alignment: .top, spacing: Space.sm) {
            if let animation {
                AirAnimation(name: animation, tint: kind.color)
                    .frame(width: IconSize.title, height: IconSize.title)
            } else {
                AntIcon(kind.iconName, size: IconSize.title)
                    .foregroundStyle(kind.color)
            }
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(title)
                    .airFont(.body)
                Text(readings: message)
                    .airFont(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if isCompact {
                    button
                        .padding(.top, Space.xxs)
                }
            }
            Spacer(minLength: 0)
            if !isCompact {
                button
            }
        }
        .padding(Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .antGlass(tint: kind.color)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var button: some View {
        if let actionTitle, let action {
            Button(action: action) {
                Text(actionTitle)
                    .airFont(.body)
            }
            .buttonStyle(.glass)
        }
    }
}

/// A surface with nothing to list shows a drawing, a title, and what to do next.
struct EmptyState: View {
    let title: String
    let message: String
    var animation: String = Animations.breeze
    var isActive = true

    var body: some View {
        VStack(spacing: Space.xs) {
            AirAnimation(name: animation, loops: true, isActive: isActive, tint: .secondary)
                .frame(width: IconSize.illustration, height: IconSize.illustration)
            Text(title)
                .airFont(.title)
            Text(message)
                .airFont(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 360)
        .padding(Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One choice of a segmented control or a select.
struct AntOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    /// True for the first option of a new group, which a line sets apart in a select's menu.
    var startsGroup = false

    var id: Value { value }
}

/// Ant Design's segmented control is a track with a pane of glass under the selected segment.
/// AirFlow draws it, because the system's control cannot use the app's typeface.
struct AntSegmented<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [AntOption<Value>]
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                let isSelected = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(option.title)
                        .airFont(.body)
                        // The pane under the selected segment marks it. Every title stays in
                        // the primary color, so the ones to choose from hold their contrast.
                        .foregroundStyle(.primary)
                        .padding(.horizontal, Space.sm)
                        .padding(.vertical, Space.xxs)
                        .frame(minWidth: 88)
                        .contentShape(.rect(cornerRadius: Radius.sm))
                }
                .buttonStyle(.plain)
                .background {
                    if isSelected {
                        Color.clear.antGlass(tint: Palette.accent, radius: Radius.sm)
                    }
                }
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Palette.fillStrong(contrast), in: .rect(cornerRadius: Radius.md))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

/// Ant Design's select shows the chosen option on a quiet background, as wide as its own text, with
/// the choices in a menu. AirFlow draws the button, because a pop-up button is as wide as its
/// longest choice and cannot use the app's typeface. The menu is the system's.
struct AntSelect<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [AntOption<Value>]
    @Environment(\.colorSchemeContrast) private var contrast

    private var current: String {
        options.first { $0.value == selection }?.title ?? ""
    }

    var body: some View {
        Menu {
            Picker(title, selection: $selection) {
                ForEach(options) { option in
                    if option.startsGroup {
                        Divider()
                    }
                    Text(option.title).tag(option.value)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: Space.xxs) {
                Text(current)
                    .airFont(.body)
                AntIcon("ant-down", size: 10)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Space.xs)
            .padding(.vertical, 3)
            .background(Palette.fillStrong(contrast), in: .rect(cornerRadius: Radius.sm))
            .contentShape(.rect(cornerRadius: Radius.sm))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(title)
        .accessibilityValue(current)
    }
}

/// Lays its pieces out left to right, and onto another line when a line is full. With no width
/// proposed it asks for no more than its widest piece, so it never makes the view that holds it
/// wider.
struct FlowLayout: SwiftUI.Layout {
    var spacing: CGFloat = Space.xs
    var lineSpacing: CGFloat = Space.xs

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let widest = sizes.map(\.width).max() ?? 0
        let lines = Self.lines(of: sizes, within: max(proposal.width ?? widest, widest), spacing: spacing)
        let height = lines.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(lines.count - 1, 0))
        return CGSize(width: lines.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        var y = bounds.minY
        for line in Self.lines(of: sizes, within: bounds.width, spacing: spacing) {
            var x = bounds.minX
            for index in line.indices {
                subviews[index].place(
                    at: CGPoint(x: x, y: y + line.height / 2),
                    anchor: .leading,
                    proposal: ProposedViewSize(sizes[index])
                )
                x += sizes[index].width + spacing
            }
            y += line.height + lineSpacing
        }
    }

    struct Line: Equatable {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    /// Fills each line until the next piece does not fit. A piece wider than a line gets a line
    /// of its own.
    static func lines(of sizes: [CGSize], within width: CGFloat, spacing: CGFloat) -> [Line] {
        var lines: [Line] = []
        var line = Line()
        for (index, size) in sizes.enumerated() {
            let extended = line.indices.isEmpty ? size.width : line.width + spacing + size.width
            if !line.indices.isEmpty, extended > width {
                lines.append(line)
                line = Line(indices: [index], width: size.width, height: size.height)
            } else {
                line.indices.append(index)
                line.width = extended
                line.height = max(line.height, size.height)
            }
        }
        if !line.indices.isEmpty {
            lines.append(line)
        }
        return lines
    }
}

/// An empty state that fills a page of the window. A page's root must scroll, because a page rooted
/// in a plain stack makes the split view lay the whole window out taller than it is.
struct PageEmptyState: View {
    let title: String
    let message: String

    var body: some View {
        ScrollView {
            EmptyState(title: title, message: message)
                .frame(minHeight: 420)
        }
    }
}

/// What the helper's state means for the person, and the one step that moves it forward.
struct ControlStatusBanner: View {
    @Environment(AppModel.self) private var model
    var isCompact = false

    var body: some View {
        if let error = model.controller.lastError, model.helper.status.allowsControl {
            StatusBanner(kind: .danger, title: "Couldn't Set Fan Speed", message: error + " AirFlow will try again.", isCompact: isCompact)
        } else if model.controller.safeguard.isEngaged {
            StatusBanner(kind: .caution, title: "Safeguard Is On", message: safeguardMessage, isCompact: isCompact)
        } else {
            switch model.helper.status {
            case .enabled:
                // The snapshot's date makes this view read the clock again as readings arrive.
                if model.helper.justEnabled(now: max(model.monitor.snapshot.date, Date())) {
                    StatusBanner(
                        kind: .success, title: "Fan Control Is On",
                        message: "AirFlow can now change fan speeds. Apply a preset to start.",
                        isCompact: isCompact, animation: Animations.done
                    )
                }
            case .notInstalled:
                StatusBanner(
                    kind: .info, title: "Monitoring Only",
                    message: "To change fan speeds, AirFlow needs to install a helper tool. You can keep monitoring without it.",
                    actionTitle: "Turn On Fan Control", action: model.enableFanControl, isCompact: isCompact
                )
            case .needsApproval:
                StatusBanner(
                    kind: .caution, title: "Allow the Helper Tool",
                    message: "Turn on AirFlow in System Settings > General > Login Items & Extensions.",
                    actionTitle: "Open Login Items Settings", action: model.helper.openLoginItems, isCompact: isCompact
                )
            case .unsignedBuild:
                StatusBanner(
                    kind: .info, title: "Monitoring Only",
                    message: "This copy of AirFlow isn't signed by a developer, so it can't install the helper tool. Presets and rules still work, but they don't change fan speeds.",
                    isCompact: isCompact
                )
            case .failed(let reason):
                StatusBanner(
                    kind: .danger, title: "The Helper Tool Couldn't Be Installed",
                    message: reason, actionTitle: "Try Again", action: model.enableFanControl, isCompact: isCompact
                )
            }
        }
    }

    private var safeguardMessage: String {
        let format = model.settings.format
        let part = model.controller.safeguard.trigger?.title ?? "CPU"
        let release = model.settings.safeguardLimit - Safeguard.releaseMargin
        return "The \(part) reached \(format.temperatureWithUnit(model.controller.safeguard.peak)), so macOS controls the fans until it cools to \(format.temperatureWithUnit(release))."
    }
}
