import Foundation
import OSLog
import SwiftData

/// Watches PHP extension directories for changes and auto-restarts PHP-FPM
/// when extensions are added or removed via `fadogen php:ext`.
final class PHPExtensionWatcher {
    private let modelContext: ModelContext
    private weak var phpFPM: PHPFPMService?
    private let logger = Logger(subsystem: "app.fadogen.Fadogen", category: "php-extension-watcher")

    // Active monitors: version -> DispatchSource
    private var activeMonitors: [String: DispatchSourceFileSystemObject] = [:]

    // Debounce timers to avoid multiple restarts for rapid changes
    private var debounceTimers: [String: DispatchWorkItem] = [:]
    private let debounceDelay: TimeInterval = 1.0

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func setPHPFPM(_ phpFPM: PHPFPMService) {
        self.phpFPM = phpFPM
    }

    /// Start watching extension directories for all installed PHP versions
    func startWatching() {
        let descriptor = FetchDescriptor<PHPVersion>()
        guard let versions = try? modelContext.fetch(descriptor) else {
            logger.error("Failed to fetch PHP versions for extension watching")
            return
        }

        for version in versions {
            startWatching(major: version.major)
        }

        logger.info("Started watching extension directories for \(versions.count) PHP version(s)")
    }

    /// Start watching extension directory for a specific PHP version
    func startWatching(major: String) {
        let extensionsDir = FadogenPaths.configPath(for: major)
            .appendingPathComponent("extensions")

        // Create the directory if it doesn't exist
        try? FileManager.default.createDirectory(
            at: extensionsDir,
            withIntermediateDirectories: true
        )

        // Open file descriptor
        let fileDescriptor = open(extensionsDir.path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            logger.warning("Failed to open extension directory for PHP \(major): \(extensionsDir.path)")
            return
        }

        // Create dispatch source for file system monitoring
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .delete, .rename],
            queue: DispatchQueue.main
        )

        source.setEventHandler { [weak self] in
            self?.handleExtensionChange(major: major)
        }

        source.setCancelHandler {
            close(fileDescriptor)
        }

        source.resume()
        activeMonitors[major] = source

        logger.debug("Watching extensions directory for PHP \(major)")
    }

    /// Stop watching extension directory for a specific PHP version
    func stopWatching(major: String) {
        guard let source = activeMonitors[major] else { return }

        source.cancel()
        activeMonitors.removeValue(forKey: major)
        debounceTimers[major]?.cancel()
        debounceTimers.removeValue(forKey: major)

        logger.debug("Stopped watching extensions for PHP \(major)")
    }

    /// Stop all watching
    func shutdown() {
        for major in activeMonitors.keys {
            stopWatching(major: major)
        }
        logger.info("Extension watcher shutdown complete")
    }

    /// Handle extension directory changes with debouncing
    private func handleExtensionChange(major: String) {
        // Cancel previous debounce timer
        debounceTimers[major]?.cancel()

        // Create new debounced restart
        let workItem = DispatchWorkItem { [weak self] in
            self?.restartPHPFPM(major: major)
        }

        debounceTimers[major] = workItem

        // Schedule debounced restart
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceDelay, execute: workItem)
    }

    /// Restart PHP-FPM for a specific version
    private func restartPHPFPM(major: String) {
        guard let phpFPM = phpFPM else {
            logger.warning("PHPFPMService not available for restart")
            return
        }

        logger.info("Extension change detected, restarting PHP-FPM \(major)")
        phpFPM.restart(major: major)
    }
}
