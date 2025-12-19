import Foundation
import Subprocess
import System
import SwiftData

@Observable
final class ProjectGeneratorService {
    // MARK: - State

    private(set) var state: ProjectGeneratorState = .idle
    private(set) var currentStep: String = ""
    private(set) var progress: Double = 0.0
    private(set) var error: ProjectGeneratorError?

    // MARK: - Dependencies

    var phpManager: PHPManager?
    var servicesManager: ServicesManager?
    var serviceProcesses: ServiceProcessManager?
    var reverbManager: ReverbManager?
    var reverbProcess: ReverbProcessManager?
    var bunManager: BunManager?
    var nodeManager: NodeManager?
    var modelContext: ModelContext?

    private var currentTask: Task<URL, any Error>?
    private var pendingVersionCheckResult: VersionCheckResult?

    // MARK: - Validation

    func validate(config: ProjectConfiguration) throws {
        // Normalize first to ignore orphaned values
        let normalized = config.normalized()

        // Validate project name
        guard let sanitizedName = normalized.projectName.sanitizedHostname() else {
            throw ProjectGeneratorError.invalidProjectName(normalized.projectName)
        }

        // Validate install directory exists
        guard let installDirectory = normalized.installDirectory else {
            throw ProjectGeneratorError.installDirectoryNotFound("")
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: installDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ProjectGeneratorError.installDirectoryNotFound(installDirectory.path)
        }

        // Validate target directory doesn't exist
        let targetPath = installDirectory.appendingPathComponent(sanitizedName)
        if FileManager.default.fileExists(atPath: targetPath.path) {
            throw ProjectGeneratorError.directoryAlreadyExists(targetPath.path)
        }

        // Validate custom starter kit repo only if applicable
        if normalized.showsCustomRepo && normalized.starterKit == .custom {
            let repo = normalized.customStarterKitRepo.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !repo.isEmpty, isValidComposerPackage(repo) else {
                throw ProjectGeneratorError.invalidCustomStarterKitRepo(normalized.customStarterKitRepo)
            }
        }
    }

    // MARK: - Version Checking

    func checkVersions(config: ProjectConfiguration) throws -> VersionCheckResult {
        guard let modelContext, servicesManager != nil else {
            throw PrerequisiteError.metadataNotAvailable
        }

        var result = VersionCheckResult()
        let normalizedConfig = config.normalized()

        // Check database version (if not SQLite)
        if let dbServiceType = normalizedConfig.databaseType.toServiceType() {
            result.databaseStatus = try checkServiceVersion(dbServiceType, modelContext: modelContext)
        }

        // Check cache version (from queueBackend or cacheService)
        if let cacheServiceType = requiredCacheServiceType(from: normalizedConfig) {
            result.cacheStatus = try checkServiceVersion(cacheServiceType, modelContext: modelContext)
        }

        // Check Node.js version (only if npm is selected)
        if normalizedConfig.jsPackageManager == .npm {
            result.nodeStatus = try checkNodeVersion(modelContext: modelContext)
        }

        return result
    }

    private func checkServiceVersion(_ serviceType: ServiceType, modelContext: ModelContext) throws -> ServiceVersionStatus {
        guard let servicesManager else {
            throw PrerequisiteError.metadataNotAvailable
        }

        // Get latest available major from metadata
        let latestMajor = servicesManager.availableServices[serviceType.rawValue]?.keys.sorted(by: >).first

        // Get all installed versions of this service type
        let descriptor = FetchDescriptor<ServiceVersion>()
        let allVersions = try modelContext.fetch(descriptor)
        let installedVersions = allVersions.filter { $0.serviceType == serviceType }

        // Check if the recommended version is already installed
        let hasRecommendedVersion = installedVersions.contains { $0.major == latestMajor }

        // Report the recommended version if installed, otherwise any installed version
        let installed = installedVersions.first { $0.major == latestMajor } ?? installedVersions.first

        // Only outdated if we have an installation but NOT the recommended version
        let isOutdated = !installedVersions.isEmpty && !hasRecommendedVersion

        return ServiceVersionStatus(
            serviceType: serviceType,
            displayName: serviceType.displayName,
            installedMajor: installed?.major,
            recommendedMajor: latestMajor ?? "?",
            shouldUpgrade: isOutdated
        )
    }

