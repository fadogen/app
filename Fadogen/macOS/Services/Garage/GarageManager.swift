import Foundation
import SwiftData

@Observable
final class GarageManager {

    var availableMetadata: GarageMetadata?
    var isLoading = false
    var errorMessage: String?

    var isInstalling = false
    var isRemoving = false
    var isUpdating = false
    var operationError: String?

    private let metadataURL = GenericDownloadService.metadataURL(for: "garage")
    private let modelContext: ModelContext
    private weak var garageProcess: GarageProcessManager?
    private weak var garageInitializer: GarageInitializer?
    private weak var caddyConfig: CaddyConfigService?

    init(
        modelContext: ModelContext,
        garageProcess: GarageProcessManager? = nil,
        garageInitializer: GarageInitializer? = nil,
        caddyConfig: CaddyConfigService? = nil
    ) {
        self.modelContext = modelContext
        self.garageProcess = garageProcess
        self.garageInitializer = garageInitializer
        self.caddyConfig = caddyConfig
    }

    func initialize() async {
        await refresh()
    }

    // MARK: - Metadata

    func refresh() async {
        // GUARD: Prevent concurrent fetches
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
                throw GarageManagerError.invalidResponse
            }

            let decoder = JSONDecoder()
            let metadata = try decoder.decode(GarageMetadata.self, from: data)

