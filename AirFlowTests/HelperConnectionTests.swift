import AirFlowBackend
import ServiceManagement
import XCTest
import XPC
@testable import AirFlow

/// A helper made of an anonymous XPC listener in the test's own process. It answers as the real
/// helper does, so the client's side of the conversation runs over real XPC.
final class FakeHelper: @unchecked Sendable {
    enum Behavior {
        case answers
        /// Says no, with a reason or without one.
        case refuses(String?)
        /// Closes the connection and sends no answer.
        case hangsUp
        /// Keeps the request and never answers.
        case silent
    }

    struct Request: Equatable {
        var operation: String
        var fan: Int64?
        var rpm: Double?
    }

    private let queue = DispatchQueue(label: "com.kevster.airflow.tests.helper")
    private let listener: xpc_connection_t
    private let lock = NSLock()
    private var peers: [xpc_connection_t] = []
    private var kept: [xpc_object_t] = []
    private var received: [Request] = []
    private var opened = 0
    private var current = Behavior.answers

    init() {
        listener = xpc_connection_create(nil, queue)
        xpc_connection_set_event_handler(listener) { [weak self] peer in
            guard xpc_get_type(peer) == XPC_TYPE_CONNECTION else { return }
            self?.accept(peer)
        }
        xpc_connection_activate(listener)
    }

    deinit {
        xpc_connection_cancel(listener)
    }

    var behavior: Behavior {
        get { locked { current } }
        set { locked { current = newValue } }
    }

    /// Every request received, in order.
    var requests: [Request] { locked { received } }

    /// How many connections the client has made.
    var connections: Int { locked { opened } }

    /// What a client is made with: a connection to this helper, not yet activated.
    var connect: @Sendable (DispatchQueue) throws -> xpc_connection_t {
        { [self] _ in
            locked { opened += 1 }
            return xpc_connection_create_from_endpoint(xpc_endpoint_create(listener))
        }
    }

    /// Closes every connection, as a helper that exits does.
    func dropClients() {
        for peer in locked({ peers }) { xpc_connection_cancel(peer) }
    }

    /// Sends every client a message that it did not ask for.
    func sendUnasked() {
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(message, "note", "hello")
        for peer in locked({ peers }) { xpc_connection_send_message(peer, message) }
    }

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func accept(_ peer: xpc_connection_t) {
        locked { peers.append(peer) }
        xpc_connection_set_event_handler(peer) { [weak self] message in
            guard let self, xpc_get_type(message) == XPC_TYPE_DICTIONARY else { return }
            self.answer(message, from: peer)
        }
        xpc_connection_activate(peer)
    }

    private func answer(_ message: xpc_object_t, from peer: xpc_connection_t) {
        let operation = xpc_dictionary_get_string(message, AIRFLOW_KEY_OPERATION).map { String(cString: $0) } ?? ""
        let hasFan = xpc_dictionary_get_value(message, AIRFLOW_KEY_FAN) != nil
        let hasSpeed = xpc_dictionary_get_value(message, AIRFLOW_KEY_RPM) != nil
        let request = Request(
            operation: operation,
            fan: hasFan ? xpc_dictionary_get_int64(message, AIRFLOW_KEY_FAN) : nil,
            rpm: hasSpeed ? xpc_dictionary_get_double(message, AIRFLOW_KEY_RPM) : nil
        )
        let behavior = locked {
            received.append(request)
            return current
        }
        switch behavior {
        case .answers:
            guard let reply = xpc_dictionary_create_reply(message) else { return }
            xpc_dictionary_set_bool(reply, AIRFLOW_KEY_OK, true)
            xpc_dictionary_set_string(reply, AIRFLOW_KEY_VERSION, AIRFLOW_HELPER_PROTOCOL_VERSION)
            xpc_connection_send_message(peer, reply)
        case .refuses(let reason):
            guard let reply = xpc_dictionary_create_reply(message) else { return }
            xpc_dictionary_set_bool(reply, AIRFLOW_KEY_OK, false)
            if let reason { xpc_dictionary_set_string(reply, AIRFLOW_KEY_ERROR, reason) }
            xpc_connection_send_message(peer, reply)
        case .hangsUp:
            xpc_connection_cancel(peer)
        case .silent:
            locked { kept.append(message) }
        }
    }
}