    private func checkNodeVersion(modelContext: ModelContext) throws -> NodeVersionStatus {
        guard let nodeManager else {
            throw PrerequisiteError.metadataNotAvailable
        }

        // Find latest LTS version from metadata (non-EOL)
        let ltsVersions = nodeManager.availableVersions.filter { $0.value.isLts && !$0.value.isEol }
        let latestLTSMajor = ltsVersions.keys.sorted(by: >).first ?? "?"

        // Get all installed Node.js versions
        let descriptor = FetchDescriptor<NodeVersion>()
        let allVersions = try modelContext.fetch(descriptor)

        // Check if the recommended LTS version is already installed
        let hasRecommendedVersion = allVersions.contains { $0.major == latestLTSMajor }

        // Report the default version as "installed" (what the user is currently using)
        let defaultNode = allVersions.first { $0.isDefault }

        // Only suggest upgrade if:
        // 1. User has installations but not the recommended LTS
        // 2. AND the default version is OLDER than recommended (don't suggest "downgrade" from Current to LTS)
        let isOutdated: Bool
        if let defaultMajor = defaultNode?.major,
           let defaultMajorInt = Int(defaultMajor),
           let recommendedInt = Int(latestLTSMajor) {
            // Only upgrade if installed < recommended (don't suggest downgrade from Current)
            isOutdated = defaultMajorInt < recommendedInt && !hasRecommendedVersion
        } else {
            // Fallback: suggest upgrade if recommended LTS is not installed
            isOutdated = !allVersions.isEmpty && !hasRecommendedVersion
        }

        return NodeVersionStatus(
            installedMajor: defaultNode?.major,
            recommendedMajor: latestLTSMajor,
            shouldUpgrade: isOutdated
        )
    }

    // MARK: - Private

    private func isValidComposerPackage(_ package: String) -> Bool {
        // Accept vendor/package format
        let vendorPackagePattern = #"^[a-z0-9]([_.-]?[a-z0-9]+)*/[a-z0-9]([_.-]?[a-z0-9]+)*$"#
        if package.range(of: vendorPackagePattern, options: .regularExpression) != nil {
            return true
        }

        // Accept Git URLs (https:// or git@)
        if package.hasPrefix("https://") || package.hasPrefix("git@") {
            return true
        }

        return false
    }

    // MARK: - Command Execution

    func runCommand(
        _ executable: URL,
        arguments: [String],
        workingDirectory: URL
    ) async throws {
        try await runCommand(executable, arguments: arguments, workingDirectory: workingDirectory, environment: .inherit)
    }

    func runCommand(
        _ executable: URL,
        arguments: [String],
        workingDirectory: URL,
        environment: Subprocess.Environment
    ) async throws {
        let result = try await run(
            .path(FilePath(executable.path)),
            arguments: .init(arguments),
            environment: environment,
            workingDirectory: FilePath(workingDirectory.path),
            output: .string(limit: 64 * 1024),
            error: .string(limit: 64 * 1024)
        )

        try Task.checkCancellation()

        guard result.terminationStatus.isSuccess else {
            let exitCode: Int
            if case .exited(let code) = result.terminationStatus {
                exitCode = Int(code)
            } else {
                exitCode = -1
            }

            let stdout = result.standardOutput ?? ""
            let stderr = result.standardError ?? ""
            let output = stderr.isEmpty ? stdout : stderr
            let commandName = executable.lastPathComponent
            let fullCommand = "\(commandName) \(arguments.joined(separator: " "))"

            throw ProjectGeneratorError.commandFailed(
                command: fullCommand,
                exitCode: exitCode,
                output: output
            )
        }
    }

    // MARK: - Git

    func initializeGit(projectPath: URL) async throws {
        let gitBinary = URL(fileURLWithPath: "/usr/bin/git")

        // Initialize repository
        try await runCommand(gitBinary, arguments: ["init"], workingDirectory: projectPath)

        // Stage all files
        try await runCommand(gitBinary, arguments: ["add", "."], workingDirectory: projectPath)

        // Create initial commit
        try await runCommand(
            gitBinary,
            arguments: ["commit", "-m", "Initial commit"],
            workingDirectory: projectPath
        )
    }

    // MARK: - Prerequisites

