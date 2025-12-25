import Foundation
import SwiftData

@Observable
final class PHPManager {
    var availableVersions: PHPMetadataCollection = [:]
    var isLoading = false
    var errorMessage: String?

    // Operation state (persists across view navigations)
    var installingVersions: Set<String> = []
    var removingVersions: Set<String> = []
    var updatingVersions: Set<String> = []
    var operationProgress: [String: Double] = [:]
    var operationErrors: [String: String] = [:]

    private let metadataURL = GenericDownloadService.metadataURL(for: "php")
    private let modelContext: ModelContext
    private let phpFPM: PHPFPMService?
    private let caddyConfig: CaddyConfigService?

    init(modelContext: ModelContext, phpFPM: PHPFPMService? = nil, caddyConfig: CaddyConfigService? = nil) {
        self.modelContext = modelContext
        self.phpFPM = phpFPM
        self.caddyConfig = caddyConfig
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

    /// Initialize PHP manager and fetch available versions
    func initialize() async {
        // Ensure directories and CA cert exist BEFORE any config generation
        // This prevents php.ini from referencing non-existent cacert.pem
        try? PHPConfigService.ensureDirectories()
        try? PHPConfigService.ensureCACert()

        await ensureBundledVersion()

        // Fetch metadata first (required for download recovery in reconciliation)
        await refresh()

        // Synchronize installed versions with SwiftData
        try? await syncInstalledVersions()

        // Update shell integration after sync
        try? await updateShellIntegration()
    }

    /// Ensures at least the bundled PHP version is installed
    /// Called on app launch to guarantee a working PHP installation
    func ensureBundledVersion() async {
        do {
            // Check if any versions are already installed
            let installedBinaries = try await PHPFileSystemService.scanInstalledBinaries()

            if !installedBinaries.isEmpty {
                return
            }

            // No versions installed - copy bundled version
            guard let bundledMajor = await PHPFileSystemService.detectBundledVersion() else {
                fatalError("No PHP version available")
            }

            // Copy bundled binaries
            let (cliURL, _) = try PHPFileSystemService.copyBundledBinary(major: bundledMajor)

            // Extract full version
            let fullVersion = try await PHPFileSystemService.extractVersion(from: cliURL)

            // Create symlinks (this is the first/default version)
            try PHPFileSystemService.updateSymlinks(to: bundledMajor)

            // Create config directory
            try PHPFileSystemService.createConfigDirectory(for: bundledMajor)

            // Generate PHP configuration files
            try PHPConfigService.generatePHPIni(major: bundledMajor)
            try PHPConfigService.generateFPMConfig(major: bundledMajor)

            // Save to SwiftData
            let phpVersion = PHPVersion(
                major: bundledMajor,
                minor: fullVersion,
                isDefault: true
            )
            modelContext.insert(phpVersion)
            try modelContext.save()

        } catch {
            fatalError("Failed to install bundled PHP version: \(error)")
        }
    }

    /// Synchronizes installed PHP versions from filesystem with SwiftData
    /// Performs complete bidirectional reconciliation with integrity validation and recovery
    func syncInstalledVersions() async throws {
        // Step 1: Scan filesystem for installed binaries and detect default
        let installedBinaries = try await PHPFileSystemService.scanInstalledBinaries()
        let defaultVersion = try PHPFileSystemService.detectDefaultVersion()

        // Step 1.5: Deduplicate existing PHPVersion models (CloudKit merge conflicts)
        let allExisting = try modelContext.fetch(FetchDescriptor<PHPVersion>())
        let grouped = Dictionary(grouping: allExisting, by: { $0.major })

        for (_, versions) in grouped where versions.count > 1 {
            // Keep the version with the highest minor (most recent), or first if tied
            let sorted = versions.sorted { v1, v2 in
                // Compare minor versions (e.g., "8.3.15" > "8.3.14")
                v1.minor.compare(v2.minor, options: .numeric) == .orderedDescending
            }
            // Keep sorted.first, delete all others
            for duplicate in sorted.dropFirst() {
                modelContext.delete(duplicate)
            }
        }

        // Save deduplication changes before proceeding
        try modelContext.save()

        // Step 2: Forward reconciliation with integrity validation
        // Track only VALID binaries (after integrity check) to enable recovery of corrupted ones
        var validBinaries: [String: URL] = [:]

        for (major, binaryURL) in installedBinaries {
            // Validate binary integrity
            guard await PHPFileSystemService.validateBinaryIntegrity(url: binaryURL) else {
                try PHPFileSystemService.deleteBinary(major: major)
                continue  // Skip - will be recovered in backward reconciliation
            }

            // Track as valid
            validBinaries[major] = binaryURL

            // Check if PHPVersion already exists
            let descriptor = FetchDescriptor<PHPVersion>(
                predicate: #Predicate { $0.major == major }
            )
            let results = try modelContext.fetch(descriptor)

            if let existing = results.first {
                // Update minor version if changed
                let fullVersion = try await PHPFileSystemService.extractVersion(from: binaryURL)
                if existing.minor != fullVersion {
                    existing.minor = fullVersion
                }

                // Update isDefault based on symlink
                existing.isDefault = (major == defaultVersion)
            } else {
                // Create new PHPVersion
                let fullVersion = try await PHPFileSystemService.extractVersion(from: binaryURL)
                let phpVersion = PHPVersion(
                    major: major,
                    minor: fullVersion,
                    isDefault: major == defaultVersion
                )
                modelContext.insert(phpVersion)
            }
        }

        // Step 3: Backward reconciliation (orphaned models + corrupted binaries)
        // Re-fetch models after forward reconciliation to get current state
        let currentModels = try modelContext.fetch(FetchDescriptor<PHPVersion>())
        try await reconcileOrphanedModels(installedBinaries: validBinaries, allModels: currentModels)

        // Step 4: Enforce default constraint (exactly one isDefault=true)
        // Re-fetch models after orphaned reconciliation
        let finalModels = try modelContext.fetch(FetchDescriptor<PHPVersion>())
        try enforceDefaultConstraint(allModels: finalModels)

        // Step 5: Ensure config directories exist for all installed versions
        for model in finalModels {
            // Create config directory if missing (idempotent)
            try PHPFileSystemService.createConfigDirectory(for: model.major)

            // Generate config files only if they don't exist (preserves user customizations)
            let configPath = FadogenPaths.configPath(for: model.major)
            let phpIniPath = configPath.appendingPathComponent("php.ini")
            let fpmConfigPath = configPath.appendingPathComponent("php-fpm.conf")

            if !FileManager.default.fileExists(atPath: phpIniPath.path) {
                try PHPConfigService.generatePHPIni(major: model.major)
            }

            if !FileManager.default.fileExists(atPath: fpmConfigPath.path) {
                try PHPConfigService.generateFPMConfig(major: model.major)
            }
        }

        // Step 6: Save all changes
        try modelContext.save()
    }

    /// Reconciles orphaned SwiftData models (models without filesystem binaries)
    /// Attempts recovery by copying bundled version or downloading, otherwise deletes model
    /// - Parameters:
    ///   - installedBinaries: Dictionary of currently installed binaries from filesystem
    ///   - allModels: All PHPVersion models from SwiftData
    private func reconcileOrphanedModels(
        installedBinaries: [String: URL],
        allModels: [PHPVersion]
    ) async throws {
        for model in allModels {
            // Skip if binary exists on filesystem
            guard installedBinaries[model.major] == nil else { continue }

            // Attempt recovery: Try bundled first
            if let bundledMajor = await PHPFileSystemService.detectBundledVersion(),
               bundledMajor == model.major {
                do {
                    // Copy bundled binary
                    let (cliURL, _) = try PHPFileSystemService.copyBundledBinary(major: model.major)

                    // Extract version and update model
                    let fullVersion = try await PHPFileSystemService.extractVersion(from: cliURL)
                    model.minor = fullVersion

                    // Recreate config directory and files
                    try PHPFileSystemService.createConfigDirectory(for: model.major)
                    try PHPConfigService.generatePHPIni(major: model.major)
                    try PHPConfigService.generateFPMConfig(major: model.major)

                    // Update symlink if this was the default version
                    if model.isDefault {
                        try PHPFileSystemService.updateSymlinks(to: model.major)
                    }

                    continue
                } catch {
                    // Fall through to try download
                }
            }

            // Attempt recovery: Try downloading from metadata
            if let metadata = availableVersions[model.major] {
                do {
                    // Download silently (no progress callback)
                    let archiveURL = try await PHPDownloadService.download(
                        major: model.major,
                        metadata: metadata,
                        progressHandler: { _ in }
                    )

                    // Extract and install
                    try await PHPDownloadService.extractAndInstall(
                        archiveURL: archiveURL,
                        major: model.major
                    )

                    // Extract version and update model
                    let binaryURL = FadogenPaths.binaryPath(for: model.major)
                    let fullVersion = try await PHPFileSystemService.extractVersion(from: binaryURL)
                    model.minor = fullVersion

                    // Recreate config directory and files
                    try PHPFileSystemService.createConfigDirectory(for: model.major)
                    try PHPConfigService.generatePHPIni(major: model.major)
                    try PHPConfigService.generateFPMConfig(major: model.major)

                    // Update symlink if this was the default version
                    if model.isDefault {
                        try PHPFileSystemService.updateSymlinks(to: model.major)
                    }

                    continue
                } catch {
                    // Fall through to delete model
                }
            }

            // Cannot recover - delete orphaned model
            modelContext.delete(model)
        }
    }

    /// Enforces the constraint that exactly one PHP version must be marked as default
    /// Reconciles multiple defaults to symlink truth, or creates a default if none exists
    /// - Parameter allModels: All PHPVersion models from SwiftData
    private func enforceDefaultConstraint(allModels: [PHPVersion]) throws {
        let defaultVersions = allModels.filter { $0.isDefault }

        if defaultVersions.count == 0 {
            // No default version - set first version as default
            guard let firstVersion = allModels.first else {
                // No versions at all - this is handled elsewhere (fatalError in ensureBundledVersion)
                return
            }

            firstVersion.isDefault = true

            // Update symlink to match
            try? PHPFileSystemService.updateSymlinks(to: firstVersion.major)

        } else if defaultVersions.count > 1 {
            // Multiple defaults - reconcile to symlink truth
            let symlinkDefault = try PHPFileSystemService.detectDefaultVersion()

            for version in allModels {
                version.isDefault = (version.major == symlinkDefault)
            }

            if symlinkDefault == nil {
                // Symlink doesn't exist - set first version as default
                if let firstVersion = allModels.first {
                    firstVersion.isDefault = true
                    try PHPFileSystemService.updateSymlinks(to: firstVersion.major)
                }
            }
        }
        // If count == 1, everything is correct - no action needed
    }

    /// Installs a new PHP version with progress tracking
    /// - Parameters:
    ///   - major: Major version string (e.g., "8.3")
    ///   - progress: Optional closure receiving progress from 0.0 to 1.0 (defaults to no-op)
    /// - Throws: PHPInstallError, PHPDownloadError, PHPFileSystemError
    func install(major: String, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        // GUARD: Reject if ANY operation is running (serialization)
        guard !isAnyOperationActive else {
            throw PHPInstallError.anotherOperationInProgress
        }

        // Set state BEFORE async work
        installingVersions.insert(major)
        operationProgress[major] = 0.0
        operationErrors[major] = nil  // Clear previous error

        // Cleanup in ALL cases (success or error)
        defer {
            installingVersions.remove(major)
            operationProgress[major] = nil
        }

        // Wrap progress to update centralized state
        let wrappedProgress: @Sendable (Double) -> Void = { [weak self] p in
            Task { @MainActor in
                self?.operationProgress[major] = p
            }
            progress(p)  // Forward to original callback
        }

        do {
            // Step 1: Validate metadata exists (instant feedback)
            guard let metadata = availableVersions[major] else {
                throw PHPInstallError.versionNotAvailable(major)
            }
            wrappedProgress(0.05)

            // Step 2: Check not already installed
            let descriptor = FetchDescriptor<PHPVersion>(
                predicate: #Predicate { $0.major == major }
            )
            if let existing = try modelContext.fetch(descriptor).first {
                throw PHPInstallError.alreadyInstalled(existing.minor)
            }
            wrappedProgress(0.1)

            // Step 3: Download with progress (10% → 35%)
            let archiveURL = try await PHPDownloadService.download(
                major: major,
                metadata: metadata,
                progressHandler: { p in wrappedProgress(0.1 + p * 0.25) }
            )

            // Step 4: Extract and install binaries (35% → 70%)
            // This is the most time-consuming step (tar extraction + rename + permissions)
            try await PHPDownloadService.extractAndInstall(
                archiveURL: archiveURL,
                major: major
            )
            wrappedProgress(0.7)

            // Step 5: Generate configuration (70% → 80%)
            try PHPFileSystemService.createConfigDirectory(for: major)
            try PHPConfigService.generatePHPIni(major: major)
            try PHPConfigService.generateFPMConfig(major: major)
            wrappedProgress(0.8)

            // Step 6: Extract full version and create SwiftData model (80% → 90%)
            let binaryURL = FadogenPaths.binaryPath(for: major)
            let fullVersion = try await PHPFileSystemService.extractVersion(from: binaryURL)

            // Determine if this is the first version (becomes default)
            let allVersions = try modelContext.fetch(FetchDescriptor<PHPVersion>())
            let isDefault = allVersions.isEmpty

            let phpVersion = PHPVersion(
                major: major,
                minor: fullVersion,
                isDefault: isDefault
            )
            modelContext.insert(phpVersion)
            wrappedProgress(0.9)

            // Step 7: Update symlinks if default
            if isDefault {
                try PHPFileSystemService.updateSymlinks(to: major)
            }

            // Step 8: Save and update shell integration (90% → 95%)
            try modelContext.save()

            try? await updateShellIntegration()

            wrappedProgress(0.95)

            // Step 9: Start PHP-FPM for this version (95% → 100%)
            phpFPM?.start(major: major)

            wrappedProgress(1.0)

        } catch {
            // Store error for UI display
            operationErrors[major] = error.localizedDescription
            throw error
        }
    }

    /// Removes a PHP version completely
    /// - Parameter major: Major version string (e.g., "8.3")
    /// - Throws: PHPRemoveError if removal is not allowed or fails
    func remove(major: String) async throws {
        // GUARD: Reject if ANY operation is running (serialization)
        guard !isAnyOperationActive else {
            throw PHPRemoveError.anotherOperationInProgress
        }

        // Set state BEFORE async work
        removingVersions.insert(major)
        operationErrors[major] = nil  // Clear previous error

        // Cleanup in ALL cases (success or error)
        defer {
            removingVersions.remove(major)
        }

        do {
            // Step 1: Fetch version from SwiftData
            let descriptor = FetchDescriptor<PHPVersion>(
                predicate: #Predicate { $0.major == major }
            )
            guard let versionToRemove = try modelContext.fetch(descriptor).first else {
                throw PHPRemoveError.versionNotInstalled(major)
            }

            // Step 2: Check if it's the last version
            let allVersions = try modelContext.fetch(FetchDescriptor<PHPVersion>())
            if allVersions.count == 1 {
                throw PHPRemoveError.cannotRemoveLastVersion
            }

            // Step 3: Check if it's the default version
            if versionToRemove.isDefault {
                throw PHPRemoveError.cannotRemoveDefaultVersion
            }

            // Step 4: Reassign projects using this version to default (nil)
            let projectsDescriptor = FetchDescriptor<LocalProject>(
                predicate: #Predicate { $0.phpVersion?.major == major }
            )
            let affectedProjects = try modelContext.fetch(projectsDescriptor)
            for project in affectedProjects {
                project.phpVersion = nil
                // Sync .fadogen file to reflect the change
                try? project.syncPHPVersion()
            }
            if !affectedProjects.isEmpty {
                try modelContext.save()
            }

            // Step 5: Stop PHP-FPM for this version
            await phpFPM?.stop(major: major)

            // Step 6: Delete binaries from filesystem
            try PHPFileSystemService.deleteBinary(major: major)

            // Step 7: Delete config directory
            try PHPFileSystemService.deleteConfigDirectory(major: major)

            // Step 8: Delete SwiftData model
            modelContext.delete(versionToRemove)
            try modelContext.save()

            // Step 9: Update shell integration
            try? await updateShellIntegration()

            // Step 10: Synchronize Caddy if projects were affected
            if !affectedProjects.isEmpty {
                caddyConfig?.reconcile()
            }

        } catch {
            // Store error for UI display
            operationErrors[major] = error.localizedDescription
            throw error
        }
    }

    /// Sets a PHP version as the default
    /// - Parameter major: Major version string (e.g., "8.3")
    /// - Throws: PHPRemoveError if version is not installed
    func setDefault(major: String) async throws {
        // GUARD: Reject if ANY operation is running (serialization)
        guard !isAnyOperationActive else {
            throw PHPRemoveError.anotherOperationInProgress
        }

        try await setDefaultInternal(major: major)
    }

    /// Internal method to set default without operation guard
    /// Used by setNewDefaultAndRemove workflow
    private func setDefaultInternal(major: String) async throws {
        // Fetch all versions
        let descriptor = FetchDescriptor<PHPVersion>()
        let allVersions = try modelContext.fetch(descriptor)

        // Verify version exists
        guard allVersions.contains(where: { $0.major == major }) else {
            throw PHPRemoveError.versionNotInstalled(major)
        }

        // Update isDefault flags
        for phpVersion in allVersions {
            phpVersion.isDefault = (phpVersion.major == major)
        }

        // Update symlinks
        try PHPFileSystemService.updateSymlinks(to: major)

        // Save changes
        try modelContext.save()

        // Synchronize Caddy (sites using default will get new socket path)
        caddyConfig?.reconcile()
    }

    /// Updates an existing PHP version to the latest available version
    /// Downloads new binaries, deletes old ones, and replaces them atomically
    /// - Parameters:
    ///   - major: Major version string (e.g., "8.3")
    ///   - progress: Closure receiving progress from 0.0 to 1.0
    /// - Throws: PHPUpdateError, PHPDownloadError, PHPFileSystemError
    func update(major: String, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        // GUARD: Reject if ANY operation is running (serialization)
        guard !isAnyOperationActive else {
            throw PHPUpdateError.anotherOperationInProgress
        }

        // Set state BEFORE async work
        updatingVersions.insert(major)
        operationProgress[major] = 0.0
        operationErrors[major] = nil  // Clear previous error

        // Cleanup in ALL cases (success or error)
        defer {
            updatingVersions.remove(major)
            operationProgress[major] = nil
        }

        // Wrap progress to update centralized state
        let wrappedProgress: @Sendable (Double) -> Void = { [weak self] p in
            Task { @MainActor in
                self?.operationProgress[major] = p
            }
            progress(p)  // Forward to original callback
        }

        do {
            wrappedProgress(0.05)

            // Step 1: Fetch metadata
            guard let metadata = availableVersions[major] else {
                throw PHPUpdateError.noUpdateAvailable
            }

            wrappedProgress(0.10)

            // Step 2: Fetch existing version from SwiftData
            let descriptor = FetchDescriptor<PHPVersion>(
                predicate: #Predicate { $0.major == major }
            )
            guard let existingVersion = try modelContext.fetch(descriptor).first else {
                throw PHPUpdateError.versionNotInstalled
            }

            wrappedProgress(0.15)

            // Step 3: Check if update is needed
            guard existingVersion.minor != metadata.latest else {
                throw PHPUpdateError.noUpdateAvailable
            }

            wrappedProgress(0.20)

            // Step 4: Download with progress (20% → 50%)
            let archiveURL = try await PHPDownloadService.download(
                major: major,
                metadata: metadata,
                progressHandler: { downloadProgress in
                    let mappedProgress = 0.20 + (downloadProgress * 0.30)
                    wrappedProgress(mappedProgress)
                }
            )

            wrappedProgress(0.50)

            // Step 5: Delete old binaries (required for update)
            try PHPFileSystemService.deleteBinary(major: major)

            // Step 6: Extract and install new binaries (50% → 85%)
            try await PHPDownloadService.extractAndInstall(archiveURL: archiveURL, major: major)

            wrappedProgress(0.85)

            // Step 7: Verify new version (85% → 90%)
            let binaryPath = FadogenPaths.binaryPath(for: major)
            let newVersion = try await PHPFileSystemService.extractVersion(from: binaryPath)

            // Step 8: Update SwiftData model
            existingVersion.minor = newVersion
            try modelContext.save()

            wrappedProgress(0.90)

            // Step 9: Update symlinks if this is the default version
            if existingVersion.isDefault {
                try PHPFileSystemService.updateSymlinks(to: major)
            }

            // Step 10: Update shell integration
            try? await updateShellIntegration()

            wrappedProgress(0.95)

            // Step 11: Restart PHP-FPM for this version (95% → 100%)
            phpFPM?.restart(major: major)

            wrappedProgress(1.0)

        } catch {
            // Store error for UI display
            operationErrors[major] = error.localizedDescription
            throw error
        }
    }

    /// Updates shell integration with installed PHP versions
    private func updateShellIntegration() async throws {
        // Fetch all installed versions from SwiftData
        let descriptor = FetchDescriptor<PHPVersion>()
        let installedVersions = try modelContext.fetch(descriptor)

        let majorVersions = installedVersions.map { $0.major }
        try? ShellIntegrationService.updateShellIntegration(installedVersions: majorVersions)
    }

    /// Refresh metadata from remote server
    func refresh() async {
        // GUARD: Reject if already loading (prevents multiple concurrent fetches)
        guard !isLoading else {
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            // Create URLSession without cache to avoid 404 cached errors
            let session = DownloadUtilities.createNoCacheSession()

            let (data, response) = try await session.data(from: self.metadataURL)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                throw PHPManagerError.invalidResponse
            }

            let decoder = JSONDecoder()
            availableVersions = try decoder.decode(PHPMetadataCollection.self, from: data)
        } catch {
            errorMessage = "Unable to check for updates"
        }

        isLoading = false
    }
}

