import AppKit
import SwiftUI

@main
struct AirFlowApp: App {
    static let mainWindowID = "main"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let model = AppModel.shared

    var body: some Scene {
        Window("AirFlow", id: Self.mainWindowID) {
            MainWindow()
                .environment(model)
                .font(AirType.body.font)
                .frame(minWidth: Layout.windowMinWidth, minHeight: 560)
        }
        .defaultSize(width: 1200, height: 760)
        // AirFlow lives in the menu bar. The window opens when the person asks for it.
        .defaultLaunchBehavior(.suppressed)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .importExport) {
                Button("Import Presets…") {
                    WindowOpener.shared.open()
                    model.transfer.isImporting = true
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                Button("Export Presets…") {
                    WindowOpener.shared.open()
                    model.beginExport()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model.presets.custom.isEmpty)
            }
        }

        MenuBarExtra {
            MenuPanel()
                .environment(model)
                .font(AirType.body.font)
        } label: {
            MenuBarLabel()
                .environment(model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
                .font(AirType.body.font)
        }
    }
}

/// Lets AppKit code open the SwiftUI window. The menu bar label is always alive, so it hands
/// its `openWindow` action over when it appears.
@MainActor
final class WindowOpener {
    static let shared = WindowOpener()
    var openMain: (() -> Void)?

    /// - Parameter activating: false leaves whatever the person is using in front.
    func open(activating: Bool = true) {
        if activating { NSApp.activate() }
        openMain?()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var observers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        // A script that captures the window can ask for either appearance.
        switch ProcessInfo.processInfo.environment["AIRFLOW_APPEARANCE"] {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        #endif
        AppModel.shared.start()
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let closing = note.name == NSWindow.willCloseNotification ? note.object as? NSWindow : nil
                MainActor.assumeIsolated { self?.updateDockPresence(closing: closing) }
            })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { AppModel.shared.systemDidWake() }
        })
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            // Coming back from System Settings is when the helper's approval changes.
            MainActor.assumeIsolated { AppModel.shared.helper.refresh() }
        })
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.prepareToQuit()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Opening AirFlow again while it runs, from Finder or Spotlight, shows its window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        MainActor.assumeIsolated { WindowOpener.shared.open() }
        return false
    }

    /// AirFlow is a menu bar app with no Dock icon. While its window or Settings is open it
    /// becomes a regular app, so the window can be reached with Command-Tab like any other.
    @MainActor
    private func updateDockPresence(closing: NSWindow?) {
        let hasWindow = NSApp.windows.contains { window in
            window !== closing && window.isVisible && window.styleMask.contains(.titled) && !(window is NSPanel)
        }
        let wanted: NSApplication.ActivationPolicy = hasWindow ? .regular : .accessory
        guard NSApp.activationPolicy() != wanted else { return }
        NSApp.setActivationPolicy(wanted)
    }
}
