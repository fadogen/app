import Foundation
import SwiftData
import OSLog

@Observable
final class NodeManager {
    var availableVersions: NodeMetadataCollection = [:]
    var isLoading = false
    var errorMessage: String?

    // Operation state (persists across view navigations)
    var installingVersions: Set<String> = []
    var removingVersions: Set<String> = []
    var updatingVersions: Set<String> = []
    var operationProgress: [String: Double] = [:]
    var operationErrors: [String: String] = [:]

    private let logger = Logger(subsystem: "app.fadogen.Fadogen", category: "node")
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    var isAnyOperationActive: Bool {
        !installingVersions.isEmpty ||
        !removingVersions.isEmpty ||
        !updatingVersions.isEmpty
    }

    func isOperationActive(for major: String) -> Bool {
        installingVersions.contains(major) ||
        removingVersions.contains(major) ||
        updatingVersions.contains(major)
    }

    /// Initialize Node.js manager and fetch available versions
    func initialize() async {
        // Migrate old node-versions directory if needed (backward compatibility)
        do {
            try NodeFileSystemService.migrateNodeVersionsDirectory()
        } catch {
            logger.warning("Migration failed: \(error.localizedDescription)")
        }

        // Ensure at least the bundled version is installed
        await ensureBundledVersion()

        // Fetch metadata first
        await refresh()

        // Synchronize installed versions with SwiftData
        do {
            try await syncInstalledVersions()

            // Update shell integration after sync
            try await updateShellIntegration()
        } catch {
            logger.error("Failed to sync installed versions: \(error.localizedDescription)")
        }
    }

    /// Ensures at least the bundled Node.js version is installed
    /// Called on app launch to guarantee a working Node.js installation
    func ensureBundledVersion() async {
        do {
            // Check if any versions are already installed
            let installedBinaries = try await NodeFileSystemService.scanInstalledBinaries()

            if !installedBinaries.isEmpty {
                logger.info("Found \(installedBinaries.count) installed Node.js version(s), skipping bundled setup")
                return
            }

            // No versions installed - copy bundled version
            guard let bundledMajor = await NodeFileSystemService.detectBundledVersion() else {
                logger.error("No bundled Node.js version found and no versions installed")
                fatalError("No Node.js version available")
            }

            logger.info("No Node.js versions installed, copying bundled version \(bundledMajor)")

            // Copy bundled installation
            let binaryURL = try NodeFileSystemService.copyBundledInstallation(major: bundledMajor)

            // Extract full version
            let fullVersion = try await NodeFileSystemService.extractVersion(from: binaryURL)

            // Create symlinks (this is the first/default version)
            try NodeFileSystemService.updateSymlinks(to: bundledMajor)

            // Install Node.js wrappers (first version)
            try FadogenShellService.installNodeWrappers()

            // Save to SwiftData
            let nodeVersion = NodeVersion(
                major: bundledMajor,
                minor: fullVersion,
                isDefault: true
            )
            modelContext.insert(nodeVersion)
            try modelContext.save()

            logger.info("Successfully installed bundled Node.js \(fullVersion) as default version")

        } catch {
            logger.error("Failed to ensure bundled version: \(error.localizedDescription)")
            fatalError("Failed to install bundled Node.js version: \(error)")
        }
    }

