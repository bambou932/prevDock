import Foundation
import Sparkle

final class UpdateController: NSObject {
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    var currentVersionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }

    var automaticallyChecksForUpdates: Bool {
        get {
            updaterController.updater.automaticallyChecksForUpdates
        }
        set {
            updaterController.updater.automaticallyChecksForUpdates = newValue
        }
    }

    var automaticallyInstallsUpdates: Bool {
        get {
            updaterController.updater.automaticallyChecksForUpdates &&
                updaterController.updater.automaticallyDownloadsUpdates
        }
        set {
            if newValue {
                updaterController.updater.automaticallyChecksForUpdates = true
                guard updaterController.updater.allowsAutomaticUpdates else { return }
                updaterController.updater.automaticallyDownloadsUpdates = true
                return
            }

            if updaterController.updater.allowsAutomaticUpdates {
                updaterController.updater.automaticallyDownloadsUpdates = false
            }
            updaterController.updater.automaticallyChecksForUpdates = false
        }
    }

    var canCheckForUpdates: Bool {
        updaterController.updater.canCheckForUpdates
    }

    @objc func checkForUpdates(_ sender: Any?) {
        enableAutomaticInstallForThisCheck()
        updaterController.checkForUpdates(sender)
    }

    private func enableAutomaticInstallForThisCheck() {
        guard updaterController.updater.allowsAutomaticUpdates else { return }
        updaterController.updater.automaticallyDownloadsUpdates = true
    }
}
