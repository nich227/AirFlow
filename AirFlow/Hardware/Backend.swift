import AirFlowBackend
import Foundation

// The Swift side of the Rust backend. Everything that touches the Mac itself (the SMC, the fans,
// the sensors, the power source, and the helper) is Rust in backend/. These types turn its C
// interface (backend/include/airflow.h) into the app's own models.

/// Something that can be asked for the current readings. Tests supply their own.
protocol SnapshotSource {
    /// - Parameter groups: the parts whose sensors are read now. Each other sensor has its
    ///   last reading.
    func snapshot(at date: Date, groups: Set<SensorGroup>) -> ThermalSnapshot
}

/// The backend's reader of fans and temperature sensors. Reading needs no privilege.
final class BackendReader: SnapshotSource {
    /// Room for more fans and sensors than any Mac reports.
    static let maximumFans = 16
    static let maximumSensors = 1024

    private let reader: OpaquePointer
    /// Filled by each read. One reader is used from one thread at a time, so it is kept.
    private var sensorBuffer = [AirflowSensor](repeating: AirflowSensor(), count: BackendReader.maximumSensors)

    /// - Parameter sample: read the backend's made-up Mac, for tests of this bridge.
    init?(sample: Bool = false) {
        guard let opened = sample ? airflow_reader_open_sample() : airflow_reader_open() else { return nil }
        reader = opened
    }

    deinit {
        airflow_reader_close(reader)
    }

    func readFans() -> [Fan] {
        var buffer = [AirflowFan](repeating: AirflowFan(), count: Self.maximumFans)
        let count = Int(airflow_reader_read_fans(reader, &buffer, Int32(buffer.count)))
        return buffer.prefix(count).map { raw in
            Fan(
                index: Int(raw.index),
                name: Fan.name(index: Int(raw.index), count: count),
                minimumRPM: raw.minimum_rpm,
                maximumRPM: raw.maximum_rpm,
                currentRPM: raw.current_rpm,
                targetRPM: raw.target_rpm,
                isManual: raw.is_manual
            )
        }
    }

    /// Every sensor. Only the sensors of `groups` are read now, and each other sensor has its
    /// last reading: one key takes about a tenth of a millisecond, and a Mac has a few hundred.
    func readSensors(groups: Set<SensorGroup> = Set(SensorGroup.allCases)) -> [Sensor] {
        let mask = groups.reduce(UInt32(0)) { $0 | (1 << UInt32($1.backendCode)) }
        let count = Int(airflow_reader_read_sensors_in(reader, &sensorBuffer, Int32(sensorBuffer.count), mask))
        return sensorBuffer.prefix(count).map { raw in
            Sensor(
                key: Self.text(raw.key),
                name: Self.text(raw.name),
                group: SensorGroup(backendCode: raw.group),
                celsius: raw.celsius,
                isKnown: raw.is_known
            )
        }
    }

    /// The power the whole Mac draws, in watts, or nil where the SMC does not report it.
    func readSystemPower() -> Double? {
        let watts = airflow_reader_read_system_power(reader)
        return watts > 0 ? watts : nil
    }

    func snapshot(at date: Date = Date(), groups: Set<SensorGroup> = Set(SensorGroup.allCases)) -> ThermalSnapshot {
        ThermalSnapshot(date: date, fans: readFans(), sensors: readSensors(groups: groups), systemWatts: readSystemPower())
    }

    /// A fixed C field of NUL-terminated UTF-8 as a string.
    private static func text<Field>(_ field: Field) -> String {
        withUnsafeBytes(of: field) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

extension SensorGroup {
    /// The backend numbers the groups in the order `allCases` lists them.
    init(backendCode: UInt8) {
        let all = SensorGroup.allCases
        self = all.indices.contains(Int(backendCode)) ? all[Int(backendCode)] : .other
    }

    var backendCode: UInt8 {
        UInt8(SensorGroup.allCases.prefix { $0 != self }.count)
    }

    var sortIndex: Int { Int(backendCode) }
}

/// One running app with what its processes use, added up. The backend counts a helper process
/// for the outermost app that holds it.
struct AppUsage: Equatable, Sendable {
    /// The app's bundle, such as `/Applications/Xcode.app`.
    var bundlePath: String
    /// The processor time the app's processes have used since they started.
    var cpuSeconds: Double
    /// How long ago the app's oldest process started.
    var runningSeconds: Double
    var memoryBytes: UInt64 = 0
}

enum Backend {
    static var isOnBattery: Bool {
        airflow_power_source_is_battery() == 1
    }

    /// More running apps than a Mac has open at once.
    static let maximumApps = 512

    /// The running apps, the one with the most processor time first. Reading needs no privilege.
    static func appUsage() -> [AppUsage] {
        var buffer = [AirflowAppUsage](repeating: AirflowAppUsage(), count: maximumApps)
        let count = Int(airflow_app_usage(&buffer, Int32(buffer.count)))
        return buffer.prefix(count).map { raw in
            AppUsage(
                bundlePath: withUnsafeBytes(of: raw.bundle_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) },
                cpuSeconds: raw.cpu_seconds, runningSeconds: raw.running_seconds, memoryBytes: raw.memory_bytes
            )
        }
    }

    /// The code signing requirement the app sets on its connection to the helper. Nil when this
    /// copy of the app has no team's signature and so can trust no helper.
    static let helperRequirement: String? = {
        var buffer = [CChar](repeating: 0, count: 512)
        let length = airflow_helper_requirement(&buffer, Int32(buffer.count))
        return length > 0 ? String(cString: buffer) : nil
    }()
}

/// Runs the reader off the main thread.
actor HardwareSampler {
    private var source: SnapshotSource?
    private let makeSource: () throws -> SnapshotSource

    init(makeSource: @escaping () throws -> SnapshotSource) {
        self.makeSource = makeSource
    }

    func sample(groups: Set<SensorGroup> = Set(SensorGroup.allCases)) throws -> ThermalSnapshot {
        let open: SnapshotSource
        if let source {
            open = source
        } else {
            open = try makeSource()
            source = open
        }
        return open.snapshot(at: Date(), groups: groups)
    }

    // coverage:off It opens the Mac's own SMC, which a test must not depend on.
    /// A sampler that reads this Mac.
    init() {
        makeSource = HardwareSampler.openBackend
    }

    static func openBackend() throws -> SnapshotSource {
        guard let reader = BackendReader() else { throw HardwareError.cannotOpenSMC }
        return reader
    }
    // coverage:on
}

enum HardwareError: Error {
    case cannotOpenSMC
}