    /// Prerequisites use 0-15% of progress, generation steps use 15-100%
    private func ensurePrerequisites(config: inout ProjectConfiguration) async throws {
        // Count active prerequisite steps to divide progress evenly
        var activeStepCount = 1  // PHP is always checked
        let needsDatabase = config.databaseType.toServiceType() != nil
        let needsCache = requiredCacheServiceType(from: config) != nil
        let needsReverb = config.reverb
        let needsBun = config.jsPackageManager == .bun

        if needsDatabase { activeStepCount += 1 }
        if needsCache { activeStepCount += 1 }
        if needsReverb { activeStepCount += 1 }
        if needsBun { activeStepCount += 1 }

        // Prerequisites use 0-15% of total progress, divided evenly among active steps
        let stepProgress = 0.15 / Double(activeStepCount)
        var completedSteps = 0

        // 1. Ensure PHP version is installed (always active)
        try Task.checkCancellation()
        currentStep = "Checking PHP \(config.phpVersion)..."
        try await ensurePHPVersion(config.phpVersion)
        completedSteps += 1
        progress = stepProgress * Double(completedSteps)

        // 2. Ensure database service (if not SQLite)
        if let serviceType = config.databaseType.toServiceType() {
            try Task.checkCancellation()
            currentStep = "Checking \(serviceType.displayName)..."
            let port = try await ensureService(serviceType, config: &config)
            config.databasePort = port
            completedSteps += 1
            progress = stepProgress * Double(completedSteps)
        }

        // 3. Ensure cache service (if Redis/Valkey needed for queue or cache)
        if let cacheServiceType = requiredCacheServiceType(from: config) {
            try Task.checkCancellation()
            currentStep = "Checking \(cacheServiceType.displayName)..."
            let port = try await ensureService(cacheServiceType, config: &config)
            config.cachePort = port
            completedSteps += 1
            progress = stepProgress * Double(completedSteps)
        }

        // 4. Ensure Reverb service (if toggle enabled)
        if config.reverb {
            try Task.checkCancellation()
            currentStep = "Checking Reverb..."
            try await ensureReverbService()
            completedSteps += 1
            progress = stepProgress * Double(completedSteps)
        }

        // 5. Ensure Bun is installed (if selected as JS package manager)
        if config.jsPackageManager == .bun {
            try Task.checkCancellation()
            currentStep = "Checking Bun..."
            try await ensureBun()
            completedSteps += 1
            progress = stepProgress * Double(completedSteps)
        }

        // 6. Store runtime versions for Dockerfile generation
        storeRuntimeVersions(in: &config)

        // Ensure we're at exactly 15% at end of prerequisites
        progress = 0.15
    }

    private func storeRuntimeVersions(in config: inout ProjectConfiguration) {
        guard let modelContext else { return }

        switch config.jsPackageManager {
        case .none:
            break  // No JavaScript runtime needed

        case .npm:
            let descriptor = FetchDescriptor<NodeVersion>(
                predicate: #Predicate { $0.isDefault == true }
            )
            if let defaultNode = try? modelContext.fetch(descriptor).first {
                config.nodeVersion = defaultNode.major
            }

        case .bun:
            if let bunVersion = bunManager?.getInstalledVersion() {
                // Extract major.minor from full version (e.g., "1.1.38" -> "1.1")
                let components = bunVersion.version.split(separator: ".")
                if components.count >= 2 {
                    config.bunVersion = "\(components[0]).\(components[1])"
                }
            }
        }
    }

    private func requiredCacheServiceType(from config: ProjectConfiguration) -> ServiceType? {
        // Check queue backend first
        if let queueBackend = config.queueBackend,
           let serviceType = queueBackend.toServiceType() {
            return serviceType
        }

        // Check cache service
        if let cacheService = config.cacheService {
            return cacheService.toServiceType()
        }

        return nil
    }

    private func ensurePHPVersion(_ major: String) async throws {
        guard let modelContext else { return }

        // Check if already installed
        let descriptor = FetchDescriptor<PHPVersion>(
            predicate: #Predicate { $0.major == major }
        )

        let result = try modelContext.fetch(descriptor).first
        if result != nil { return }

        // Not installed - need to install
        guard let phpManager else { return }

        // Ensure metadata is loaded
        if phpManager.availableVersions.isEmpty {
            await phpManager.refresh()
        }

        // Check version is available
        guard phpManager.availableVersions[major] != nil else {
            throw PrerequisiteError.phpNotAvailable(major)
        }

        currentStep = "Installing PHP \(major)..."

        do {
            try await phpManager.install(major: major)
        } catch {
            throw PrerequisiteError.phpInstallationFailed(major, error)
        }
    }

