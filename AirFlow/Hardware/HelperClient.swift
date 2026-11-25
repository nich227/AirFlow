import AirFlowBackend
import Foundation
import ServiceManagement
import XPC

/// What the control loop needs from the helper. Tests supply a recorder.
protocol FanCommanding: AnyObject, Sendable {
    func setFan(_ index: Int, rpm: Double) async throws
    func setFanAutomatic(_ index: Int) async throws
    func resetAllFans() async throws
    func keepAlive() async
}

enum HelperError: Error, LocalizedError, Equatable {
    case unsignedBuild
    case notConnected
    case refused(String)

    var errorDescription: String? {
        switch self {
        case .unsignedBuild: return "This copy of AirFlow isn't signed, so it can only monitor."
        case .notConnected: return "AirFlow can't reach its helper."
        case .refused(let message): return message
        }
    }
}

/// The XPC connection to the privileged helper, which is Rust (backend/src/bin/helper.rs).
/// The two sides exchange plain XPC dictionaries whose keys backend/include/airflow.h names.
final class HelperClient: FanCommanding, @unchecked Sendable {
    private let lock = NSLock()
    private var connection: xpc_connection_t?
    private let queue = DispatchQueue(label: "com.kevster.airflow.helper.client")

    func setFan(_ index: Int, rpm: Double) async throws {
        try await send(AIRFLOW_OP_SET_FAN, fan: index, rpm: rpm)
    }

    func setFanAutomatic(_ index: Int) async throws {
        try await send(AIRFLOW_OP_SET_AUTOMATIC, fan: index)
    }

    func resetAllFans() async throws {
        try await send(AIRFLOW_OP_RESET_ALL)
    }

    func keepAlive() async {
        _ = try? await send(AIRFLOW_OP_KEEP_ALIVE)
    }

    /// The version of the messages the helper speaks, or nil when it cannot be reached.
    func protocolVersion() async -> String? {
        try? await send(AIRFLOW_OP_VERSION)
    }

    /// Asks the helper to return every fan to the system and waits a short time for the answer.
    /// The helper does the same by itself when the connection closes.
    func resetAllFansBeforeQuitting(timeout: TimeInterval = 2) {
        guard let connection = try? openConnection() else { return }
        let done = DispatchSemaphore(value: 0)
        xpc_connection_send_message_with_reply(connection, Self.message(AIRFLOW_OP_RESET_ALL), queue) { _ in done.signal() }
        _ = done.wait(timeout: .now() + timeout)
    }

    func disconnect() {
        lock.lock()
        let old = connection
        connection = nil
        lock.unlock()
        if let old { xpc_connection_cancel(old) }
    }

    private static func message(_ operation: String, fan: Int? = nil, rpm: Double? = nil) -> xpc_object_t {
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(message, AIRFLOW_KEY_OPERATION, operation)
        if let fan { xpc_dictionary_set_int64(message, AIRFLOW_KEY_FAN, Int64(fan)) }
        if let rpm { xpc_dictionary_set_double(message, AIRFLOW_KEY_RPM, rpm) }
        return message
    }