            availableMetadata = metadata

        } catch {
            errorMessage = "Unable to check for updates"
        }

        isLoading = false
    }

    var isAnyOperationActive: Bool {
        isInstalling || isRemoving || isUpdating
    }

    // MARK: - Installation

    func install(s3Port: Int = 3900, autoStart: Bool = false) async throws {
        // GUARD: Check for active operation
        guard !isAnyOperationActive else {
            throw GarageInstallError.anotherOperationInProgress
        }

        // Set state BEFORE async work
        isInstalling = true
        operationError = nil
        garageProcess?.clearStartupError()

        // Cleanup in ALL cases (success or error)
        defer {
            isInstalling = false
        }

        do {
            // Step 1: Validate metadata exists
            guard let metadata = availableMetadata else {
                throw GarageInstallError.metadataNotAvailable
            }

            // Step 2: Check not already installed
            let descriptor = FetchDescriptor<GarageVersion>(
                predicate: #Predicate { $0.uniqueIdentifier == "garage" }
            )
            if try modelContext.fetch(descriptor).first != nil {
                throw GarageInstallError.alreadyInstalled
            }

            // Step 3: Check if binaries already exist (multi-user optimization)
            let binariesExist = validateGarageBinaries()

            if !binariesExist {
                // Step 3b: Preventive deletion of binary directory (if partial/corrupted)
                let binaryPath = FadogenPaths.garageBinaryPath
                if FileManager.default.fileExists(atPath: binaryPath.path) {
                    try FileManager.default.removeItem(at: binaryPath)
                }

                // Step 4: Download
                let archiveURL = try await GarageDownloadService.download(
                    metadata: metadata,
                    progressHandler: { _ in }
                )

                // Step 5: Extract and install
                try await GarageDownloadService.extractAndInstall(archiveURL: archiveURL)
            }

            // Step 6: Create data directory
            let dataPath = FadogenPaths.garageDataDirectory
            try FileManager.default.createDirectory(at: dataPath, withIntermediateDirectories: true)

            // Step 7: Create SwiftData model
            let garageVersion = GarageVersion(
                version: metadata.latest,
                s3Port: s3Port,
                autoStart: autoStart
            )
            modelContext.insert(garageVersion)
            try modelContext.save()

            // Step 8: Regenerate Caddy config (adds Garage proxy)
            try caddyConfig?.generateMainCaddyfile()

            // Step 9: Reload Caddy to apply new configuration and generate certificate
            caddyConfig?.reloadCaddy()

            // Step 9b: Wait for Caddy to generate s3.localhost certificate
            let certPath = FadogenPaths.caddyDataDirectory
                .appendingPathComponent("pki/authorities/local/s3.localhost.crt")

            var attempts = 0
            let maxAttempts = 100  // 10 seconds
            while attempts < maxAttempts {
                if FileManager.default.fileExists(atPath: certPath.path) {
                    break
                }
                try? await Task.sleep(for: .milliseconds(100))
                attempts += 1
            }

            // Step 10: Start Garage immediately if autoStart is enabled
            if autoStart {
                try await garageProcess?.start(s3Port: s3Port)

                // Step 11: Initialize (layout + key) on first start
                try await garageInitializer?.initialize(garageVersion: garageVersion)
            }

        } catch {
            operationError = error.localizedDescription
            throw error
        }
    }

    // MARK: - Update

    func update() async throws {
        // GUARD: Check for active operation
        guard !isAnyOperationActive else {
            throw GarageUpdateError.anotherOperationInProgress
        }

        // Set state
        isUpdating = true
        operationError = nil

        defer {
            isUpdating = false
        }

        do {
            // Step 1: Fetch metadata
            guard let metadata = availableMetadata else {
                throw GarageUpdateError.noUpdateAvailable
            }

            // Step 2: Fetch existing version
            let descriptor = FetchDescriptor<GarageVersion>(
                predicate: #Predicate { $0.uniqueIdentifier == "garage" }
            )
            guard let existingVersion = try modelContext.fetch(descriptor).first else {
                throw GarageUpdateError.notInstalled
            }

            // Step 3: Check if update needed
            guard existingVersion.version != metadata.latest else {
                throw GarageUpdateError.noUpdateAvailable
            }

            // Step 4: Store running state before update
            let wasRunning = garageProcess?.isRunning ?? false

            // Step 5: Stop Garage if running
            if wasRunning {
                await garageProcess?.stop()
            }

            // Step 6: Download
            let archiveURL = try await GarageDownloadService.download(
                metadata: metadata,
                progressHandler: { _ in }
            )

            // Step 7: Delete old binaries
            let binaryPath = FadogenPaths.garageBinaryPath
            if FileManager.default.fileExists(atPath: binaryPath.path) {
                try FileManager.default.removeItem(at: binaryPath)
            }

            // Step 8: Extract new binaries
            try await GarageDownloadService.extractAndInstall(archiveURL: archiveURL)

            // Step 9: Update model (preserve port, autoStart, and isInitialized)
            existingVersion.version = metadata.latest
            try modelContext.save()

            // Step 10: Restart Garage if it was running
            if wasRunning {
                try await garageProcess?.start(s3Port: existingVersion.s3Port)
            }

        } catch {
            operationError = error.localizedDescription
            throw error
        }
    }

    // MARK: - Removal

    func remove() async throws {
        // GUARD: Check for active operation
        guard !isAnyOperationActive else {
            throw GarageRemoveError.anotherOperationInProgress
        }

        // Set state
        isRemoving = true
        operationError = nil
        garageProcess?.clearStartupError()

        defer {
            isRemoving = false
        }

        do {
            // Step 1: Fetch version from SwiftData
            let descriptor = FetchDescriptor<GarageVersion>(
                predicate: #Predicate { $0.uniqueIdentifier == "garage" }
            )
            guard let versionToRemove = try modelContext.fetch(descriptor).first else {
                throw GarageRemoveError.notInstalled
            }

            // Step 2: Stop Garage if running
            if garageProcess?.isRunning == true {
                await garageProcess?.stop()
            }

            // Step 3: Delete binaries
            let binaryPath = FadogenPaths.garageBinaryPath
            if FileManager.default.fileExists(atPath: binaryPath.path) {
                try FileManager.default.removeItem(at: binaryPath)
            }

            // Step 4: Delete config directory
            let configPath = FadogenPaths.garageConfigDirectory
            if FileManager.default.fileExists(atPath: configPath.path) {
                try FileManager.default.removeItem(at: configPath)
            }

            // Step 5: Delete data directory
            let dataPath = FadogenPaths.garageDataDirectory
            if FileManager.default.fileExists(atPath: dataPath.path) {
                try FileManager.default.removeItem(at: dataPath)
            }

            // Step 6: Delete SwiftData model
            modelContext.delete(versionToRemove)
            try modelContext.save()

            // Step 7: Regenerate Caddy config (removes Garage proxy)
            try caddyConfig?.generateMainCaddyfile()

            // Step 8: Reload Caddy to apply updated configuration
            caddyConfig?.reloadCaddy()

        } catch {
            operationError = error.localizedDescription
            throw error
        }
    }

    // MARK: - Port Management

    func updatePort(newPort: Int) async throws {
        // Step 1: Fetch version from SwiftData
        let descriptor = FetchDescriptor<GarageVersion>(
            predicate: #Predicate { $0.uniqueIdentifier == "garage" }
        )
        guard let garageVersion = try modelContext.fetch(descriptor).first else {
            throw GaragePortUpdateError.notInstalled
        }

        // Step 2: Check if port actually changed
        guard garageVersion.s3Port != newPort else {
            return  // No change needed
        }

        let wasRunning = garageProcess?.isRunning ?? false

        // Step 3: Stop Garage if running
        if wasRunning {
            await garageProcess?.stop()
        }

        // Step 4: Update port in SwiftData
        garageVersion.s3Port = newPort
        garageVersion.rpcPort = newPort + 1
        garageVersion.adminPort = newPort + 3
        try modelContext.save()

        // Step 5: Delete old config (will be regenerated with new ports on next start)
        let configPath = FadogenPaths.garageConfigPath
        if FileManager.default.fileExists(atPath: configPath.path) {
            try FileManager.default.removeItem(at: configPath)
        }

        // Step 6: Regenerate Caddy config with new port
        try caddyConfig?.generateMainCaddyfile()

        // Step 7: Reload Caddy to apply new port
        caddyConfig?.reloadCaddy()

        // Step 8: Restart Garage if it was running
        if wasRunning {
            try await garageProcess?.start(s3Port: newPort)
        }
    }

    func detectPortConflict(port: Int) throws -> String? {
        // Check services
        let servicesDescriptor = FetchDescriptor<ServiceVersion>()
        let allServices = try modelContext.fetch(servicesDescriptor)

        for service in allServices {
            if service.port == port {
                return "\(service.serviceType.displayName) \(service.major)"
            }
        }

        // Check Reverb
        let reverbDescriptor = FetchDescriptor<ReverbVersion>()
        if let reverb = try modelContext.fetch(reverbDescriptor).first {
            if reverb.port == port {
                return "Reverb"
            }
        }

        // Check Typesense
        let typesenseDescriptor = FetchDescriptor<TypesenseVersion>()
        if let typesense = try modelContext.fetch(typesenseDescriptor).first {
            if typesense.port == port {
                return "Typesense"
            }
        }

        return nil
    }

    // MARK: - Private

    private func validateGarageBinaries() -> Bool {
        let path = FadogenPaths.garageBinaryPath.appendingPathComponent("garage")
        return FileManager.default.isExecutableFile(atPath: path.path)
    }
}