    /// Synchronizes installed Node.js versions from filesystem with SwiftData
    /// Performs complete bidirectional reconciliation with integrity validation and recovery
    func syncInstalledVersions() async throws {
        // Step 1: Scan filesystem for installed binaries and detect default
        let installedBinaries = try await NodeFileSystemService.scanInstalledBinaries()
        let defaultVersion = try NodeFileSystemService.detectDefaultVersion()

        // Step 2: Forward reconciliation with integrity validation
        var validBinaries: [String: URL] = [:]

        for (major, binaryURL) in installedBinaries {
            // Validate binary integrity
            guard await NodeFileSystemService.validateBinaryIntegrity(url: binaryURL) else {
                logger.warning("Binary \(major) failed integrity check, removing and will attempt recovery")
                try NodeFileSystemService.deleteInstallation(major: major)
                continue
            }

            // Track as valid
            validBinaries[major] = binaryURL

            // Check if NodeVersion already exists
            let descriptor = FetchDescriptor<NodeVersion>(
                predicate: #Predicate { $0.major == major }
            )
            let existing = try modelContext.fetch(descriptor).first

            if let existing {
                // Update minor version if changed
                let fullVersion = try await NodeFileSystemService.extractVersion(from: binaryURL)
                if existing.minor != fullVersion {
                    existing.minor = fullVersion
                    logger.info("Updated Node.js \(major) version to \(fullVersion)")
                }

                // Update isDefault based on symlink
                existing.isDefault = (major == defaultVersion)
            } else {
                // Create new NodeVersion
                let fullVersion = try await NodeFileSystemService.extractVersion(from: binaryURL)
                let nodeVersion = NodeVersion(
                    major: major,
                    minor: fullVersion,
                    isDefault: major == defaultVersion
                )
                modelContext.insert(nodeVersion)
                logger.info("Detected new Node.js \(major) installation: \(fullVersion)")
            }
        }

        // Step 3: Backward reconciliation (orphaned models + corrupted binaries)
        let currentModels = try modelContext.fetch(FetchDescriptor<NodeVersion>())
        try await reconcileOrphanedModels(installedBinaries: validBinaries, allModels: currentModels)

        // Step 4: Enforce default constraint
        let finalModels = try modelContext.fetch(FetchDescriptor<NodeVersion>())
        try enforceDefaultConstraint(allModels: finalModels)

        // Step 5: Save all changes
        try modelContext.save()

        // Step 6: Synchronize Node.js wrappers with installation state
        let wrapperExists = FileManager.default.fileExists(
            atPath: FadogenPaths.binDirectory.appendingPathComponent("node").path
        )
        let hasVersions = !finalModels.isEmpty

        if hasVersions && !wrapperExists {
            // Have versions but no wrappers - install them
            try FadogenShellService.installNodeWrappers()
            logger.info("Installed Node.js wrappers during reconciliation")
        } else if !hasVersions && wrapperExists {
            // No versions but wrappers exist - remove them
            try FadogenShellService.removeNodeWrappers()
            logger.info("Removed Node.js wrappers during reconciliation (no versions installed)")
        }

        logger.info("Full reconciliation completed: \(finalModels.count) Node.js version(s) synchronized")
    }

    /// Reconciles orphaned SwiftData models (models without filesystem binaries)
    /// Attempts recovery by downloading from metadata
    private func reconcileOrphanedModels(
        installedBinaries: [String: URL],
        allModels: [NodeVersion]
    ) async throws {
        for model in allModels {
            // Skip if binary exists on filesystem
            guard installedBinaries[model.major] == nil else { continue }

            logger.warning("Detected orphaned model for Node.js \(model.major) - binary missing from filesystem")

            // Attempt recovery: Try downloading from metadata
            if let metadata = availableVersions[model.major] {
                logger.info("Recovering Node.js \(model.major) by downloading from server")

                do {
                    // Download silently
                    let archiveURL = try await NodeDownloadService.download(
                        major: model.major,
                        metadata: metadata,
                        progressHandler: { _ in }
                    )

                    // Extract and install
                    try await NodeDownloadService.extractAndInstall(
                        archiveURL: archiveURL,
                        major: model.major
                    )

                    // Extract version and update model
                    let binaryURL = FadogenPaths.nodeBinaryPath(for: model.major)
                    let fullVersion = try await NodeFileSystemService.extractVersion(from: binaryURL)
                    model.minor = fullVersion

                    // Update symlink if this was the default version
                    if model.isDefault {
                        try NodeFileSystemService.updateSymlinks(to: model.major)
                    }

                    logger.info("Successfully recovered Node.js \(model.major) by downloading")
                    continue
                } catch {
                    logger.error("Failed to download and recover: \(error.localizedDescription)")
                }
            }

            // Cannot recover - delete orphaned model
            logger.warning("Cannot recover Node.js \(model.major), deleting orphaned model from SwiftData")
            modelContext.delete(model)
        }
    }