    private func ensureService(_ serviceType: ServiceType, config: inout ProjectConfiguration) async throws -> Int {
        guard let _ = modelContext, let servicesManager, let serviceProcesses else {
            throw PrerequisiteError.metadataNotAvailable
        }

        // Get latest major version from metadata
        if servicesManager.availableServices.isEmpty {
            await servicesManager.refresh()
        }
        let latestMajor = latestMajorVersion(for: serviceType)

        // Check if already installed
        if let existing = try findInstalledService(serviceType) {
            // Check if upgrade was requested via version check dialog
            let upgradeRequested = shouldUpgradeService(serviceType)
            if upgradeRequested, let latestMajor, existing.major != latestMajor {
                // Install the latest version alongside the existing one
                let port = try servicesManager.suggestPort(for: serviceType)

                currentStep = "Installing \(serviceType.displayName) \(latestMajor)..."

                do {
                    try await servicesManager.install(
                        service: serviceType,
                        major: latestMajor,
                        port: port,
                        autoStart: true
                    )
                } catch {
                    throw PrerequisiteError.serviceInstallationFailed(serviceType, error)
                }

                // Store the new version for Docker compose
                storeServiceVersion(serviceType, major: latestMajor, in: &config)
                return port
            }

            // No upgrade - use existing version
            if !serviceProcesses.isRunning(service: serviceType, major: existing.major) {
                currentStep = "Starting \(serviceType.displayName)..."
                do {
                    try await serviceProcesses.start(
                        service: serviceType,
                        major: existing.major,
                        port: existing.port
                    )
                } catch {
                    throw PrerequisiteError.serviceStartFailed(serviceType, error)
                }
            }

            // Store the existing version for Docker compose
            storeServiceVersion(serviceType, major: existing.major, in: &config)
            return existing.port
        }

        // Not installed - need to install latest
        guard let major = latestMajor else {
            throw PrerequisiteError.metadataNotAvailable
        }

        // Get available port
        let port = try servicesManager.suggestPort(for: serviceType)

        currentStep = "Installing \(serviceType.displayName) \(major)..."

        do {
            // Install with autoStart: true (will start automatically after install)
            try await servicesManager.install(
                service: serviceType,
                major: major,
                port: port,
                autoStart: true
            )
        } catch {
            throw PrerequisiteError.serviceInstallationFailed(serviceType, error)
        }

        // Store the installed version for Docker compose
        storeServiceVersion(serviceType, major: major, in: &config)
        return port
    }

    private func shouldUpgradeService(_ serviceType: ServiceType) -> Bool {
        guard let result = pendingVersionCheckResult else { return false }

        if let db = result.databaseStatus, db.serviceType == serviceType {
            return db.shouldUpgrade && db.needsUpgrade
        }
        if let cache = result.cacheStatus, cache.serviceType == serviceType {
            return cache.shouldUpgrade && cache.needsUpgrade
        }
        return false
    }

    private func storeServiceVersion(_ serviceType: ServiceType, major: String, in config: inout ProjectConfiguration) {
        switch serviceType {
        case .postgresql:
            config.postgresVersion = major
        case .mysql:
            config.mysqlVersion = major
        case .mariadb:
            config.mariadbVersion = major
        case .valkey:
            config.valkeyVersion = major
        case .redis:
            config.redisVersion = major
        }
    }

    private func ensureReverbService() async throws {
        guard let reverbManager, let reverbProcess else { return }

        // Check if already installed
        if let existingReverb = try? findInstalledReverb() {
            // Reverb installed - check if running
            if !reverbProcess.isRunning {
                currentStep = "Starting Reverb..."
                do {
                    try await reverbProcess.start(port: existingReverb.port)
                } catch {
                    throw PrerequisiteError.reverbStartFailed(error)
                }
            }
            return
        }

        // Not installed - need to install
        // Ensure metadata is loaded
        if reverbManager.availableMetadata == nil {
            await reverbManager.refresh()
        }

        guard reverbManager.availableMetadata != nil else {
            throw PrerequisiteError.metadataNotAvailable
        }

        // Get available port (default 8080, or next available)
        let port = try suggestReverbPort()

        currentStep = "Installing Reverb..."

        do {
            // Install with autoStart: true
            try await reverbManager.install(port: port, autoStart: true)
        } catch {
            throw PrerequisiteError.reverbInstallationFailed(error)
        }
    }

    private func ensureBun() async throws {
        guard let bunManager else { return }

        // Check if already installed
        if bunManager.getInstalledVersion() != nil {
            // Bun already installed
            return
        }

        // Not installed - need to install
        // Ensure metadata is loaded
        if bunManager.availableVersion == nil {
            await bunManager.refresh()
        }

        guard bunManager.availableVersion != nil else {
            throw PrerequisiteError.metadataNotAvailable
        }

        currentStep = "Installing Bun..."

        do {
            try await bunManager.install()
        } catch {
            throw PrerequisiteError.bunInstallationFailed(error)
        }
    }

    private func findInstalledService(_ serviceType: ServiceType) throws -> ServiceVersion? {
        guard let modelContext else { return nil }

        // Fetch all and filter in memory - SwiftData has issues with enum predicates
        // when the enum value is captured from outside the predicate closure
        let descriptor = FetchDescriptor<ServiceVersion>()
        let allVersions = try modelContext.fetch(descriptor)
        return allVersions.first { $0.serviceType == serviceType }
    }

