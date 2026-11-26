import Combine
import Observation
import Sparkle

/// Looks for a newer AirFlow and installs it, through Sparkle. Sparkle reads the appcast's address
/// (SUFeedURL) and the key that every update must be signed with (SUPublicEDKey) from Info.plist.
/// It schedules its own checks.
@MainActor
@Observable
final class Updates {
    static let shared = Updates()

    /// False while a check is under way, and in a copy that does not update itself.
    private(set) var canCheck = false

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: AnyCancellable?

    /// True in a copy that updates itself. A Debug build has its own bundle identifier and would be
    /// offered the release in place of itself. A test must not reach the network.
    var isAvailable: Bool { controller != nil }

    var checksAutomatically: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    func start() {
        #if !DEBUG
        guard controller == nil, !AppModel.isRunningTests else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        observation = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] canCheck in
                MainActor.assumeIsolated { self?.canCheck = canCheck }
            }
        #endif
    }

    func check() {
        controller?.checkForUpdates(nil)
    }
}