    /// Enforces the constraint that exactly one Node.js version must be marked as default
    private func enforceDefaultConstraint(allModels: [NodeVersion]) throws {
        let defaultVersions = allModels.filter { $0.isDefault }

        if defaultVersions.count == 0 {
            // No default version - set first version as default
            guard let firstVersion = allModels.first else {
                // No versions at all - this is okay for Node.js (optional)
                return
            }

            logger.warning("No default Node.js version found, setting \(firstVersion.major) as default")
            firstVersion.isDefault = true

            // Update symlink to match
            do {
                try NodeFileSystemService.updateSymlinks(to: firstVersion.major)
            } catch {
                logger.error("Failed to update symlinks: \(error.localizedDescription)")
            }

        } else if defaultVersions.count > 1 {
            // Multiple defaults - reconcile to symlink truth
            logger.warning("Found \(defaultVersions.count) default versions, reconciling to symlink")

            let symlinkDefault = try NodeFileSystemService.detectDefaultVersion()

            for version in allModels {
                version.isDefault = (version.major == symlinkDefault)
            }

            if let actual = symlinkDefault {
                logger.info("Reconciled to symlink default: Node.js \(actual)")
            } else if let firstVersion = allModels.first {
                firstVersion.isDefault = true
                try NodeFileSystemService.updateSymlinks(to: firstVersion.major)
                logger.info("No symlink found, created default: Node.js \(firstVersion.major)")
            }
        }
    }

    /// Installs a new Node.js version with progress tracking
    func install(major: String, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        guard !isAnyOperationActive else {
            throw NodeInstallError.anotherOperationInProgress
        }

        logger.info("Starting installation of Node.js \(major)")

        installingVersions.insert(major)
        operationProgress[major] = 0.0
        operationErrors[major] = nil

        defer {
            installingVersions.remove(major)
            operationProgress[major] = nil
        }

        let wrappedProgress: @Sendable (Double) -> Void = { [weak self] p in
            Task { @MainActor in
                self?.operationProgress[major] = p
            }
            progress(p)
        }

        do {
            // Step 1: Validate metadata exists
            guard let metadata = availableVersions[major] else {
                throw NodeInstallError.versionNotAvailable(major)
            }
            wrappedProgress(0.05)

            // Step 2: Check not already installed
            let descriptor = FetchDescriptor<NodeVersion>(
                predicate: #Predicate { $0.major == major }
            )
            if let existing = try modelContext.fetch(descriptor).first {
                throw NodeInstallError.alreadyInstalled(existing.minor)
            }
            wrappedProgress(0.1)

            // Step 3: Check if binaries already exist (multi-user optimization)
            let binariesExist = BinaryValidationService.validateNodeBinaries(major: major)

            if binariesExist {
                // Skip download - binaries already present from another user
                wrappedProgress(0.8)
            } else {
                // Step 3b: Download with progress (10% → 40%)
                let archiveURL = try await NodeDownloadService.download(
                    major: major,
                    metadata: metadata,
                    progressHandler: { p in wrappedProgress(0.1 + p * 0.3) }
                )

                // Step 4: Extract and install (40% → 80%)
                try await NodeDownloadService.extractAndInstall(
                    archiveURL: archiveURL,
                    major: major
                )
                wrappedProgress(0.8)
            }

            // Step 5: Extract full version and create SwiftData model
            let binaryURL = FadogenPaths.nodeBinaryPath(for: major)
            let fullVersion = try await NodeFileSystemService.extractVersion(from: binaryURL)

            // Determine if this is the first version (becomes default)
            let allVersions = try modelContext.fetch(FetchDescriptor<NodeVersion>())
            let isDefault = allVersions.isEmpty

            let nodeVersion = NodeVersion(
                major: major,
                minor: fullVersion,
                isDefault: isDefault
            )
            modelContext.insert(nodeVersion)
            wrappedProgress(0.9)

            // Step 6: Create versioned symlink (for all versions)
            try NodeFileSystemService.createVersionedSymlink(for: major)

            // Step 7: Update default symlinks if this is the default version (before wrappers!)
            if isDefault {
                try NodeFileSystemService.updateSymlinks(to: major)
            }

            // Step 8: Install Node.js wrappers if this is the first version (overwrites npm/npx symlinks)
            if isDefault {
                try FadogenShellService.installNodeWrappers()
                logger.info("Installed Node.js wrappers (first version)")
            }

            // Step 9: Save and update shell integration
            try modelContext.save()

            do {
                try await updateShellIntegration()
            } catch {
                logger.warning("Failed to update shell integration: \(error.localizedDescription)")
            }

            wrappedProgress(0.95)

            logger.info("Node.js \(major) installed successfully (\(fullVersion))")
            wrappedProgress(1.0)

        } catch {
            operationErrors[major] = error.localizedDescription
            throw error
        }
    }