    private func findInstalledReverb() throws -> ReverbVersion? {
        guard let modelContext else { return nil }

        let reverbId = "reverb"
        let descriptor = FetchDescriptor<ReverbVersion>(
            predicate: #Predicate { $0.uniqueIdentifier == reverbId }
        )

        return try modelContext.fetch(descriptor).first
    }

    private func latestMajorVersion(for serviceType: ServiceType) -> String? {
        servicesManager?.availableServices[serviceType.rawValue]?.keys.sorted(by: >).first
    }

    private func suggestReverbPort() throws -> Int {
        let defaultPort = 8080

        // Check if default port conflicts with any service
        if (try servicesManager?.detectPortConflict(port: defaultPort)) != nil {
            // Find next available port
            var candidatePort = defaultPort + 1
            while candidatePort < 65535 {
                if try servicesManager?.detectPortConflict(port: candidatePort) == nil {
                    return candidatePort
                }
                candidatePort += 1
            }
        }

        return defaultPort
    }

    struct GenerationStep {
        let name: String
        let weight: Double
        let action: (ProjectConfiguration, URL?) async throws -> URL?
    }

    // MARK: - Generation

    @discardableResult
    func generate(config: ProjectConfiguration, versionCheckResult: VersionCheckResult = VersionCheckResult()) async throws -> URL {
        // Store version check result for use in ensurePrerequisites
        self.pendingVersionCheckResult = versionCheckResult

        // Normalize configuration (mutable for port and version discovery)
        var normalizedConfig = config.normalized()

        // Reset state
        state = .generating
        progress = 0.0
        error = nil
        currentStep = "Preparing prerequisites..."

        // Phase 0: Ensure all prerequisites are met (PHP, database, cache, reverb)
        // This modifies normalizedConfig with discovered ports
        try await ensurePrerequisites(config: &normalizedConfig)

        // Validate before starting generation steps
        try validate(config: normalizedConfig)

        // Compute target path upfront for cleanup (validation already ensures these are valid)
        let installDirectory = normalizedConfig.installDirectory!
        let projectName = normalizedConfig.projectName.sanitizedHostname()!
        let targetProjectPath = installDirectory.appendingPathComponent(projectName)

        // Helper to clean up the project folder if it exists
        func cleanupProjectFolder() {
            if FileManager.default.fileExists(atPath: targetProjectPath.path) {
                try? FileManager.default.removeItem(at: targetProjectPath)
            }
        }

        // Track current project path during generation
        var projectPath: URL?

        // Select generation steps based on framework
        let steps: [GenerationStep] = switch normalizedConfig.framework {
        case .laravel: laravelGenerationSteps()
        case .symfony: symfonyGenerationSteps()
        }

        // Calculate total weight for progress
        let totalWeight = steps.reduce(0) { $0 + $1.weight }
        var completedWeight: Double = 0

        do {
            for step in steps {
                try Task.checkCancellation()

                currentStep = step.name
                projectPath = try await step.action(normalizedConfig, projectPath)

                completedWeight += step.weight
                // Prerequisites use 0-15%, generation steps use 15-100%
                progress = 0.15 + (completedWeight / totalWeight) * 0.85
            }

            state = .completed
            currentStep = "Project created successfully"
            progress = 1.0

            return projectPath!

        } catch is CancellationError {
            state = .cancelled
            currentStep = "Generation cancelled"
            error = .cancelled
            cleanupProjectFolder()
            throw ProjectGeneratorError.cancelled

        } catch let generatorError as ProjectGeneratorError {
            state = .failed
            error = generatorError
            cleanupProjectFolder()
            throw generatorError

        } catch let prerequisiteError as PrerequisiteError {
            // Prerequisites failed - wrap in ProjectGeneratorError for UI
            let wrappedError = ProjectGeneratorError.commandFailed(
                command: currentStep,
                exitCode: -1,
                output: prerequisiteError.localizedDescription
            )
            state = .failed
            self.error = wrappedError
            // Don't cleanup - project folder doesn't exist yet during prerequisites
            throw wrappedError

        } catch {
            let wrappedError = ProjectGeneratorError.commandFailed(
                command: currentStep,
                exitCode: -1,
                output: error.localizedDescription
            )
            state = .failed
            self.error = wrappedError
            cleanupProjectFolder()
            throw wrappedError
        }
    }

    // MARK: - Task Management

    func startGeneration(config: ProjectConfiguration) -> Task<URL, any Error> {
        let task = Task {
            try await generate(config: config)
        }
        currentTask = task
        return task
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }
}