final class HelperClientConnectionTests: XCTestCase {
    private func refusal(_ body: () async throws -> Void) async -> HelperError? {
        do {
            try await body()
            return nil
        } catch {
            return error as? HelperError
        }
    }

    func testARequestCarriesItsOperationItsFanAndItsSpeed() async throws {
        let helper = FakeHelper()
        let client = HelperClient(connect: helper.connect)
        try await client.setFan(1, rpm: 2400)
        try await client.setFanAutomatic(0)
        try await client.resetAllFans()
        await client.keepAlive()
        let version = await client.protocolVersion()
        XCTAssertEqual(version, AIRFLOW_HELPER_PROTOCOL_VERSION)
        XCTAssertEqual(helper.requests, [
            .init(operation: AIRFLOW_OP_SET_FAN, fan: 1, rpm: 2400),
            .init(operation: AIRFLOW_OP_SET_AUTOMATIC, fan: 0, rpm: nil),
            .init(operation: AIRFLOW_OP_RESET_ALL, fan: nil, rpm: nil),
            .init(operation: AIRFLOW_OP_KEEP_ALIVE, fan: nil, rpm: nil),
            .init(operation: AIRFLOW_OP_VERSION, fan: nil, rpm: nil),
        ])
        XCTAssertEqual(helper.connections, 1, "Every request goes over the one connection")
    }

    func testAMessageNamesAFanAndASpeedOnlyWhenItHasThem() {
        let full = HelperClient.message(AIRFLOW_OP_SET_FAN, fan: 2, rpm: 1800)
        XCTAssertEqual(xpc_dictionary_get_string(full, AIRFLOW_KEY_OPERATION).map { String(cString: $0) }, AIRFLOW_OP_SET_FAN)
        XCTAssertEqual(xpc_dictionary_get_int64(full, AIRFLOW_KEY_FAN), 2)
        XCTAssertEqual(xpc_dictionary_get_double(full, AIRFLOW_KEY_RPM), 1800)
        // The helper reads a missing fan as no fan, so a request without one must not carry a zero.
        let bare = HelperClient.message(AIRFLOW_OP_RESET_ALL)
        XCTAssertNil(xpc_dictionary_get_value(bare, AIRFLOW_KEY_FAN))
        XCTAssertNil(xpc_dictionary_get_value(bare, AIRFLOW_KEY_RPM))
        XCTAssertEqual(xpc_dictionary_get_count(bare), 1)
    }

    func testARefusalComesBackWithTheHelpersReason() async {
        let helper = FakeHelper()
        let client = HelperClient(connect: helper.connect)
        helper.behavior = .refuses("This Mac has no fan 3.")
        let named = await refusal { try await client.setFan(2, rpm: 3000) }
        XCTAssertEqual(named, .refused("This Mac has no fan 3."))
        XCTAssertEqual(named?.errorDescription, "This Mac has no fan 3.")
        helper.behavior = .refuses(nil)
        let unnamed = await refusal { try await client.resetAllFans() }
        XCTAssertEqual(unnamed, .refused("The helper refused the request."))
        // Keeping the connection alive never fails the caller, and a refusal has no version.
        await client.keepAlive()
        let version = await client.protocolVersion()
        XCTAssertNil(version)
        XCTAssertEqual(helper.connections, 1, "A refusal is an answer, so the connection stays")
    }

