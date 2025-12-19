import Foundation
import Sparkle

/// Delegate for Sparkle updater to handle beta channel opt-in
final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {

    /// UserDefaults key for beta updates preference
    static let checkForBetaUpdatesKey = "checkForBetaUpdates"

    /// Whether the user has opted in to receive beta updates
    var checkForBetaUpdates: Bool {
        get { UserDefaults.standard.bool(forKey: Self.checkForBetaUpdatesKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.checkForBetaUpdatesKey) }
    }

    /// Returns the set of allowed update channels
    /// - Returns: Set containing "beta" if user opted in, empty otherwise
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        checkForBetaUpdates ? Set(["beta"]) : Set()
    }
}