// MARK: - Errors

enum PHPManagerError: LocalizedError {
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from metadata server"
        }
    }
}

enum PHPInstallError: LocalizedError {
    case versionNotAvailable(String)
    case alreadyInstalled(String)
    case anotherOperationInProgress

    var errorDescription: String? {
        switch self {
        case .versionNotAvailable(let version):
            return "PHP \(version) is not available for installation"
        case .alreadyInstalled(let version):
            return "PHP \(version) is already installed"
        case .anotherOperationInProgress:
            return "Another PHP operation is in progress. Please wait for it to complete."
        }
    }
}

enum PHPRemoveError: LocalizedError {
    case cannotRemoveLastVersion
    case cannotRemoveDefaultVersion
    case versionNotInstalled(String)
    case anotherOperationInProgress

    var errorDescription: String? {
        switch self {
        case .cannotRemoveLastVersion:
            return "Cannot remove the last installed PHP version. Install another version first."
        case .cannotRemoveDefaultVersion:
            return "Cannot remove the default PHP version. Please select another version as default first."
        case .versionNotInstalled(let version):
            return "PHP \(version) is not installed"
        case .anotherOperationInProgress:
            return "Another PHP operation is in progress. Please wait for it to complete."
        }
    }
}

enum PHPUpdateError: LocalizedError {
    case versionNotInstalled
    case noUpdateAvailable
    case anotherOperationInProgress

    var errorDescription: String? {
        switch self {
        case .versionNotInstalled:
            return "PHP version is not installed"
        case .noUpdateAvailable:
            return "Already using the latest version"
        case .anotherOperationInProgress:
            return "Another PHP operation is in progress. Please wait for it to complete."
        }
    }
}