    func testAHelperThatHangsUpIsReachedAgainOnTheNextRequest() async throws {
        let helper = FakeHelper()
        let client = HelperClient(connect: helper.connect)
        helper.behavior = .hangsUp
        let lost = await refusal { try await client.setFan(0, rpm: 3000) }
        XCTAssertEqual(lost, .notConnected)
        XCTAssertEqual(HelperError.notConnected.errorDescription, "AirFlow can't connect to its helper tool.")
        helper.behavior = .answers
        try await client.setFan(0, rpm: 3000)
        XCTAssertEqual(helper.connections, 2, "The connection that ended is not used again")
        XCTAssertEqual(helper.requests.count, 2)
    }

    func testAConnectionThatEndsWhileIdleIsReplaced() async throws {
        let helper = FakeHelper()
        let client = HelperClient(connect: helper.connect)
        try await client.resetAllFans()
        // A message the client did not ask for is not the end of the connection.
        helper.sendUnasked()
        try await Task.sleep(for: .milliseconds(100))
        try await client.resetAllFans()
        XCTAssertEqual(helper.connections, 1)
        // The helper exits when it has been idle. The client hears of it and opens a new
        // connection for the next request, which therefore does not fail.
        helper.dropClients()
        try await Task.sleep(for: .milliseconds(300))
        try await client.setFan(0, rpm: 2000)
        XCTAssertEqual(helper.connections, 2)
    }

    func testDisconnectingClosesTheConnectionAndTheNextRequestOpensAnother() async throws {
        let helper = FakeHelper()
        let client = HelperClient(connect: helper.connect)
        client.disconnect()
        XCTAssertEqual(helper.connections, 0, "There was nothing to close")
        try await client.resetAllFans()
        client.disconnect()
        client.disconnect()
        try await client.resetAllFans()
        XCTAssertEqual(helper.connections, 2)
    }

    func testTheFansAreGivenBackBeforeTheAppQuits() async throws {
        let helper = FakeHelper()
        let client = HelperClient(connect: helper.connect)
        client.resetAllFansBeforeQuitting()
        XCTAssertEqual(helper.requests, [.init(operation: AIRFLOW_OP_RESET_ALL, fan: nil, rpm: nil)])

        // A helper that does not answer holds the app up no longer than the wait it is given.
        helper.behavior = .silent
        let start = Date()
        client.resetAllFansBeforeQuitting(timeout: 0.1)
        let waited = Date().timeIntervalSince(start)
        XCTAssertGreaterThanOrEqual(waited, 0.09)
        XCTAssertLessThan(waited, 1.5)
        XCTAssertEqual(helper.requests.count, 2)

        // A copy that reaches no helper has nothing to ask.
        let unsigned = HelperClient(requirement: nil)
        unsigned.resetAllFansBeforeQuitting()
        let error = await refusal { try await unsigned.setFan(0, rpm: 3000) }
        XCTAssertEqual(error, .unsignedBuild)
        XCTAssertEqual(error?.errorDescription, "This copy of AirFlow isn't signed, so it can only monitor.")
    }
}

/// The system's record of the helper, made up.
final class FakeRegistration: DaemonRegistration, @unchecked Sendable {
    var status: SMAppService.Status
    /// The status the system reports once the helper is registered.
    var statusWhenRegistered = SMAppService.Status.requiresApproval
    var registerFailure: Error?
    var unregisterFailure: Error?
    private(set) var registrations = 0
    private(set) var removals = 0
    private(set) var timesSettingsOpened = 0

    init(status: SMAppService.Status = .notRegistered) {
        self.status = status
    }

    func register() throws {
        registrations += 1
        if let registerFailure { throw registerFailure }
        status = statusWhenRegistered
    }

    func unregister() async throws {
        removals += 1
        if let unregisterFailure { throw unregisterFailure }
        status = .notRegistered
    }

    func openLoginItems() {
        timesSettingsOpened += 1
    }
}

private struct Refused: LocalizedError {
    var errorDescription: String? { "Operation not permitted" }
}

