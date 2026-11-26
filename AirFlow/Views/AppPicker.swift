import AppKit
import SwiftUI

/// Chooses apps from a grid of their icons, laid out as the Applications folder is in the Finder's
/// icon view. A click selects an app or lets it go, and Add hands every selected app back.
struct AppPickerSheet: View {
    let apps: [AppDirectory.App]
    /// The apps that have an entry already. They show as added and cannot be chosen again.
    let added: Set<String>
    /// True until the list of installed apps has been read.
    let isLoading: Bool
    /// True if Apple Intelligence chose the apps that start out selected.
    let isSuggested: Bool
    let onAdd: ([AppDirectory.App]) -> Void

    init(
        apps: [AppDirectory.App], added: Set<String>, isLoading: Bool, selected: Set<String> = [], isSuggested: Bool = false,
        onAdd: @escaping ([AppDirectory.App]) -> Void
    ) {
        // The apps that start out selected come first, so the person sees them without scrolling.
        // The order is fixed here, so an app does not move when it is clicked.
        self.apps = apps.filter { selected.contains($0.bundleID) } + apps.filter { !selected.contains($0.bundleID) }
        self.added = added
        self.isLoading = isLoading
        self.isSuggested = isSuggested
        self.onAdd = onAdd
        _chosen = State(initialValue: selected.subtracting(added))
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var search = ""
    @State private var chosen: Set<String>
    @State private var hovered: String?
    @FocusState private var searchIsFocused: Bool

    private static let columns = [GridItem(.adaptive(minimum: 108, maximum: 140), spacing: Space.xs, alignment: .top)]

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(Space.lg)
            Divider()
            content
            Divider()
            footer
                .padding(.horizontal, Space.lg)
                .padding(.vertical, Space.md)
        }
        .frame(width: Layout.appPickerSize.width, height: Layout.appPickerSize.height)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Space.lg) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("Add Apps")
                    .airFont(.display)
                Text(Self.subtitle(isSuggested: isSuggested, selected: chosen.count))
                    .airFont(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Space.sm)
            searchField
        }
    }

    /// A search field as the Finder's: a magnifying glass, the text, and a button that clears it.
    private var searchField: some View {
        HStack(spacing: Space.xxs + 2) {
            AntIcon("ant-search", size: IconSize.inline)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search", text: $search)
                .font(AirType.body.font)
                .textFieldStyle(.plain)
                .focused($searchIsFocused)
                .accessibilityLabel("Search apps")
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Label("Clear the search", image: "ant-close-circle")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear the search")
            }
        }
        .padding(.horizontal, Space.xs)
        .frame(width: 220, height: 28)
        .background(Palette.fill(contrast), in: .rect(cornerRadius: Radius.sm))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.sm)
                .strokeBorder(searchIsFocused ? Palette.accent : Palette.hairline(contrast), lineWidth: searchIsFocused ? 2 : 1)
        }
        .contentShape(.rect(cornerRadius: Radius.sm))
        .onTapGesture { searchIsFocused = true }
    }

    @ViewBuilder
    private var content: some View {
        let shown = Self.matches(search, in: apps)
        if isLoading {
            EmptyState(title: "Loading Apps…", message: "AirFlow is looking in your Applications folders.")
        } else if shown.isEmpty {
            EmptyState(
                title: search.isEmpty ? "No Apps Found" : "No Results for “\(search)”",
                message: search.isEmpty ? "AirFlow found no apps in your Applications folders." : "Check the spelling or try a new search."
            )
        } else {
            ScrollView {
                LazyVGrid(columns: Self.columns, spacing: Space.xs) {
                    ForEach(shown) { app in
                        cell(app)
                    }
                }
                .padding(Space.md)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: Space.xs) {
            Text(readings: Self.status(chosen: chosen.count))
                .foregroundStyle(.secondary)
            Spacer(minLength: Space.sm)
            Button(role: .cancel) {
                dismiss()
            } label: {
                Text("Cancel")
                    .airFont(.body)
            }
            .keyboardShortcut(.cancelAction)
            Button {
                onAdd(apps.filter { chosen.contains($0.bundleID) })
                dismiss()
            } label: {
                Text("Add")
                    .airFont(.body)
            }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(chosen.isEmpty)
        }
    }

    private func cell(_ app: AppDirectory.App) -> some View {
        let isAdded = added.contains(app.bundleID)
        let isChosen = chosen.contains(app.bundleID)
        return Button {
            withAnimation(Anim.allowed(Anim.quick, reduceMotion: reduceMotion)) {
                if isChosen { chosen.remove(app.bundleID) } else { chosen.insert(app.bundleID) }
            }
        } label: {
            // A selected app looks as it does in the Finder: a quiet ground behind its icon, and
            // its name on the accent the person chose in System Settings.
            VStack(spacing: Space.xxs) {
                Image(nsImage: AppIcons.icon(for: app.bundleID))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: Layout.appIcon, height: Layout.appIcon)
                    .opacity(isAdded ? 0.35 : 1)
                    .padding(Space.xxs)
                    .background {
                        if isChosen || hovered == app.bundleID {
                            RoundedRectangle(cornerRadius: Radius.md).fill(Palette.fillStrong(contrast))
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if isChosen {
                            AntIcon("ant-check", size: IconSize.inline - 2)
                                .foregroundStyle(.white)
                                .padding(Space.xxs)
                                .background(Palette.accent, in: Circle())
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                // A name of one long word is cut in the middle. Broken across two lines, it would
                // end in a single letter.
                Text(app.name)
                    .airFont(.label)
                    .foregroundStyle(isChosen ? AnyShapeStyle(.white) : AnyShapeStyle(isAdded ? .secondary : .primary))
                    .lineLimit(app.name.contains(" ") ? 2 : 1)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Space.xxs + 2)
                    .padding(.vertical, 1)
                    .background {
                        if isChosen {
                            RoundedRectangle(cornerRadius: Radius.xs).fill(Palette.accent)
                        }
                    }
                    .frame(maxWidth: .infinity)
                if isAdded {
                    Text("Added")
                        .airFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(Space.xxs)
            .frame(maxWidth: .infinity, minHeight: 118, alignment: .top)
            .contentShape(.rect(cornerRadius: Radius.md))
        }
        .buttonStyle(.plain)
        .disabled(isAdded)
        .onHover { inside in
            if inside { hovered = app.bundleID } else if hovered == app.bundleID { hovered = nil }
        }
        .accessibilityLabel(app.name)
        .accessibilityValue(isAdded ? "Added" : (isChosen ? "Selected" : ""))
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }

    /// The apps whose names hold the search text, whatever its case and accents.
    static func matches(_ search: String, in apps: [AppDirectory.App]) -> [AppDirectory.App] {
        let wanted = search.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return apps }
        return apps.filter { $0.name.localizedStandardContains(wanted) }
    }

    /// The sentence under the title. After a suggestion it says who selected the apps and that
    /// the choice is still the person's.
    static func subtitle(isSuggested: Bool, selected: Int) -> String {
        guard isSuggested else { return "Choose the apps that put a heavy load on your Mac." }
        return selected == 0
            ? "Apple Intelligence found no app it knows for heavy work. Choose the apps yourself."
            : "Apple Intelligence selected the apps it knows for heavy work. Change the selection, then click Add."
    }

    /// The line beside the buttons: what to do, or how many apps are selected.
    static func status(chosen: Int) -> String {
        switch chosen {
        case 0: return "Click an app to select it."
        case 1: return "1 app selected"
        default: return "\(chosen) apps selected"
        }
    }
}

/// The icons of installed apps, each read from the system once.
@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for bundleID: String) -> NSImage {
        if let cached = cache[bundleID] { return cached }
        let workspace = NSWorkspace.shared
        let icon = workspace.urlForApplication(withBundleIdentifier: bundleID).map { workspace.icon(forFile: $0.path) }
            ?? workspace.icon(for: .application)
        cache[bundleID] = icon
        return icon
    }
}
