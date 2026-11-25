import AppKit
import SwiftUI
import XCTest
@testable import AirFlow

/// Draws the app's surfaces with made-up readings into PNG files, so a person or an agent can
/// look at states that are hard to reach by hand: fans under control, the safeguard, a Mac with
/// no fans. Skipped unless AIRFLOW_SNAPSHOTS names a folder:
///
///     TEST_RUNNER_AIRFLOW_SNAPSHOTS=/tmp/airflow-shots scripts/test.sh
///
/// An off-screen drawing has no Liquid Glass. Look at the running app for the material.
@MainActor
final class SnapshotTests: XCTestCase {
    private var folder: URL?

    override func setUp() async throws {
        guard let path = ProcessInfo.processInfo.environment["AIRFLOW_SNAPSHOTS"], !path.isEmpty else {
            throw XCTSkip("Set AIRFLOW_SNAPSHOTS to a folder to draw the surfaces")
        }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        folder = url
    }

    private func model(helper: HelperManager.Status, active: String, cpu: Double = 68, fans: [Fan]? = nil) throws -> AppModel {
        let suite = "airflow-snapshots-\(UUID().uuidString)"
        let model = AppModel(
            defaults: UserDefaults(suiteName: suite) ?? .standard, presetsURL: nil, rulesURL: nil,
            sampler: HardwareSampler(makeSource: { throw HardwareError.cannotOpenSMC }),
            commander: CommandRecorder(), helper: HelperManager(fixedStatus: helper)
        )
        let preset = try XCTUnwrap(model.presets.preset(named: active))
        model.apply(preset.id)
        let start = Date(timeIntervalSinceNow: -600)
        for step in 0..<120 {
            let wave = sin(Double(step) / 9) * 9
            let current = fans ?? [
                Fan(index: 0, name: "Left Fan", minimumRPM: 1350, maximumRPM: 5349, currentRPM: 2380 + wave * 40, targetRPM: 2400, isManual: helper == .enabled),
                Fan(index: 1, name: "Right Fan", minimumRPM: 1458, maximumRPM: 5777, currentRPM: 2590 + wave * 40, targetRPM: 2600, isManual: helper == .enabled),
            ]
            var snapshot = Fixtures.snapshot(cpu: cpu + wave, gpu: 54 + wave / 2, battery: 33, fans: current, date: start.addingTimeInterval(Double(step) * 5))
            snapshot.sensors += [
                Sensor(key: "TaLP", name: "Airflow Left", group: .enclosure, celsius: 41),
                Sensor(key: "TaRF", name: "Airflow Right", group: .enclosure, celsius: 39),
                Sensor(key: "TH0x", name: "SSD", group: .storage, celsius: 36),
                Sensor(key: "TW0P", name: "Wi-Fi", group: .wireless, celsius: 44),
                Sensor(key: "TPSP", name: "Power Supply", group: .power, celsius: 47),
            ]
            model.monitor.ingest(snapshot)
        }
        return model
    }

    private func draw<Content: View>(_ name: String, width: CGFloat, height: CGFloat? = nil, dark: Bool = true, model: AppModel, @ViewBuilder _ content: () -> Content) throws {
        let folder = try XCTUnwrap(folder)
        let view = content()
            .environment(model)
            .environment(\.airReduceMotion, true)
            .environment(\.airFlatGlass, true)
            .font(AirType.body.font)
            .frame(width: width)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: view)
        host.wantsLayer = true
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let size = CGSize(width: width, height: height ?? host.fittingSize.height)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        // A window that is never on screen commits its layers late. Lay it out, let the run
        // loop turn, and commit before the drawing is taken.
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        CATransaction.flush()
        // The layer tree, not the view's own drawing: SwiftUI draws most of a page into layers.
        let scale: CGFloat = 2
        let context = try XCTUnwrap(CGContext(
            data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        // A hosting view's layer counts down from the top, and a bitmap counts up from the bottom.
        context.translateBy(x: 0, y: size.height * scale)
        context.scaleBy(x: scale, y: -scale)
        try XCTUnwrap(host.layer).render(in: context)
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: folder.appendingPathComponent("\(name).png"))
    }

    func testThePanel() throws {
        let controlling = try model(helper: .enabled, active: "Quiet", cpu: 78)
        try draw("panel-controlling", width: Layout.panelWidth, model: controlling) { MenuPanel() }
        try draw("panel-controlling-light", width: Layout.panelWidth, dark: false, model: controlling) { MenuPanel() }
        let monitoring = try model(helper: .notInstalled, active: "Automatic")
        try draw("panel-monitoring", width: Layout.panelWidth, model: monitoring) { MenuPanel() }
        let approval = try model(helper: .needsApproval, active: "Heavy Workload")
        try draw("panel-approval", width: Layout.panelWidth, model: approval) { MenuPanel() }
    }

