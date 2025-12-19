import Foundation
import SwiftData

@Observable
final class ComposerManager {
    var availableVersion: ComposerMetadata?
    var isLoading = false
    var isUpdating = false
    var updateProgress: Double = 0.0
    var errorMessage: String?

    private let metadataURL = URL(string: "https://binaries.fadogen.app/metadata-composer.json")!
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func initialize() async {
        await ensureBundledVersion()
        await refresh()
        try? await syncInstalledVersion()
    }

    /// Ensures bundled Composer binary is installed if no version exists
    /// Called on app launch to guarantee a working Composer installation
    func ensureBundledVersion() async {
        do {
            // Check if Composer is already installed
            if ComposerFileSystemService.isInstalled() {
                return
            }

            // Check if bundled version exists
            guard ComposerFileSystemService.detectBundledBinary() else {
                errorMessage = "Composer binary not available"
                return
            }

            // Copy bundled binary
            let binaryURL = try ComposerFileSystemService.copyBundledBinary()

            // Extract version
            let version = try await ComposerFileSystemService.extractVersion(from: binaryURL)

            // Save to SwiftData
            let composerVersion = ComposerVersion(version: version)
            modelContext.insert(composerVersion)
            try modelContext.save()

        } catch {
            errorMessage = "Failed to install Composer"
        }
    }

    /// Synchronizes installed Composer version from filesystem with SwiftData
    func syncInstalledVersion() async throws {
        let binaryURL = FadogenPaths.binDirectory.appendingPathComponent("composer.phar")

        // Check if binary exists
        guard ComposerFileSystemService.isInstalled() else {
            // No binary - check if we have a model and delete it (orphaned)
            let descriptor = FetchDescriptor<ComposerVersion>()
            if let orphanedModel = try modelContext.fetch(descriptor).first {
                modelContext.delete(orphanedModel)
                try modelContext.save()
            }
            return
        }

        // Validate binary integrity
        guard await ComposerFileSystemService.validateBinaryIntegrity(url: binaryURL) else {
            // Try to recover from bundled
            if ComposerFileSystemService.detectBundledBinary() {
                let recoveredURL = try ComposerFileSystemService.copyBundledBinary()
                let version = try await ComposerFileSystemService.extractVersion(from: recoveredURL)

                // Update or create model
                let descriptor = FetchDescriptor<ComposerVersion>()
                if let existing = try modelContext.fetch(descriptor).first {
                    existing.version = version
                } else {
                    let composerVersion = ComposerVersion(version: version)
                    modelContext.insert(composerVersion)
                }
                try modelContext.save()
                return
            }

            // Cannot recover - delete binary and model
            try ComposerFileSystemService.deleteBinary()
            let descriptor = FetchDescriptor<ComposerVersion>()
            if let existing = try modelContext.fetch(descriptor).first {
                modelContext.delete(existing)
                try modelContext.save()
            }
            throw ComposerManagerError.corruptedBinary
        }

        // Binary is valid - ensure SwiftData model exists and is up-to-date
        let version = try await ComposerFileSystemService.extractVersion(from: binaryURL)

        let descriptor = FetchDescriptor<ComposerVersion>()
        if let existing = try modelContext.fetch(descriptor).first {
            // Update version if changed
            if existing.version != version {
                existing.version = version
            }
        } else {
            // Create new model
            let composerVersion = ComposerVersion(version: version)
            modelContext.insert(composerVersion)
        }

        try modelContext.save()
    }

    /// Updates Composer to the latest available version
    /// Downloads new binary, replaces old one, and updates SwiftData
    func update() async throws {
        guard !isUpdating else {
            throw ComposerManagerError.updateInProgress
        }

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

            // Step 1: Refresh metadata to get latest version info
            await refresh()

            // Step 2: Validate metadata exists
            guard let metadata = availableVersion else {
                throw ComposerManagerError.noUpdateAvailable
            }

            wrappedProgress(0.10)

            // Step 3: Fetch existing version from SwiftData
            let descriptor = FetchDescriptor<ComposerVersion>()
            let existingVersion = try modelContext.fetch(descriptor).first

            wrappedProgress(0.15)

            // Step 4: Check if update is needed
            if let existing = existingVersion, existing.version == metadata.latest {
                throw ComposerManagerError.noUpdateAvailable
            }

            wrappedProgress(0.20)

            // Step 5: Download with progress (20% → 60%)
            let archiveURL = try await ComposerDownloadService.download(
                metadata: metadata,
                progressHandler: { downloadProgress in
                    let mappedProgress = 0.20 + (downloadProgress * 0.40)
                    wrappedProgress(mappedProgress)
                }
            )

            wrappedProgress(0.60)

            // Step 6: Delete old binary (required for update)
            try ComposerFileSystemService.deleteBinary()

            // Step 7: Extract and install new binary (60% → 90%)
            try await ComposerDownloadService.extractAndInstall(archiveURL: archiveURL)

            wrappedProgress(0.90)

            // Step 8: Verify new version
            let binaryPath = FadogenPaths.binDirectory.appendingPathComponent("composer.phar")
            let newVersion = try await ComposerFileSystemService.extractVersion(from: binaryPath)

            // Step 9: Update SwiftData model
            if let existing = existingVersion {
                existing.version = newVersion
            } else {
                let composerVersion = ComposerVersion(version: newVersion)
                modelContext.insert(composerVersion)
            }
            try modelContext.save()

            wrappedProgress(1.0)

        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    /// Refresh metadata from remote server
    func refresh() async {
        guard !isLoading else {
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            // Create URLSession without cache to always get fresh metadata
            let session = DownloadUtilities.createNoCacheSession()

            let (data, response) = try await session.data(from: self.metadataURL)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw ComposerManagerError.invalidResponse
            }

            guard httpResponse.statusCode == 200 else {
                throw ComposerManagerError.invalidResponse
            }

            let decoder = JSONDecoder()
            self.availableVersion = try decoder.decode(ComposerMetadata.self, from: data)
        } catch {
            self.errorMessage = "Unable to check for updates"
        }

        self.isLoading = false
    }

    /// Get the currently installed Composer version from SwiftData
    /// - Returns: ComposerVersion if installed, nil otherwise
    func getInstalledVersion() -> ComposerVersion? {
        let descriptor = FetchDescriptor<ComposerVersion>()
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
}

// MARK: - Errors

enum ComposerManagerError: LocalizedError {
    case invalidResponse
    case updateInProgress
    case noUpdateAvailable
    case corruptedBinary

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from metadata server"
        case .updateInProgress:
            return "An update is already in progress"
        case .noUpdateAvailable:
            return "Already using the latest version"
        case .corruptedBinary:
            return "Composer binary is corrupted and cannot be recovered"
        }
    }
}
