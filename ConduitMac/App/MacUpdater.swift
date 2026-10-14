import Combine
import Sparkle

/// Sparkle updates (D12): hourly check against the GitHub Releases feed,
/// prompt before installing. Not started under XCTest (the test host is the app).
@MainActor
final class MacUpdater: ObservableObject {
    static let shared = MacUpdater()

    let started: Bool
    @Published private(set) var canCheckForUpdates = false

    private let controller: SPUStandardUpdaterController
    private var observation: NSKeyValueObservation?

    init(startingUpdater: Bool = !MacDefaults.isRunningUnderXCTest) {
        started = startingUpdater
        controller = SPUStandardUpdaterController(
            startingUpdater: startingUpdater, updaterDelegate: nil, userDriverDelegate: nil
        )
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let value = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheckForUpdates = value }
        }
    }

    func checkForUpdates() { controller.checkForUpdates(nil) }
}