    func testAPreset() throws {
        let sensor = try model(helper: .enabled, active: "Quiet", cpu: 78)
        let quiet = try XCTUnwrap(sensor.presets.preset(named: "Quiet"))
        try draw("preset-sensor", width: 640, height: 900, model: sensor) { PresetDetail(preset: quiet) }
        try draw("preset-sensor-light", width: 640, height: 900, dark: false, model: sensor) { PresetDetail(preset: quiet) }

        let heavy = try XCTUnwrap(sensor.presets.preset(named: "Heavy Workload"))
        try draw("preset-not-active", width: 640, height: 900, model: sensor) { PresetDetail(preset: heavy) }

        let constant = try model(helper: .enabled, active: "Full Blast")
        var copy = try XCTUnwrap(constant.presets.duplicate(id: Preset.fullBlastID))
        copy.controls[0] = .constant(rpm: 3200)
        copy.controls[1] = .automatic
        constant.presets.update(copy)
        constant.apply(copy.id)
        constant.monitor.ingest(constant.monitor.snapshot)
        try draw("preset-constant", width: 640, height: 620, model: constant) { PresetDetail(preset: copy) }

        let hot = try model(helper: .enabled, active: "Quiet", cpu: 99)
        let hotQuiet = try XCTUnwrap(hot.presets.preset(named: "Quiet"))
        try draw("preset-safeguard", width: 640, height: 900, model: hot) { PresetDetail(preset: hotQuiet) }

        let fanless = try model(helper: .notInstalled, active: "Automatic", fans: [])
        try draw("preset-no-fans", width: 640, height: 520, model: fanless) { PresetDetail(preset: .automatic) }
    }

    func testRulesTheInspectorAndSensors() throws {
        let model = try model(helper: .enabled, active: "Quiet", cpu: 78)
        let quiet = try XCTUnwrap(model.presets.preset(named: "Quiet"))
        let heavy = try XCTUnwrap(model.presets.preset(named: "Heavy Workload"))
        model.settings.autopilotEnabled = true
        model.automation.add(AutomationRule(trigger: .appIsFrontmost(bundleID: "com.apple.dt.Xcode", name: "Xcode"), presetID: heavy.id))
        model.automation.add(AutomationRule(trigger: .powerSource(.battery), presetID: quiet.id))
        model.automation.add(AutomationRule(trigger: .temperatureAbove(source: .cpuAverage, celsius: 85), presetID: Preset.fullBlastID))
        model.automation.add(AutomationRule(trigger: .timeRange(startMinute: 22 * 60, endMinute: 7 * 60), presetID: quiet.id, isEnabled: false))
        model.monitor.ingest(model.monitor.snapshot)
        try draw("rules", width: 760, height: 520, model: model) { AutomationView() }

        let empty = try self.model(helper: .enabled, active: "Quiet")
        try draw("rules-empty", width: 760, height: 520, model: empty) { AutomationView() }

        try draw("inspector", width: Layout.inspectorWidth, height: 720, model: model) { LiveInspector() }
        try draw("inspector-light", width: Layout.inspectorWidth, height: 720, dark: false, model: model) { LiveInspector() }
        try draw("sensors", width: 640, height: 420, model: model) { SensorsView() }
    }

    func testSettingsAndADraft() throws {
        let model = try model(helper: .enabled, active: "Quiet")
        try draw("settings-general", width: Layout.settingsWidth, height: 380, model: model) { GeneralSettingsPane() }
        try draw("settings-fan-control", width: Layout.settingsWidth, height: 440, model: model) { FanControlSettingsPane() }
        try draw("settings-intelligence", width: Layout.settingsWidth, height: 380, model: model) { IntelligenceSettingsPane() }
        try draw("settings-about", width: Layout.settingsWidth, model: model) { AboutSettingsPane() }

        let draft = PresetProposal(
            name: "Video Calls", mode: .sensorBased, speedPercent: 0, sensor: .cpu, startCelsius: 75,
            fullSpeedCelsius: 98, summary: "Keeps the fans near silent until the CPU is hot."
        ).makePreset()
        try draw("draft", width: 520, model: model) { ProposalPreview(preset: draft).padding(Space.lg) }
    }
}
