import AirFlowBackend
import XCTest
@testable import AirFlow

/// The Swift side of the Rust backend. The backend's own tests (cargo test, in backend/) cover
/// the SMC's byte formats, the sensor names, the fan writer's limits, and the trust rule. These
/// tests cover what crosses the C interface and how the app is put together around it.
final class BackendBridgeTests: XCTestCase {
    func testTheBackendsSampleMacCrossesTheBridge() throws {
        let reader = try XCTUnwrap(BackendReader(sample: true))
        let snapshot = reader.snapshot(at: Date(timeIntervalSince1970: 10))
        XCTAssertEqual(snapshot.date, Date(timeIntervalSince1970: 10))
        XCTAssertEqual(snapshot.fans.map(\.name), ["Left Fan", "Right Fan"])
        XCTAssertEqual(snapshot.fans[0].currentRPM, 2400)
        XCTAssertEqual(snapshot.fans[0].minimumRPM, 1350)
        XCTAssertEqual(snapshot.fans[0].maximumRPM, 5349)
        XCTAssertTrue(snapshot.fans[0].isManual)
        XCTAssertFalse(snapshot.fans[1].isManual)
        XCTAssertEqual(snapshot.fans[1].index, 1)

        let byKey = Dictionary(uniqueKeysWithValues: snapshot.sensors.map { ($0.key, $0) })
        XCTAssertEqual(snapshot.sensors.count, 7)
        XCTAssertEqual(byKey["Tp01"]?.group, .cpu)
        XCTAssertEqual(byKey["Tp01"]?.celsius, 61)
        XCTAssertEqual(byKey["Te05"]?.name, "Efficiency Core Sensor 1")
        XCTAssertEqual(byKey["Te05"]?.isKnown, false)
        XCTAssertEqual(byKey["TB1T"]?.isKnown, true)
        XCTAssertEqual(byKey["Tg0D"]?.group, .gpu)
        XCTAssertEqual(byKey["TaLP"]?.name, "Airflow Left")
        XCTAssertEqual(byKey["TaLP"]?.group, .enclosure)
        XCTAssertEqual(byKey["TB1T"]?.group, .battery)
        XCTAssertEqual(byKey["TH0x"]?.name, "SSD")
        XCTAssertEqual(snapshot.summary(of: .cpu)?.count, 3)
    }

    func testTheGroupsAreNumberedAsTheBackendNumbersThem() {
        XCTAssertEqual(Int(SensorGroup.cpu.backendCode), Int(AIRFLOW_GROUP_CPU))
        XCTAssertEqual(Int(SensorGroup.gpu.backendCode), Int(AIRFLOW_GROUP_GPU))
        XCTAssertEqual(Int(SensorGroup.memory.backendCode), Int(AIRFLOW_GROUP_MEMORY))
        XCTAssertEqual(Int(SensorGroup.storage.backendCode), Int(AIRFLOW_GROUP_STORAGE))
        XCTAssertEqual(Int(SensorGroup.battery.backendCode), Int(AIRFLOW_GROUP_BATTERY))
        XCTAssertEqual(Int(SensorGroup.enclosure.backendCode), Int(AIRFLOW_GROUP_ENCLOSURE))
        XCTAssertEqual(Int(SensorGroup.power.backendCode), Int(AIRFLOW_GROUP_POWER))
        XCTAssertEqual(Int(SensorGroup.wireless.backendCode), Int(AIRFLOW_GROUP_WIRELESS))
        XCTAssertEqual(Int(SensorGroup.other.backendCode), Int(AIRFLOW_GROUP_OTHER))
        XCTAssertEqual(SensorGroup(backendCode: 200), .other, "A group this app does not know is not a crash")
        for group in SensorGroup.allCases {
            XCTAssertEqual(SensorGroup(backendCode: group.backendCode), group)
        }
    }