    /// Removes a Node.js version completely
    func remove(major: String) async throws {
        guard !isAnyOperationActive else {
            throw NodeRemoveError.anotherOperationInProgress
        }

        logger.info("Starting removal of Node.js \(major)")

        removingVersions.insert(major)
        operationErrors[major] = nil

        defer {
            removingVersions.remove(major)
        }

        do {
            // Step 1: Fetch version from SwiftData
            let descriptor = FetchDescriptor<NodeVersion>(
                predicate: #Predicate { $0.major == major }
            )
            guard let versionToRemove = try modelContext.fetch(descriptor).first else {
                throw NodeRemoveError.versionNotInstalled(major)
            }

            // Step 2: Check if it's the last version
            let allVersions = try modelContext.fetch(FetchDescriptor<NodeVersion>())
            if allVersions.count == 1 {
                throw NodeRemoveError.cannotRemoveLastVersion
            }

            // Step 3: Check if it's the default version (and not the last one)
            if versionToRemove.isDefault {
                throw NodeRemoveError.cannotRemoveDefaultVersion
            }

            // Step 4: Reassign projects using this version to default (nil)
            let projectsDescriptor = FetchDescriptor<LocalProject>(
                predicate: #Predicate { $0.nodeVersion?.major == major }
            )
            let affectedProjects = try modelContext.fetch(projectsDescriptor)
            for project in affectedProjects {
                project.nodeVersion = nil
                try? project.syncNodeVersion()
                logger.info("Reassigned project \(project.name) to default Node.js version")
            }
            if !affectedProjects.isEmpty {
                try modelContext.save()
            }

            // Step 5: Delete installation from filesystem
            let isLastVersion = allVersions.count == 1
            try NodeFileSystemService.deleteInstallation(major: major, isLastVersion: isLastVersion)

            // Step 6: Remove Node.js wrappers if this was the last version
            if isLastVersion {
                try FadogenShellService.removeNodeWrappers()
                logger.info("Removed Node.js wrappers (last version uninstalled)")
            }

            // Step 7: Delete SwiftData model
            modelContext.delete(versionToRemove)
            try modelContext.save()

            // Step 8: Update shell integration
            do {
                try await updateShellIntegration()
            } catch {
                logger.warning("Failed to update shell integration: \(error.localizedDescription)")
            }

            logger.info("Node.js \(major) removed successfully")

        } catch {
            operationErrors[major] = error.localizedDescription
            throw error
        }
    }

    /// Sets a Node.js version as the default
    func setDefault(major: String) async throws {
        guard !isAnyOperationActive else {
            throw NodeRemoveError.anotherOperationInProgress
        }

        logger.info("Setting Node.js \(major) as default")

        // Fetch all versions
        let descriptor = FetchDescriptor<NodeVersion>()
        let allVersions = try modelContext.fetch(descriptor)

        // Verify version exists
        guard allVersions.contains(where: { $0.major == major }) else {
            throw NodeRemoveError.versionNotInstalled(major)
        }

        // Update isDefault flags
        for nodeVersion in allVersions {
            nodeVersion.isDefault = (nodeVersion.major == major)
        }

        // Update symlinks
        try NodeFileSystemService.updateSymlinks(to: major)

        // Save changes
        try modelContext.save()

        logger.info("Node.js \(major) set as default")
    }