    /// Sends one request and returns the helper's protocol version from its answer.
    @discardableResult
    private func send(_ operation: String, fan: Int? = nil, rpm: Double? = nil) async throws -> String? {
        let connection = try openConnection()
        let message = Self.message(operation, fan: fan, rpm: rpm)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String?, Error>) in
            // XPC calls the handler exactly once, with the reply or with an error.
            xpc_connection_send_message_with_reply(connection, message, queue) { [weak self] reply in
                guard xpc_get_type(reply) == XPC_TYPE_DICTIONARY else {
                    self?.disconnect()
                    continuation.resume(throwing: HelperError.notConnected)
                    return
                }
                if xpc_dictionary_get_bool(reply, AIRFLOW_KEY_OK) {
                    continuation.resume(returning: xpc_dictionary_get_string(reply, AIRFLOW_KEY_VERSION).map { String(cString: $0) })
                } else {
                    let reason = xpc_dictionary_get_string(reply, AIRFLOW_KEY_ERROR).map { String(cString: $0) }
                    continuation.resume(throwing: HelperError.refused(reason ?? "The helper refused the request."))
                }
            }
        }
    }

    private func openConnection() throws -> xpc_connection_t {
        lock.lock()
        defer { lock.unlock() }
        if let connection { return connection }
        // The helper must carry the same team's signature as the app. XPC drops any peer
        // that does not, before a single message is delivered.
        guard let requirement = Backend.helperRequirement else { throw HelperError.unsignedBuild }
        let opened = xpc_connection_create_mach_service(AIRFLOW_HELPER_SERVICE, queue, UInt64(XPC_CONNECTION_MACH_SERVICE_PRIVILEGED))
        guard xpc_connection_set_peer_code_signing_requirement(opened, requirement) == 0 else {
            xpc_connection_cancel(opened)
            throw HelperError.notConnected
        }
        xpc_connection_set_event_handler(opened) { [weak self] event in
            guard xpc_get_type(event) == XPC_TYPE_ERROR else { return }
            Log.helper.error("The helper's connection ended")
            self?.forget(opened)
        }
        xpc_connection_activate(opened)
        connection = opened
        return opened
    }

    /// Drops a connection that ended, so the next request opens a new one.
    private func forget(_ ended: xpc_connection_t) {
        lock.lock()
        if connection === ended { connection = nil }
        lock.unlock()
    }
}

/// Whether the helper is registered with the system, and the steps to change that.
@MainActor
@Observable
final class HelperManager {
    enum Status: Equatable {
        /// The build has no team signature, so no helper can trust it.
        case unsignedBuild
        case notInstalled
        /// Registered, but waiting for approval in System Settings > General > Login Items.
        case needsApproval
        case enabled
        case failed(String)

        var allowsControl: Bool { self == .enabled }
    }

    /// The launchd property list inside the app, at Contents/Library/LaunchDaemons.
    nonisolated static let daemonPlistName = "com.kevster.airflow.helper.plist"

    private(set) var status: Status = .notInstalled {
        didSet {
            if status == .enabled, oldValue != .enabled, hasReadStatus { enabledAt = Date() }
            hasReadStatus = true
        }
    }
    /// When the helper came on during this session. A helper that was already on has no date.
    private(set) var enabledAt: Date?
    @ObservationIgnored private var hasReadStatus = false
    @ObservationIgnored private let service = SMAppService.daemon(plistName: HelperManager.daemonPlistName)
    @ObservationIgnored private let isSigned: Bool
    @ObservationIgnored private let fixedStatus: Status?

    init(isSigned: Bool = Backend.helperRequirement != nil) {
        self.isSigned = isSigned
        fixedStatus = nil
        refresh()
        hasReadStatus = true
    }

    /// A manager that reports one status and never touches the system, for tests.
    init(fixedStatus: Status, enabledAt: Date? = nil) {
        isSigned = false
        self.fixedStatus = fixedStatus
        status = fixedStatus
        hasReadStatus = true
        self.enabledAt = enabledAt
    }

    /// True for a short time after the helper comes on, while the app says so.
    func justEnabled(now: Date = Date()) -> Bool {
        guard let enabledAt else { return false }
        return now.timeIntervalSince(enabledAt) < Self.announcementSeconds
    }

    static let announcementSeconds: TimeInterval = 8

    func refresh() {
        if let fixedStatus {
            status = fixedStatus
            return
        }
        guard isSigned else {
            status = .unsignedBuild
            return
        }
        switch service.status {
        case .enabled: status = .enabled
        case .requiresApproval: status = .needsApproval
        case .notRegistered, .notFound: status = .notInstalled
        @unknown default: status = .notInstalled
        }
    }

    func install() {
        guard fixedStatus == nil else { return }
        guard isSigned else {
            status = .unsignedBuild
            return
        }
        do {
            try service.register()
            refresh()
        } catch {
            refresh()
            if status == .notInstalled {
                status = .failed(error.localizedDescription)
            }
        }
    }

    func remove() async {
        guard fixedStatus == nil else { return }
        do {
            try await service.unregister()
            refresh()
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
