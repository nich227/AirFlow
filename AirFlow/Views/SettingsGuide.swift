import AppKit
import SwiftUI

/// A small panel that floats beside System Settings while AirFlow waits to be allowed there. It
/// says what to do in that window, follows the window when it moves, and closes by itself when the
/// switch is on. An app cannot draw inside System Settings, and finding the switch itself would
/// need the Accessibility permission, so the panel sits next to the window instead.
@MainActor
final class SettingsGuide {
    static let shared = SettingsGuide()

    private var panel: NSPanel?
    private var timer: Timer?
    private var finishedAt: Date?
    private static let size = NSSize(width: 300, height: 196)
    private static let settingsBundleID = "com.apple.systempreferences"

    /// Shows the panel and keeps it beside System Settings until fan control is on.
    /// - Parameter watches: false only for a script that captures the panel, which shows it and
    ///   leaves it there.
    func show(model: AppModel, watches: Bool = true) {
        guard !AppModel.isRunningTests else { return }
        finishedAt = nil
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: Self.size),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
            )
            panel.level = .floating
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = true
            panel.isMovableByWindowBackground = true
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = NSHostingView(rootView: SettingsGuideView(close: { [weak self] in self?.hide() }).environment(model))
            self.panel = panel
        }
        place()
        panel?.orderFrontRegardless()
        timer?.invalidate()
        guard watches else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick(model: model) }
        }
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
    }

    private func tick(model: AppModel) {
        model.helper.refresh()
        place()
        switch model.helper.status {
        case .needsApproval:
            break
        case .enabled:
            // The panel says that it worked for a moment, then AirFlow comes back to the front.
            if let finishedAt {
                if Date().timeIntervalSince(finishedAt) > 2 {
                    hide()
                    WindowOpener.shared.open()
                }
            } else {
                finishedAt = Date()
            }
        default:
            hide()
        }
    }

    /// Puts the panel beside the System Settings window: to its right, or to its left when the
    /// screen has no room there. With no such window, the panel keeps its place.
    private func place() {
        guard let panel, let settings = Self.settingsFrame() else { return }
        let screen = NSScreen.screens.first { $0.frame.intersects(settings) }?.visibleFrame ?? settings
        var origin = NSPoint(x: settings.maxX + 12, y: settings.maxY - Self.size.height - 40)
        if origin.x + Self.size.width > screen.maxX {
            origin.x = settings.minX - Self.size.width - 12
        }
        if origin.x < screen.minX {
            origin.x = settings.maxX - Self.size.width - 24
        }
        origin.y = min(max(origin.y, screen.minY), screen.maxY - Self.size.height)
        panel.setFrameOrigin(origin)
    }

    /// The frame of System Settings' main window, in AppKit's coordinates.
    private static func settingsFrame() -> NSRect? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        guard let primary = NSScreen.screens.first else { return nil }
        for window in windows {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == settingsBundleID,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"], let width = bounds["Width"], let height = bounds["Height"],
                  width > 300, height > 300 else { continue }
            // Core Graphics counts down from the top of the first screen, and AppKit counts up.
            return NSRect(x: x, y: primary.frame.maxY - y - height, width: width, height: height)
        }
        return nil
    }
}

private struct SettingsGuideView: View {
    @Environment(AppModel.self) private var model
    let close: () -> Void

    var body: some View {
        let isOn = model.helper.status == .enabled
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack {
                AntIcon("MenuBarIcon", size: IconSize.title)
                    .foregroundStyle(Palette.accent)
                Text(isOn ? "Fan Control Is On" : "Turn On AirFlow Here")
                    .airFont(.title)
                Spacer()
                Button(action: close) {
                    AntIcon("ant-close-circle", size: IconSize.row)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Close")
            }
            if isOn {
                Text("That's it. AirFlow can now change your fan speeds.")
                    .airFont(.body)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("1. In System Settings, find AirFlow under Allow in the Background.")
                    .airFont(.body)
                    .fixedSize(horizontal: false, vertical: true)
                Text("2. Turn on the switch next to it. Your Mac may ask for your password or Touch ID.")
                    .airFont(.body)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Space.xs) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for the switch…")
                        .airFont(.label)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Space.md)
        .frame(width: 300, height: 196, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Radius.card).stroke(Palette.accent.opacity(0.6), lineWidth: 2))
        .font(AirType.body.font)
    }
}