    func testTheHelperIsInsideTheAppWhereItsPropertyListPoints() throws {
        let plist = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchDaemons/\(HelperManager.daemonPlistName)")
        let values = try XCTUnwrap(NSDictionary(contentsOf: plist) as? [String: Any], "The daemon's property list is not in the app")
        XCTAssertEqual(values["Label"] as? String, AIRFLOW_HELPER_SERVICE)
        XCTAssertEqual((values["MachServices"] as? [String: Any])?.keys.map { $0 }, [AIRFLOW_HELPER_SERVICE])
        let program = try XCTUnwrap(values["BundleProgram"] as? String)
        let helper = Bundle.main.bundleURL.appendingPathComponent(program)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: helper.path), "\(program) is not in the app")
        XCTAssertEqual(
            Set(values["AssociatedBundleIdentifiers"] as? [String] ?? []), ["com.kevster.airflow", "com.kevster.airflow.debug"]
        )
    }

    func testTheAppDemandsTheHelpersIdentifierOrTrustsNoHelper() {
        // A copy signed by a team requires that team's helper. An ad hoc copy, which is what the
        // tests usually run in, gets no requirement and so opens no connection.
        if let requirement = Backend.helperRequirement {
            XCTAssertTrue(requirement.contains("identifier \"com.kevster.airflow.helper\""))
            XCTAssertTrue(requirement.hasPrefix("anchor apple generic and certificate leaf[subject.OU] = "))
        }
    }

    func testAnAppWithNoSignatureCannotReachTheHelper() async throws {
        try XCTSkipIf(Backend.helperRequirement != nil, "This copy is signed by a team")
        let client = HelperClient()
        do {
            try await client.setFan(0, rpm: 3000)
            XCTFail("An unsigned copy sent a fan command")
        } catch {
            XCTAssertEqual(error as? HelperError, .unsignedBuild)
        }
        let version = await client.protocolVersion()
        XCTAssertNil(version)
    }

    func testAnUnsignedCopyOffersNoControl() async {
        let manager = await HelperManager(isSigned: false)
        let status = await manager.status
        XCTAssertEqual(status, .unsignedBuild)
        await manager.install()
        let after = await manager.status
        XCTAssertEqual(after, .unsignedBuild, "Installing does nothing without a team's signature")
        XCTAssertFalse(after.allowsControl)
    }

    @MainActor
    func testTheHelperComingOnIsAnnouncedForAShortTime() {
        let now = Date()
        XCTAssertFalse(HelperManager(fixedStatus: .enabled).justEnabled(now: now), "A helper that was already on is not news")
        let manager = HelperManager(fixedStatus: .enabled, enabledAt: now)
        XCTAssertTrue(manager.justEnabled(now: now.addingTimeInterval(2)))
        XCTAssertFalse(manager.justEnabled(now: now.addingTimeInterval(HelperManager.announcementSeconds + 1)))
    }
}

/// What an installed copy needs to find and trust an update.
final class UpdateSettingsTests: XCTestCase {
    func testTheAppNamesItsAppcastAndTheKeyUpdatesMustBeSignedWith() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        let feed = try XCTUnwrap(info["SUFeedURL"] as? String)
        XCTAssertEqual(feed, "https://raw.githubusercontent.com/nich227/AirFlow/gh-pages/updates.xml.rss")
        let key = try XCTUnwrap(info["SUPublicEDKey"] as? String)
        XCTAssertEqual(Data(base64Encoded: key)?.count, 32, "An Ed25519 public key is 32 bytes")
        XCTAssertEqual(info["SUEnableAutomaticChecks"] as? Bool, true)
    }

    @MainActor
    func testACopyUnderTestNeverStartsTheUpdater() {
        Updates.shared.start()
        XCTAssertFalse(Updates.shared.isAvailable)
        XCTAssertFalse(Updates.shared.canCheck)
        XCTAssertFalse(Updates.shared.checksAutomatically)
    }
}
