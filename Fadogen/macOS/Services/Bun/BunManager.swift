import Foundation
import SwiftData
import OSLog

@Observable
final class BunManager {
    var availableVersion: BunMetadata?
    var isLoading = false
    var isUpdating = false
    var updateProgress: Double = 0.0
    var errorMessage: String?

    private let logger = Logger(subsystem: "app.fadogen.Fadogen", category: "bun")
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func initialize() async {
        logger.info("Bun is optional and not installed by default")

        await refresh()

        do {
            try await syncInstalledVersion()
        } catch {
            logger.error("Failed to sync installed Bun version: \(error.localizedDescription)")
        }
    }

    /// Synchronizes installed Bun version from filesystem with SwiftData
    func syncInstalledVersion() async throws {
        let binaryURL = FadogenPaths.binDirectory.appendingPathComponent("bun")

        // Check if binary exists
        guard BunFileSystemService.isInstalled() else {
            // No binary - check if we have a model and delete it (orphaned)
            let descriptor = FetchDescriptor<BunVersion>()
            if let orphanedModel = try modelContext.fetch(descriptor).first {
                logger.warning("Found orphaned Bun model without binary, removing")
                modelContext.delete(orphanedModel)
                try modelContext.save()
            }
            return
        }

        // Validate binary integrity
        guard await BunFileSystemService.validateBinaryIntegrity(url: binaryURL) else {
            logger.warning("Bun binary failed integrity check, attempting recovery")

            // Try to recover from bundled
            if BunFileSystemService.detectBundledBinary() {
                let recoveredURL = try BunFileSystemService.copyBundledBinary()
                let version = try await BunFileSystemService.extractVersion(from: recoveredURL)

                // Update or create model
                let descriptor = FetchDescriptor<BunVersion>()
                if let existing = try modelContext.fetch(descriptor).first {
                    existing.version = version
                } else {
                    let bunVersion = BunVersion(version: version)
                    modelContext.insert(bunVersion)
                }
                try modelContext.save()
                logger.info("Successfully recovered Bun from bundled binary")
                return
            }

            // Cannot recover - delete binary and model
            try BunFileSystemService.deleteBinary()
            let descriptor = FetchDescriptor<BunVersion>()
            if let existing = try modelContext.fetch(descriptor).first {
                modelContext.delete(existing)
                try modelContext.save()
            }
            throw BunManagerError.corruptedBinary
        }

        // Binary is valid - ensure SwiftData model exists and is up-to-date
        let version = try await BunFileSystemService.extractVersion(from: binaryURL)

        // Ensure bunx symlink exists
        try? createBunxSymlink()

        let descriptor = FetchDescriptor<BunVersion>()
        if let existing = try modelContext.fetch(descriptor).first {
            // Update version if changed
            if existing.version != version {
                existing.version = version
                logger.info("Updated Bun version to \(version)")
            }
        } else {
            // Create new model
            let bunVersion = BunVersion(version: version)
            modelContext.insert(bunVersion)
            logger.info("Detected Bun installation: \(version)")
        }

        try modelContext.save()

    }