    /// Updates an existing Node.js version to the latest available version
    func update(major: String, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        guard !isAnyOperationActive else {
            throw NodeUpdateError.anotherOperationInProgress
        }

        logger.info("Starting update of Node.js \(major)")

        updatingVersions.insert(major)
        operationProgress[major] = 0.0
        operationErrors[major] = nil

        defer {
            updatingVersions.remove(major)
            operationProgress[major] = nil
        }

        let wrappedProgress: @Sendable (Double) -> Void = { [weak self] p in
            Task { @MainActor in
                self?.operationProgress[major] = p
            }
            progress(p)
        }

        do {
            wrappedProgress(0.05)

            // Step 1: Fetch metadata
            guard let metadata = availableVersions[major] else {
                throw NodeUpdateError.noUpdateAvailable
            }

            wrappedProgress(0.10)

            // Step 2: Fetch existing version
            let descriptor = FetchDescriptor<NodeVersion>(
                predicate: #Predicate { $0.major == major }
            )
            guard let existingVersion = try modelContext.fetch(descriptor).first else {
                throw NodeUpdateError.versionNotInstalled
            }

            wrappedProgress(0.15)

            // Step 3: Check if update is needed
            guard existingVersion.minor != metadata.latest else {
                throw NodeUpdateError.noUpdateAvailable
            }

            wrappedProgress(0.20)

            // Step 4: Download with progress (20% → 50%)
            let archiveURL = try await NodeDownloadService.download(
                major: major,
                metadata: metadata,
                progressHandler: { downloadProgress in
                    let mappedProgress = 0.20 + (downloadProgress * 0.30)
                    wrappedProgress(mappedProgress)
                }
            )

            wrappedProgress(0.50)

            // Step 5: Delete old installation
            try NodeFileSystemService.deleteInstallation(major: major)

            // Step 6: Extract and install new version (50% → 85%)
            try await NodeDownloadService.extractAndInstall(archiveURL: archiveURL, major: major)

            wrappedProgress(0.85)

            // Step 7: Verify new version
            let binaryPath = FadogenPaths.nodeBinaryPath(for: major)
            let newVersion = try await NodeFileSystemService.extractVersion(from: binaryPath)

            // Step 8: Update SwiftData model
            existingVersion.minor = newVersion
            try modelContext.save()

            wrappedProgress(0.90)

            // Step 9: Update symlinks if this is the default version
            if existingVersion.isDefault {
                try NodeFileSystemService.updateSymlinks(to: major)
            }

            // Step 10: Update shell integration
            do {
                try await updateShellIntegration()
            } catch {
                logger.warning("Failed to update shell integration: \(error.localizedDescription)")
            }

            wrappedProgress(0.95)

            logger.info("Successfully updated Node.js \(major) to \(newVersion)")
            wrappedProgress(1.0)

        } catch {
            operationErrors[major] = error.localizedDescription
            throw error
        }
    }

    /// Updates shell integration with installed Node.js versions
    private func updateShellIntegration() async throws {
        let descriptor = FetchDescriptor<NodeVersion>()
        let installedVersions = try modelContext.fetch(descriptor)

        let majorVersions = installedVersions.map { $0.major }

        do {
            try ShellIntegrationService.updateShellIntegration(installedVersions: majorVersions)
        } catch {
            logger.warning("Failed to update shell integration: \(error.localizedDescription)")
        }
    }

    /// Refresh metadata from endoflife.date API and nodejs.org
    func refresh() async {
        guard !isLoading else {
            logger.warning("Refresh already in progress, ignoring request")
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            availableVersions = try await NodeMetadataService.fetchLTSVersions()
            logger.info("Fetched metadata for \(self.availableVersions.count) Node.js LTS versions")
        } catch {
            logger.error("Failed to fetch Node.js metadata: \(error.localizedDescription)")
            errorMessage = "Unable to check for updates"
        }

        isLoading = false
    }
}

// MARK: - Errors

enum NodeInstallError: LocalizedError {
    case versionNotAvailable(String)
    case alreadyInstalled(String)
    case anotherOperationInProgress

    var errorDescription: String? {
        switch self {
        case .versionNotAvailable(let version):
            return "Node.js \(version) is not available for installation"
        case .alreadyInstalled(let version):
            return "Node.js \(version) is already installed"
        case .anotherOperationInProgress:
            return "Another Node.js operation is in progress. Please wait for it to complete."
        }
    }
}

enum NodeRemoveError: LocalizedError {
    case cannotRemoveLastVersion
    case cannotRemoveDefaultVersion
    case versionNotInstalled(String)
    case anotherOperationInProgress

    var errorDescription: String? {
        switch self {
        case .cannotRemoveLastVersion:
            return "Cannot remove the last installed Node.js version. Install another version first."
        case .cannotRemoveDefaultVersion:
            return "Cannot remove the default Node.js version. Please select another version as default first."
        case .versionNotInstalled(let version):
            return "Node.js \(version) is not installed"
        case .anotherOperationInProgress:
            return "Another Node.js operation is in progress. Please wait for it to complete."
        }
    }
}

enum NodeUpdateError: LocalizedError {
    case versionNotInstalled
    case noUpdateAvailable
    case anotherOperationInProgress

    var errorDescription: String? {
        switch self {
        case .versionNotInstalled:
            return "Node.js version is not installed"
        case .noUpdateAvailable:
            return "Already using the latest version"
        case .anotherOperationInProgress:
            return "Another Node.js operation is in progress. Please wait for it to complete."
        }
    }
}