// MARK: - Errors

enum GarageManagerError: LocalizedError {
    case invalidResponse
    case invalidMetadata

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from metadata server"
        case .invalidMetadata:
            return "Invalid Garage metadata structure"
        }
    }
}

enum GarageInstallError: LocalizedError {
    case metadataNotAvailable
    case alreadyInstalled
    case anotherOperationInProgress

    var errorDescription: String? {
        switch self {
        case .metadataNotAvailable:
            return "Garage metadata is not available. Please refresh and try again."
        case .alreadyInstalled:
            return "Garage is already installed"
        case .anotherOperationInProgress:
            return "Another operation is in progress. Please wait."
        }
    }
}

enum GarageRemoveError: LocalizedError {
    case notInstalled
    case anotherOperationInProgress

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Garage is not installed"
        case .anotherOperationInProgress:
            return "Another operation is in progress. Please wait."
        }
    }
}

enum GarageUpdateError: LocalizedError {
    case notInstalled
    case noUpdateAvailable
    case anotherOperationInProgress

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Garage is not installed"
        case .noUpdateAvailable:
            return "Already using the latest version"
        case .anotherOperationInProgress:
            return "Another operation is in progress. Please wait."
        }
    }
}

enum GaragePortUpdateError: LocalizedError {
    case notInstalled

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Garage is not installed"
        }
    }
}