    /// Installs Bun from GitHub releases (first-time installation)
    /// Downloads binary, installs it, and creates SwiftData model
    func install() async throws {
        guard !isUpdating else {
            throw BunManagerError.installInProgress
        }

        logger.info("Starting Bun installation")

        isUpdating = true
        updateProgress = 0.0
        errorMessage = nil

        defer {
            isUpdating = false
            updateProgress = 0.0
        }

        // Wrap progress to update centralized state
        let wrappedProgress: @Sendable (Double) -> Void = { [weak self] p in
            Task { @MainActor in
                self?.updateProgress = p
            }
        }

        do {
            wrappedProgress(0.05)

            // Step 1: Check if already installed
            if BunFileSystemService.isInstalled() {
                throw BunManagerError.alreadyInstalled
            }

            wrappedProgress(0.10)

            // Step 2: Validate metadata exists
            guard let metadata = availableVersion else {
                throw BunManagerError.noVersionAvailable
            }

            wrappedProgress(0.15)

            // Step 3: Download with progress (15% → 60%)
            let archiveURL = try await BunDownloadService.download(
                metadata: metadata,
                progressHandler: { downloadProgress in
                    let mappedProgress = 0.15 + (downloadProgress * 0.45)
                    wrappedProgress(mappedProgress)
                }
            )

            wrappedProgress(0.60)

            // Step 4: Extract and install binary (60% → 90%)
            try await BunDownloadService.extractAndInstall(archiveURL: archiveURL)

            wrappedProgress(0.90)

            // Step 5: Verify version
            let binaryPath = FadogenPaths.binDirectory.appendingPathComponent("bun")
            let version = try await BunFileSystemService.extractVersion(from: binaryPath)

            // Step 6: Create bunx symlink
            try createBunxSymlink()

            // Step 7: Create SwiftData model
            let bunVersion = BunVersion(version: version)
            modelContext.insert(bunVersion)
            try modelContext.save()

            wrappedProgress(0.95)

            logger.info("Successfully installed Bun \(version)")
            wrappedProgress(1.0)

        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    /// Updates Bun to the latest available version
    /// Downloads new binary, replaces old one, and updates SwiftData
    func update() async throws {
        guard !isUpdating else {
            throw BunManagerError.updateInProgress
        }

        logger.info("Starting Bun update")

        isUpdating = true
        updateProgress = 0.0
        errorMessage = nil

        defer {
            isUpdating = false
            updateProgress = 0.0
        }

        // Wrap progress to update centralized state
        let wrappedProgress: @Sendable (Double) -> Void = { [weak self] p in
            Task { @MainActor in
                self?.updateProgress = p
            }
        }

        do {
            wrappedProgress(0.05)

            // Step 1: Validate metadata exists
            guard let metadata = availableVersion else {
                throw BunManagerError.noUpdateAvailable
            }

            wrappedProgress(0.10)

            // Step 2: Fetch existing version from SwiftData
            let descriptor = FetchDescriptor<BunVersion>()
            let existingVersion = try modelContext.fetch(descriptor).first

            wrappedProgress(0.15)

            // Step 3: Check if update is needed
            if let existing = existingVersion, existing.version == metadata.latest {
                throw BunManagerError.noUpdateAvailable
            }

            wrappedProgress(0.20)

            // Step 4: Download with progress (20% → 60%)
            let archiveURL = try await BunDownloadService.download(
                metadata: metadata,
                progressHandler: { downloadProgress in
                    let mappedProgress = 0.20 + (downloadProgress * 0.40)
                    wrappedProgress(mappedProgress)
                }
            )

            wrappedProgress(0.60)

            // Step 5: Delete old binary (required for update)
            try BunFileSystemService.deleteBinary()

            // Step 6: Extract and install new binary (60% → 90%)
            try await BunDownloadService.extractAndInstall(archiveURL: archiveURL)

            wrappedProgress(0.90)

            // Step 7: Verify new version
            let binaryPath = FadogenPaths.binDirectory.appendingPathComponent("bun")
            let newVersion = try await BunFileSystemService.extractVersion(from: binaryPath)

            // Step 8: Update SwiftData model
            if let existing = existingVersion {
                existing.version = newVersion
            } else {
                let bunVersion = BunVersion(version: newVersion)
                modelContext.insert(bunVersion)
            }
            try modelContext.save()

            wrappedProgress(0.95)

            logger.info("Successfully updated Bun to \(newVersion)")
            wrappedProgress(1.0)

        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    /// Refresh metadata from GitHub releases
    func refresh() async {
        guard !isLoading else {
            logger.warning("Refresh already in progress, ignoring request")
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            availableVersion = try await BunMetadataService.fetchLatestVersion()
            logger.info("Fetched Bun metadata: \(self.availableVersion?.latest ?? "unknown")")
        } catch {
            logger.error("Failed to fetch Bun metadata: \(error.localizedDescription)")
            errorMessage = "Unable to check for updates"
        }

        isLoading = false
    }

    /// Get the currently installed Bun version from SwiftData
    /// - Returns: BunVersion if installed, nil otherwise
    func getInstalledVersion() -> BunVersion? {
        let descriptor = FetchDescriptor<BunVersion>()
        return try? modelContext.fetch(descriptor).first
    }

    /// Checks if an update is available
    /// - Returns: `true` if a newer version is available, `false` otherwise
    func isUpdateAvailable() -> Bool {
        guard let installed = getInstalledVersion(),
              let available = availableVersion else {
            return false
        }

        return available.latest != installed.version
    }

    /// Removes Bun completely (binary + SwiftData model)
    /// Called when user wants to uninstall Bun
    func remove() async throws {
        guard !isUpdating else {
            throw BunManagerError.updateInProgress
        }

        logger.info("Starting Bun removal")

        isUpdating = true  // Reuse the same flag for operation lock
        updateProgress = 0.0
        errorMessage = nil

        defer {
            isUpdating = false
            updateProgress = 0.0
        }

        do {
            updateProgress = 0.1

            // Step 1: Check if Bun is installed
            guard BunFileSystemService.isInstalled() else {
                throw BunManagerError.notInstalled
            }

            updateProgress = 0.3

            // Step 2: Delete binary from filesystem
            try BunFileSystemService.deleteBinary()

            // Step 3: Delete bunx symlink (works for both valid and broken symlinks)
            let bunxURL = FadogenPaths.binDirectory.appendingPathComponent("bunx")
            FileSystemUtilities.removeSymlink(at: bunxURL, logger: logger, itemName: "bunx symlink")

            updateProgress = 0.6

            // Step 4: Delete SwiftData model
            let descriptor = FetchDescriptor<BunVersion>()
            let installedVersions = try modelContext.fetch(descriptor)

            for version in installedVersions {
                modelContext.delete(version)
            }
            try modelContext.save()

            updateProgress = 0.9

            logger.info("Successfully removed Bun")
            updateProgress = 1.0

        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    // MARK: - Private

    private func createBunxSymlink() throws {
        let bunxURL = FadogenPaths.binDirectory.appendingPathComponent("bunx")

        // Remove existing symlink if present
        if FileManager.default.fileExists(atPath: bunxURL.path) {
            try FileManager.default.removeItem(at: bunxURL)
        }

        // Create symlink (relative path for portability)
        try FileManager.default.createSymbolicLink(
            atPath: bunxURL.path,
            withDestinationPath: "bun"
        )

        logger.info("Created symlink bunx -> bun")
    }
}

// MARK: - Errors

enum BunManagerError: LocalizedError {
    case installInProgress
    case updateInProgress
    case alreadyInstalled
    case notInstalled
    case noVersionAvailable
    case noUpdateAvailable
    case corruptedBinary

    var errorDescription: String? {
        switch self {
        case .installInProgress:
            return "An installation is already in progress"
        case .updateInProgress:
            return "An update is already in progress"
        case .alreadyInstalled:
            return "Bun is already installed. Use update() to update to the latest version."
        case .notInstalled:
            return "Bun is not installed"
        case .noVersionAvailable:
            return "No Bun version available for installation. Try refreshing metadata first."
        case .noUpdateAvailable:
            return "Already using the latest version"
        case .corruptedBinary:
            return "Bun binary is corrupted and cannot be recovered"
        }
    }
}
