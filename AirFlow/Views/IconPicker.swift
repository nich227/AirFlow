import SwiftUI

/// The icons a preset can carry: every outlined icon of Ant Design, in a grid with a search
/// field. A click chooses an icon.
struct IconPicker: View {
    let selected: PresetIcon
    let onChoose: (PresetIcon) -> Void

    @Environment(\.colorSchemeContrast) private var contrast
    @State private var search = ""
    @State private var hovered: PresetIcon?

    static let cell: CGFloat = 36
    private static let columns = [GridItem(.adaptive(minimum: cell, maximum: cell), spacing: Space.xxs)]

    var body: some View {
        let shown = PresetIcon.matching(search)
        VStack(spacing: 0) {
            SearchField(text: $search, label: "Search icons")
                .padding(Space.sm)
            Divider()
            if shown.isEmpty {
                EmptyState(title: "No Results for “\(search)”", message: "Check the spelling or try a new search.")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: Self.columns, spacing: Space.xxs) {
                            ForEach(shown) { icon in
                                cell(icon)
                            }
                        }
                        .padding(Space.sm)
                    }
                    // The grid opens at the icon the preset has, so the person sees what is chosen.
                    .onAppear { proxy.scrollTo(selected.id, anchor: .center) }
                }
            }
        }
        .frame(width: Layout.iconPickerSize.width, height: Layout.iconPickerSize.height)
    }

    private func cell(_ icon: PresetIcon) -> some View {
        let isSelected = icon == selected
        return Button {
            onChoose(icon)
        } label: {
            AntIcon(icon.assetName, size: IconSize.title)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .frame(width: Self.cell, height: Self.cell)
                .background(
                    isSelected ? Palette.accent : hovered == icon ? Palette.fillStrong(contrast) : Color.clear,
                    in: .rect(cornerRadius: Radius.sm)
                )
                .contentShape(.rect(cornerRadius: Radius.sm))
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside {
                hovered = icon
            } else if hovered == icon {
                hovered = nil
            }
        }
        .help(icon.title)
        .accessibilityLabel(icon.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