@MainActor
final class HelperManagerTests: XCTestCase {
    func testTheSystemsStatusIsReadAsOneOfThree() {
        let service = FakeRegistration()
        let manager = HelperManager(isSigned: true, service: service)
        XCTAssertEqual(manager.status, .notInstalled)
        for (system, expected) in [
            (SMAppService.Status.enabled, HelperManager.Status.enabled), (.requiresApproval, .needsApproval),
            (.notRegistered, .notInstalled), (.notFound, .notInstalled),
        ] {
            service.status = system
            manager.refresh()
            XCTAssertEqual(manager.status, expected)
        }
        XCTAssertTrue(HelperManager.Status.enabled.allowsControl)
        XCTAssertFalse(HelperManager.Status.needsApproval.allowsControl)
    }

    func testInstallingRegistersTheHelperAndApprovalTurnsItOn() {
        let service = FakeRegistration()
        let manager = HelperManager(isSigned: true, service: service)
        manager.install()
        XCTAssertEqual(service.registrations, 1)
        XCTAssertEqual(manager.status, .needsApproval)
        XCTAssertFalse(manager.justEnabled(), "It is not on yet")
        // The person allows it in System Settings.
        service.status = .enabled
        manager.refresh()
        XCTAssertEqual(manager.status, .enabled)
        XCTAssertTrue(manager.justEnabled(), "The helper came on while the app ran")
        manager.openLoginItems()
        XCTAssertEqual(service.timesSettingsOpened, 1)
    }

    func testAHelperThatWasAlreadyOnIsNotAnnounced() {
        let manager = HelperManager(isSigned: true, service: FakeRegistration(status: .enabled))
        XCTAssertEqual(manager.status, .enabled)
        XCTAssertNil(manager.enabledAt)
        XCTAssertFalse(manager.justEnabled())
    }

    func testAFailedInstallSaysWhyUnlessTheSystemAlreadyHasTheHelper() {
        let refused = FakeRegistration()
        refused.registerFailure = Refused()
        let manager = HelperManager(isSigned: true, service: refused)
        manager.install()
        XCTAssertEqual(manager.status, .failed("Operation not permitted"))
        XCTAssertFalse(manager.status.allowsControl)

        // macOS reports an error for a helper that waits for approval. The status says more.
        let waiting = FakeRegistration(status: .requiresApproval)
        waiting.registerFailure = Refused()
        let second = HelperManager(isSigned: true, service: waiting)
        second.install()
        XCTAssertEqual(second.status, .needsApproval)
    }

    func testRemovingUnregistersTheHelper() async {
        let service = FakeRegistration(status: .enabled)
        let manager = HelperManager(isSigned: true, service: service)
        await manager.remove()
        XCTAssertEqual(service.removals, 1)
        XCTAssertEqual(manager.status, .notInstalled)

        service.status = .enabled
        manager.refresh()
        service.unregisterFailure = Refused()
        await manager.remove()
        XCTAssertEqual(manager.status, .failed("Operation not permitted"))
    }

    func testACopyWithNoTeamAndAManagerWithAFixedStatusNeverTouchTheSystem() async throws {
        let service = FakeRegistration(status: .enabled)
        let unsigned = HelperManager(isSigned: false, service: service)
        XCTAssertEqual(unsigned.status, .unsignedBuild)
        unsigned.install()
        XCTAssertEqual(unsigned.status, .unsignedBuild)
        XCTAssertEqual(service.registrations, 0)

        let fixed = HelperManager(fixedStatus: .needsApproval)
        fixed.install()
        await fixed.remove()
        fixed.refresh()
        fixed.openLoginItems()
        XCTAssertEqual(fixed.status, .needsApproval)

        try XCTSkipIf(Backend.helperRequirement != nil, "This copy is signed by a team")
        XCTAssertEqual(HelperManager().status, .unsignedBuild, "The app under test has no team's signature")
    }
}
