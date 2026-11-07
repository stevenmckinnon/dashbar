import SwiftUI
import Sparkle

/// In-app updates through Sparkle. The feed URL and public signing key live in Info.plist (build.sh writes them),
/// so the updater only starts for a built Dashbar.app, never for tests, snapshots or the bare dev binary.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    @Published private(set) var canCheck = false
    let isAvailable: Bool
    private var controller: SPUStandardUpdaterController?

    private init() {
        let info = Bundle.main.infoDictionary ?? [:]
        isAvailable = Bundle.main.bundleURL.pathExtension == "app"
            && info["SUFeedURL"] != nil && info["SUPublicEDKey"] != nil
            && !CommandLine.arguments.contains("--snapshot") && !CommandLine.arguments.contains("--bench")
        guard isAvailable else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
    }

    func checkForUpdates() { controller?.checkForUpdates(nil) }
}
