import Foundation
import AppKit

@Observable
final class IDEService {
    private(set) var installedIDEs: [IDE] = []
    private var detectionCache: [IDE: Bool] = [:]

    init() {
        detectInstalledIDEs()
    }

    /// Detect all installed IDEs
    func detectInstalledIDEs() {
        installedIDEs = IDE.allCases.filter { isInstalled($0) }
    }

    /// Check if a specific IDE is installed
    func isInstalled(_ ide: IDE) -> Bool {
        if let cached = detectionCache[ide] {
            return cached
        }

        let isInstalled = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: ide.bundleIdentifier
        ) != nil

        detectionCache[ide] = isInstalled
        return isInstalled
    }

    /// Open a folder in the specified IDE
    func open(path: String, in ide: IDE) {
        let folderURL = URL(fileURLWithPath: path, isDirectory: true)

        guard let appURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: ide.bundleIdentifier
        ) else { return }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.promptsUserIfNeeded = false

        NSWorkspace.shared.open(
            [folderURL],
            withApplicationAt: appURL,
            configuration: configuration
        )
    }

    /// Invalidate cache and re-detect installed IDEs
    func refreshDetection() {
        detectionCache.removeAll()
        detectInstalledIDEs()
    }
}
